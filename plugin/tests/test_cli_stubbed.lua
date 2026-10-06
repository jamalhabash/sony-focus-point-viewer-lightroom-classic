--[[
Exercise FocusPointCli.lua outside Lightroom with stubbed SDK namespaces and a
fake `focuspoint` shell script. Checks the analyse pipeline's decisions
(Lightroom preview vs embedded, --size, error handling) – not Lightroom
itself. POSIX only.

  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_cli_stubbed.lua
  # or against the real CLI (skips the fake-script assertions):
  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_cli_stubbed.lua <focuspoint> <image.ARW>
]]

local scriptDir = string.match(arg and arg[0] or '', '^(.*)[/\\]') or '.'
package.path = scriptDir .. '/../focuspoint.lrplugin/?.lua;' .. package.path

local realBin, realImage = arg and arg[1], arg and arg[2]

local passed, failed = 0, 0
local function eq(actual, expected, name)
	if actual == expected then
		passed = passed + 1
	else
		failed = failed + 1
		print('FAIL: ' .. name .. '\n  expected: ' .. tostring(expected) .. '\n  actual:   ' .. tostring(actual))
	end
end

local function sh(cmd)
	local rc = os.execute(cmd)
	return rc == 0 or rc == true
end

local function slurp(path)
	local f = io.open(path, 'rb')
	if not f then
		return nil
	end
	local d = f:read('*a')
	f:close()
	return d
end

local function spit(path, data)
	local f = assert(io.open(path, 'wb'))
	f:write(data)
	f:close()
end

-- Work area -------------------------------------------------------------------
local root = os.tmpname()
os.remove(root)
assert(sh("mkdir -p '" .. root .. "/plugin/bin' '" .. root .. "/temp' '" .. root .. "/photos'"))

-- Stubs -------------------------------------------------------------------------
WIN_ENV = false
MAC_ENV = true
_PLUGIN = { path = root .. '/plugin', id = 'dev.focuspoint.lightroom' }

local logLines = {}
local logger = {}
for _, lvl in ipairs({ 'trace', 'debug', 'info', 'warn', 'error', 'fatal' }) do
	logger[lvl] = function(_, ...)
		local parts = {}
		for i = 1, select('#', ...) do
			parts[#parts + 1] = tostring((select(i, ...)))
		end
		logLines[#logLines + 1] = lvl .. ': ' .. table.concat(parts, ' ')
	end
	logger[lvl .. 'f'] = function(_, fmt, ...)
		logLines[#logLines + 1] = lvl .. ': ' .. string.format(fmt, ...)
	end
end
logger.enable = function() end

local function exists(path)
	if sh("test -d '" .. path:gsub("'", "'\\''") .. "'") then
		return 'directory'
	end
	if sh("test -f '" .. path:gsub("'", "'\\''") .. "'") then
		return 'file'
	end
	return false
end

local stubs = {
	LrLogger = function()
		return logger
	end,
	LrDate = {
		currentTime = function()
			return os.time() - 978307200
		end,
	},
	LrPathUtils = {
		child = function(a, b)
			return a .. '/' .. b
		end,
		getStandardFilePath = function(which)
			assert(which == 'temp' or which == 'home')
			return root .. '/temp'
		end,
	},
	LrFileUtils = {
		exists = exists,
		createAllDirectories = function(p)
			return sh("mkdir -p '" .. p .. "'")
		end,
		delete = function(p)
			return os.remove(p) ~= nil
		end,
		readFile = function(p)
			return assert(slurp(p))
		end,
		files = function(dir)
			local list = {}
			local pipe = io.popen("ls -1 '" .. dir .. "'")
			for line in pipe:lines() do
				list[#list + 1] = dir .. '/' .. line
			end
			pipe:close()
			local i = 0
			return function()
				i = i + 1
				return list[i]
			end
		end,
		fileAttributes = function()
			return {}
		end,
	},
	LrTasks = {
		execute = function(cmd)
			return os.execute(cmd)
		end,
		sleep = function() end,
		yield = function() end,
		pcall = pcall,
		startAsyncTask = function(fn)
			fn()
		end,
	},
}

import = function(name)
	return assert(stubs[name], 'no stub for ' .. name)
end

local Core = require 'FocusPointCore'
local Cli = require 'FocusPointCli'

-- Fake photo --------------------------------------------------------------------
local function be16(n)
	return string.char(math.floor(n / 256), n % 256)
end
local function fakeJpeg(w, h)
	return '\255\216\255\192' .. be16(17) .. '\8' .. be16(h) .. be16(w) .. '\3' .. string.rep('\0', 9) .. '\255\217'
end

local function makePhoto(opts)
	local photoPath = opts.path or (root .. '/photos/DSC0001.ARW')
	if opts.createFile ~= false then
		spit(photoPath, 'fake raw')
	end
	local photo = { localIdentifier = 1, thumbRequests = 0 }
	function photo:getFormattedMetadata(key)
		assert(key == 'fileName')
		return string.match(photoPath, '[^/]+$')
	end
	function photo:getRawMetadata(key)
		local raw = {
			path = photoPath,
			fileFormat = opts.fileFormat or 'RAW',
			isVideo = opts.fileFormat == 'VIDEO',
			isCropped = opts.isCropped or false,
			aspectRatio = 1.5,
			pickStatus = 0,
		}
		return raw[key]
	end
	function photo:getDevelopSettings()
		return opts.develop or { HasCrop = false, CropAngle = 0, CropLeft = 0, CropTop = 0, CropRight = 1, CropBottom = 1 }
	end
	function photo:requestJpegThumbnail(w, h, cb)
		self.thumbRequests = self.thumbRequests + 1
		if opts.thumb then
			cb(opts.thumb)
		else
			cb(nil, 'no preview')
		end
		return {}
	end
	return photo
end

-- Fake CLI ------------------------------------------------------------------------
local argsLog = root .. '/args.log'
local function installFakeCli(body)
	local p = root .. '/plugin/bin/focuspoint'
	spit(p, '#!/bin/sh\n' .. 'printf "%s\\n" "$*" >> \'' .. argsLog .. '\'\n' .. body)
	assert(sh("chmod +x '" .. p .. "'"))
	os.remove(argsLog)
end

local OK_INFO = [[
cmd=$1
if [ "$cmd" = info ]; then
  printf 'status=ok\nmake=SONY\nmodel=ILCE-7M4\norientation=1\nimage_width=7008\nimage_height=4672\nfocus_x=3504\nfocus_y=2336\nnorm_x=0.5\nnorm_y=0.5\nfocus_mode=AF-C\naf_area_mode=Zone\nmessage=a\\nb\n'
  exit 0
fi
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out-dir) out="$2"; shift;; esac
  shift
done
mkdir -p "$out"
: > "$out/ov-$$.jpg"; : > "$out/cr-$$.jpg"
src=embedded_preview
case "$(cat ']] .. argsLog .. [[' | tail -1)" in *--source*) src=provided;; esac
printf 'status=ok\nimage_width=7008\nimage_height=4672\norientation=1\nnorm_x=0.5\nnorm_y=0.5\nfocus_mode=AF-C\naf_area_mode=Zone\noverview=%s\ncrop=%s\nsource=%s\n' "$out/ov-$$.jpg" "$out/cr-$$.jpg" "$src"
]]

if not realBin then
	-- 1. Happy path with Lightroom preview.
	installFakeCli(OK_INFO)
	local photo = makePhoto({ thumb = fakeJpeg(2560, 1707) })
	local r = Cli.analyze(photo, { render = true, useLrPreview = true, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.kind, 'ok', 'happy: kind')
	eq(r.sourceNote, 'Lightroom preview', 'happy: source note')
	eq(exists(r.overview), 'file', 'happy: overview exists')
	eq(exists(r.crop), 'file', 'happy: crop exists')
	eq(r.info.focus_mode, 'AF-C', 'happy: info passed through')
	eq(r.aspect, 1.5, 'happy: aspect')
	local argsText = slurp(argsLog) or ''
	eq(string.find(argsText, '--source ' .. root .. '/temp/focuspoint/src-', 1, true) ~= nil, true, 'happy: --source passed')
	eq(string.find(argsText, '--size 640', 1, true) ~= nil, true, 'happy: --size 640')
	eq(string.find(argsText, '--crop-size 400', 1, true) ~= nil, true, 'happy: --crop-size 400')
	eq(string.find(argsText, '--format kv', 1, true) ~= nil, true, 'happy: --format kv')
	-- temp src/out/err files cleaned up
	local leftovers = io.popen("ls '" .. root .. "/temp/focuspoint' | grep -v renders"):read('*a')
	eq(leftovers, '', 'happy: temp files cleaned')

	-- 2. Rotated in Lightroom: preview aspect portrait vs camera landscape.
	installFakeCli(OK_INFO)
	photo = makePhoto({ thumb = fakeJpeg(1707, 2560) })
	r = Cli.analyze(photo, { render = true, useLrPreview = true, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.kind, 'ok', 'rotated: kind')
	eq(string.find(slurp(argsLog) or '', '--source', 1, true), nil, 'rotated: no --source')
	eq(r.sourceNote, 'embedded preview (Lightroom preview is rotated or reshaped)', 'rotated: note')

	-- 3. Develop crop -> no thumbnail request at all.
	photo = makePhoto({ thumb = fakeJpeg(2560, 1707), develop = { HasCrop = true } })
	installFakeCli(OK_INFO)
	r = Cli.analyze(photo, { render = true, useLrPreview = true })
	eq(photo.thumbRequests, 0, 'cropped: no thumbnail requested')
	eq(string.find(slurp(argsLog) or '', '--source', 1, true), nil, 'cropped: no --source')

	-- 4. Preview disabled by the checkbox.
	photo = makePhoto({ thumb = fakeJpeg(2560, 1707) })
	installFakeCli(OK_INFO)
	r = Cli.analyze(photo, { render = true, useLrPreview = false })
	eq(photo.thumbRequests, 0, 'toggle off: no thumbnail requested')

	-- 5. Thumbnail failure falls back silently.
	photo = makePhoto({ thumb = nil })
	installFakeCli(OK_INFO)
	r = Cli.analyze(photo, { render = true, useLrPreview = true })
	eq(r.kind, 'ok', 'thumb fail: still ok')

	-- 6. Video skipped.
	r = Cli.analyze(makePhoto({ fileFormat = 'VIDEO' }), { render = true })
	eq(r.kind, 'video', 'video: kind')

	-- 7. Missing original.
	r = Cli.analyze(makePhoto({ path = root .. '/photos/offline.ARW', createFile = false }), { render = true })
	eq(r.kind, 'missing', 'missing: kind')
	eq(string.find(r.message, 'offline', 1, true) ~= nil, true, 'missing: message')

	-- 8. Unsupported (non-Sony): no render call.
	installFakeCli("printf 'status=unsupported\\nmessage=Not a Sony file\\n'\n")
	r = Cli.analyze(makePhoto({}), { render = true, useLrPreview = true })
	eq(r.kind, 'unsupported', 'unsupported: kind')
	eq(r.message, 'Not a Sony file', 'unsupported: message')
	local _, calls = string.gsub(slurp(argsLog) or '', '\n', '')
	eq(calls, 1, 'unsupported: only info was run')

	-- 9. no_focus is still rendered.
	installFakeCli([[
if [ "$1" = info ]; then printf 'status=no_focus\nfocus_mode=MF\n'; exit 0; fi
printf 'status=no_focus\nfocus_mode=MF\nmessage=Manual focus\n'
]])
	r = Cli.analyze(makePhoto({}), { render = true })
	eq(r.kind, 'no_focus', 'no_focus: kind')
	eq(r.message, 'Manual focus', 'no_focus: message')

	-- 10. CLI error with exit 1 still parsed.
	installFakeCli("printf 'status=error\\nmessage=corrupt file\\n'; exit 1\n")
	r = Cli.analyze(makePhoto({}), { render = true })
	eq(r.kind, 'error', 'error: kind')
	eq(r.message, 'corrupt file', 'error: message')

	-- 11. CLI prints nothing and fails.
	installFakeCli("echo 'thread main panicked' >&2; exit 101\n")
	r = Cli.analyze(makePhoto({}), { render = true })
	eq(r.kind, 'error', 'crash: kind')
	eq(string.find(r.message, 'panicked', 1, true) ~= nil, true, 'crash: stderr in message')

	-- 12. Binary not executable.
	installFakeCli("printf 'status=ok\\n'\n")
	assert(sh("chmod -x '" .. root .. "/plugin/bin/focuspoint'"))
	r = Cli.analyze(makePhoto({}), { render = true })
	eq(r.kind, 'nocli', 'not executable: kind')
	eq(string.find(r.message, 'not executable', 1, true) ~= nil, true, 'not executable: message')

	-- 13. Binary missing.
	os.remove(root .. '/plugin/bin/focuspoint')
	r = Cli.analyze(makePhoto({}), { render = true })
	eq(r.kind, 'nocli', 'missing binary: kind')
	eq(string.find(r.message, 'nix run .#install', 1, true) ~= nil, true, 'missing binary: install hint')

	-- 14. Paths with quotes and spaces survive the shell.
	installFakeCli(OK_INFO)
	r = Cli.analyze(makePhoto({ path = root .. "/photos/it's a photo.ARW" }), { render = true })
	eq(r.kind, 'ok', 'quoted path: kind')
	eq(string.find(slurp(argsLog) or '', "it's a photo.ARW", 1, true) ~= nil, true, 'quoted path: passed intact')

	-- 15. info only (metadata command).
	installFakeCli(OK_INFO)
	r = Cli.analyze(makePhoto({}), { render = false })
	eq(r.kind, 'ok', 'info only: kind')
	eq(r.info.message, 'a\nb', 'info only: escaped value decoded')
	eq(Core.formatFocusPoint(r.info), '50%, 50%', 'info only: focus point')
else
	-- Real CLI: copy it into the fake plug-in and run the pipeline.
	assert(sh("cp '" .. realBin .. "' '" .. root .. "/plugin/bin/focuspoint'"))
	local photo = makePhoto({ path = realImage, createFile = false })
	for _, mode in ipairs({ { render = false }, { render = true, useLrPreview = false } }) do
		local r = Cli.analyze(photo, mode)
		print(string.format('render=%s kind=%s message=%s overview=%s crop=%s source=%s aspect=%s',
			tostring(mode.render), tostring(r.kind), tostring(r.message), tostring(r.overview),
			tostring(r.crop), tostring(r.sourceNote), tostring(r.aspect)))
		print('  summary: ' .. Core.summaryLine(r.info, r.fileName) .. ' | point: ' .. tostring(Core.formatFocusPoint(r.info)))
		eq(r.kind == 'ok' or r.kind == 'no_focus' or r.kind == 'unsupported', true, 'real CLI kind sane')
		if mode.render and r.kind == 'ok' then
			eq(exists(r.overview), 'file', 'real CLI overview exists')
			eq(exists(r.crop), 'file', 'real CLI crop exists')
			local w, h = Core.jpegSize(slurp(r.overview))
			print(string.format('  overview %sx%s', tostring(w), tostring(h)))
			eq(math.max(w or 0, h or 0) <= 640, true, 'real overview fits box width')
			eq(math.min(w or 0, h or 0) <= 480, true, 'real overview fits box height')
		end
	end
end

sh("rm -rf '" .. root .. "'")
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then
	for _, l in ipairs(logLines) do
		print('  log ' .. l)
	end
	os.exit(1)
end
