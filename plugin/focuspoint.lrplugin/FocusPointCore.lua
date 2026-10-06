--[[----------------------------------------------------------------------------
FocusPointCore.lua

Pure helper functions shared by the Focus Point plug-in.

This module deliberately does NOT import any Lightroom namespace, so it can be
loaded and unit-tested with a stock Lua 5.1 interpreter outside Lightroom
(see plugin/tests/test_core.lua). Everything that touches the SDK lives in
FocusPointCli.lua / FocusPointViewer.lua.

Lua 5.1 only: no goto, no // operator, no utf8 library, no bit ops.
------------------------------------------------------------------------------]]

local Core = {}

--------------------------------------------------------------------------------
-- kv output parsing
--
-- The CLI prints one `key=value` per line (UTF-8). Inside values a newline is
-- written as the two characters `\n` and a backslash as `\\`. Any other
-- backslash sequence is left untouched (we do not invent escapes the CLI does
-- not produce).
--------------------------------------------------------------------------------

local function unescapeChar(c)
	if c == 'n' then
		return '\n'
	elseif c == '\\' then
		return '\\'
	end
	return '\\' .. c
end

--- Undo the CLI's value escaping. Scans left to right, so `\\n` (escaped
-- backslash followed by a literal n) correctly becomes `\n` (two characters),
-- not a newline.
function Core.unescapeValue(s)
	if s == nil then
		return nil
	end
	-- gsub matches are non-overlapping and scanned left to right; a trailing
	-- lone backslash has no following char and is therefore kept as-is.
	local out = string.gsub(s, '\\(.)', unescapeChar)
	return out
end

--- Escape a value the same way the CLI does (used by tests and logging).
function Core.escapeValue(s)
	local out = string.gsub(s, '\\', '\\\\')
	out = string.gsub(out, '\n', '\\n')
	return out
end

--- Parse kv text into a table of string -> string.
-- Blank lines and lines without `=` are ignored. CRLF line endings are
-- tolerated. Keys are trimmed of surrounding whitespace; values are not
-- (apart from a trailing CR). Later duplicates win.
function Core.parseKv(text)
	local result = {}
	if type(text) ~= 'string' or text == '' then
		return result
	end
	-- Append a newline so the last line is matched even without a terminator.
	for line in string.gmatch(text .. '\n', '([^\n]*)\n') do
		line = string.gsub(line, '\r$', '')
		local eq = string.find(line, '=', 1, true)
		if eq and eq > 1 then
			local key = string.match(string.sub(line, 1, eq - 1), '^%s*(.-)%s*$')
			if key ~= '' then
				result[key] = Core.unescapeValue(string.sub(line, eq + 1))
			end
		end
	end
	return result
end

--- tonumber() that tolerates nil and surrounding whitespace.
function Core.num(v)
	if v == nil then
		return nil
	end
	return tonumber((string.gsub(tostring(v), '^%s*(.-)%s*$', '%1')))
end

--------------------------------------------------------------------------------
-- Shell quoting / command building
--------------------------------------------------------------------------------

--- POSIX sh single-quote: wrap in '...' and turn each embedded ' into '\''.
function Core.shellQuotePosix(s)
	s = tostring(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

--- Windows cmd.exe quoting: wrap in double quotes. Windows paths cannot
-- contain `"`, so we only defensively drop any that appear. (cmd.exe has no
-- reliable escape for `"` inside a quoted argument.) `%` is not escaped:
-- paths we pass are plug-in/temp/photo paths; this is a known limitation.
function Core.shellQuoteWindows(s)
	s = tostring(s)
	return '"' .. string.gsub(s, '"', '') .. '"'
end

--- Build the full shell command line for LrTasks.execute.
-- @param exe      absolute path of the CLI binary
-- @param args     array of argument strings (each quoted individually)
-- @param outFile  file to receive stdout
-- @param errFile  file to receive stderr (optional)
-- @param isWindows true on Windows (WIN_ENV)
function Core.buildCommand(exe, args, outFile, errFile, isWindows)
	local q = isWindows and Core.shellQuoteWindows or Core.shellQuotePosix
	local parts = { q(exe) }
	for i = 1, #args do
		parts[#parts + 1] = q(args[i])
	end
	local cmd = table.concat(parts, ' ') .. ' > ' .. q(outFile)
	if errFile then
		cmd = cmd .. ' 2> ' .. q(errFile)
	end
	if isWindows then
		-- LrTasks.execute hands the string to `cmd.exe /c`, which strips the
		-- first and last quote when the line starts with a quote. The SDK guide
		-- says: "In Windows, enclose the whole command in double quotes."
		cmd = '"' .. cmd .. '"'
	end
	return cmd
end

--- Normalise LrTasks.execute's return value to a process exit code.
-- On macOS it returns the raw wait() status (exit code * 256), on Windows
-- the exit code itself.
function Core.exitCode(rc)
	rc = tonumber(rc)
	if rc == nil then
		return nil
	end
	if rc >= 256 and rc % 256 == 0 then
		return rc / 256
	end
	return rc
end

--------------------------------------------------------------------------------
-- JPEG dimensions (from SOFn marker) – used to check the aspect of the
-- Lightroom preview before handing it to the CLI as --source.
--------------------------------------------------------------------------------

local function u16(data, pos)
	local a, b = string.byte(data, pos, pos + 1)
	if not a or not b then
		return nil
	end
	return a * 256 + b
end

--- Return width, height of a baseline/progressive JPEG held in a string, or
-- nil if the header can't be parsed.
function Core.jpegSize(data)
	if type(data) ~= 'string' or #data < 4 then
		return nil
	end
	if string.byte(data, 1) ~= 0xFF or string.byte(data, 2) ~= 0xD8 then
		return nil
	end
	local pos = 3
	local len = #data
	while pos + 3 <= len do
		-- Skip fill bytes / find the next marker.
		if string.byte(data, pos) ~= 0xFF then
			return nil
		end
		local marker = string.byte(data, pos + 1)
		if marker == 0xFF then
			pos = pos + 1
		elseif marker == 0xD8 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
			-- Standalone markers without a length.
			pos = pos + 2
		elseif marker == 0xD9 or marker == 0xDA then
			-- EOI or start of scan before any SOF: give up.
			return nil
		else
			local segLen = u16(data, pos + 2)
			if not segLen or segLen < 2 then
				return nil
			end
			local isSof = marker >= 0xC0 and marker <= 0xCF
				and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
			if isSof then
				-- FF Cx LL LL P HH HH WW WW
				local h = u16(data, pos + 5)
				local w = u16(data, pos + 7)
				if not h or not w or w == 0 or h == 0 then
					return nil
				end
				return w, h
			end
			pos = pos + 2 + segLen
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

--- Displayed (orientation-applied) aspect ratio (w / h) from CLI info output,
-- or nil when unknown. Orientation 5..8 swaps width and height.
function Core.displayedAspect(info)
	if type(info) ~= 'table' then
		return nil
	end
	local w = Core.num(info.image_width)
	local h = Core.num(info.image_height)
	if not w or not h or w <= 0 or h <= 0 then
		return nil
	end
	local o = Core.num(info.orientation) or 1
	if o >= 5 and o <= 8 then
		w, h = h, w
	end
	return w / h
end

--- True when two aspect ratios describe the same frame shape: same
-- orientation (landscape vs portrait) and within `tolerance` (relative,
-- default 3 %).
function Core.aspectMatches(a, b, tolerance)
	if not a or not b or a <= 0 or b <= 0 then
		return false
	end
	tolerance = tolerance or 0.03
	if (a >= 1) ~= (b >= 1) then
		-- One is landscape, the other portrait (e.g. user rotated 90° in Lr).
		-- Exactly square frames (a == 1) fall into the "landscape" bucket on
		-- both sides, which is what we want.
		return false
	end
	return math.abs(a - b) / b <= tolerance
end

--- Long-edge size (for --size) so that an image of aspect `aspect` (w/h) fits
-- inside a box of boxW x boxH pixels. Falls back to the smaller box side when
-- the aspect is unknown.
function Core.fitLongEdge(aspect, boxW, boxH)
	if not aspect or aspect <= 0 then
		return math.floor(math.min(boxW, boxH))
	end
	local size
	if aspect >= 1 then
		-- landscape: width = size, height = size / aspect
		size = math.min(boxW, boxH * aspect)
	else
		-- portrait: height = size, width = size * aspect
		size = math.min(boxH, boxW / aspect)
	end
	return math.floor(size)
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

local function nonEmpty(s)
	return s ~= nil and s ~= ''
end

--- Round to nearest integer (Lua 5.1 has no math.round).
function Core.round(x)
	if x >= 0 then
		return math.floor(x + 0.5)
	end
	return -math.floor(-x + 0.5)
end

--- "x%, y%" from normalised coordinates, or nil if unknown.
function Core.formatFocusPoint(info)
	if type(info) ~= 'table' then
		return nil
	end
	local x = Core.num(info.norm_x)
	local y = Core.num(info.norm_y)
	if not x or not y then
		return nil
	end
	return string.format('%d%%, %d%%', Core.round(x * 100), Core.round(y * 100))
end

local MIDDOT = ' \194\183 ' -- " · " (U+00B7, UTF-8 encoded)
Core.SEPARATOR = MIDDOT

--- Combined tracking / face / eye text, or nil.
function Core.trackingText(info)
	if type(info) ~= 'table' then
		return nil
	end
	local parts = {}
	if nonEmpty(info.af_tracking) then
		parts[#parts + 1] = info.af_tracking
	end
	if nonEmpty(info.face_eye) and info.face_eye ~= info.af_tracking then
		parts[#parts + 1] = info.face_eye
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ', ')
end

--- Human-readable flag label for a pickStatus value.
function Core.flagLabel(pickStatus)
	if pickStatus == 1 then
		return 'Picked'
	elseif pickStatus == -1 then
		return 'Rejected'
	end
	return 'Unflagged'
end

--- One-line summary: focus mode · AF area · tracking/eye · file name [· flag]
function Core.summaryLine(info, fileName, flag)
	local parts = {}
	if type(info) == 'table' then
		if nonEmpty(info.focus_mode) then
			parts[#parts + 1] = info.focus_mode
		end
		if nonEmpty(info.af_area_mode) then
			parts[#parts + 1] = info.af_area_mode
		end
		local t = Core.trackingText(info)
		if t then
			parts[#parts + 1] = t
		end
	end
	if nonEmpty(fileName) then
		parts[#parts + 1] = fileName
	end
	if nonEmpty(flag) then
		parts[#parts + 1] = flag
	end
	return table.concat(parts, MIDDOT)
end

--- Truncate a string to at most `maxBytes` bytes without splitting a UTF-8
-- sequence (searchable plug-in fields must be <= 511 bytes).
function Core.truncateUtf8(s, maxBytes)
	if s == nil or #s <= maxBytes then
		return s
	end
	local cut = maxBytes
	-- Step back while the byte after the cut is a continuation byte (10xxxxxx).
	while cut > 0 do
		local nextByte = string.byte(s, cut + 1)
		if nextByte == nil or nextByte < 0x80 or nextByte >= 0xC0 then
			break
		end
		cut = cut - 1
	end
	return string.sub(s, 1, cut)
end

--- Explain why the CLI produced no parseable output.
-- @param code normalised exit code (see Core.exitCode)
-- @param stderr captured stderr text (may be nil)
function Core.describeExecFailure(code, stderr)
	local hint
	if code == 127 then
		hint = 'The focuspoint helper could not be found or started (exit 127).'
	elseif code == 126 then
		hint = 'The focuspoint helper is not executable (exit 126). '
			.. 'Try: chmod +x on plug-in bin/focuspoint, or reinstall with `nix run .#install`.'
	elseif code ~= nil and code ~= 0 then
		hint = string.format('The focuspoint helper failed (exit %s) without printing a result.', tostring(code))
	else
		hint = 'The focuspoint helper printed no result.'
	end
	if nonEmpty(stderr) then
		local first = string.match(stderr, '^%s*([^\n]+)')
		if first then
			hint = hint .. ' ' .. Core.truncateUtf8(first, 300)
		end
	end
	return hint
end

return Core
