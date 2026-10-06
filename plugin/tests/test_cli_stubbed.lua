--[[
Exercise FocusPointCli.lua / FocusPointViewer.lua outside Lightroom with
stubbed SDK namespaces and a fake `focuspoint` shell script. Checks the
analyse pipeline's decisions (Lightroom preview vs embedded, --size, render
cache, batch, error handling) and the floating viewer's session logic
(cache hits, on-demand renders, prefetch) – not Lightroom itself. POSIX only.

  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_cli_stubbed.lua
  # or against the real CLI (skips the fake-script assertions):
  nix shell nixpkgs#lua5_1 -c lua plugin/tests/test_cli_stubbed.lua <focuspoint> <image> [<image>...]
]]

local scriptDir = string.match(arg and arg[0] or '', '^(.*)[/\\]') or '.'
package.path = scriptDir .. '/../focuspoint.lrplugin/?.lua;' .. package.path

local realBin, realImage = arg and arg[1], arg and arg[2]
local realImages = {}
for i = 2, (arg and #arg or 0) do
	realImages[#realImages + 1] = arg[i]
end

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

fakeClock = 1000
local function advance(dt)
	fakeClock = fakeClock + dt
end
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
	-- Only needed so FocusPointViewer can be loaded (applyResult tests).
	LrApplication = {},
	LrBinding = {},
	LrDialogs = {},
	LrFunctionContext = {},
	LrPrefs = {},
	LrView = {},
	-- Fake clock: advances a little on every read, tests jump it forward.
	-- With a real CLI, real wall time (sub-second, via perl) plus the jumps,
	-- so the logged timings are meaningful.
	LrDate = {
		currentTime = function()
			if realBin then
				local pipe = io.popen("perl -MTime::HiRes=time -e 'printf q(%.4f), time'")
				local t = tonumber(pipe:read('*a'))
				pipe:close()
				return (t or os.time()) - 978307200 + fakeClock
			end
			fakeClock = fakeClock + 0.0001
			return fakeClock
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
local Viewer = require 'FocusPointViewer'

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
	local photo = { localIdentifier = opts.id or 1, thumbRequests = 0 }
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
			aspectRatio = opts.aspectRatio or 1.5,
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
	local happy = r
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

	-- 9. no_focus is still rendered: overview only, no crop, no focus keys.
	-- The photo is rotated to portrait in Lightroom, but the overview is the
	-- camera's landscape frame: the slot must follow the overview.
	installFakeCli([[
if [ "$1" = info ]; then printf 'status=no_focus\nfocus_mode=Manual\nmessage=Manual focus\n'; exit 0; fi
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out-dir) out="$2"; shift;; esac
  shift
done
mkdir -p "$out"
: > "$out/ov-nf-$$.jpg"
printf 'status=no_focus\nfocus_mode=Manual\nmessage=Manual focus\noverview=%s\nsource=embedded_preview\nsource_width=1616\nsource_height=1080\n' "$out/ov-nf-$$.jpg"
]])
	r = Cli.analyze(makePhoto({ aspectRatio = 2 / 3 }), { render = true, useLrPreview = false })
	eq(r.kind, 'no_focus', 'no_focus: kind')
	eq(r.message, 'Manual focus', 'no_focus: message')
	eq(exists(r.overview), 'file', 'no_focus: overview exists')
	eq(r.crop, nil, 'no_focus: no crop')
	eq(r.aspect, 1616 / 1080, 'no_focus: aspect from the rendered overview')

	-- The viewer must not keep showing the previous photo's crop.
	local props = {}
	Viewer.initProps(props)
	Viewer.applyResult(props, happy, 'Flag: Unflagged')
	eq(props.cropPath, happy.crop, 'viewer: ok shows crop')
	eq(props.showCrop, true, 'viewer: ok crop visible')
	Viewer.applyResult(props, r, 'Flag: Unflagged')
	eq(props.cropPath, Viewer.blankImage(), 'viewer: no_focus clears crop')
	eq(props.showCrop, false, 'viewer: no_focus hides crop')
	eq(props.landscapePath, r.overview, 'viewer: no_focus overview in landscape slot')
	eq(props.showPortrait, false, 'viewer: no_focus portrait slot hidden')
	eq(props.showMessage, false, 'viewer: no_focus overview shown, not the message overlay')
	eq(string.find(props.status, 'Manual focus', 1, true) ~= nil, true, 'viewer: no_focus message in status')
	eq(props.summary, 'Manual \194\183 DSC0001.ARW', 'viewer: no_focus summary')

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
	---------------------------------------------------------------------------
	-- v0.2: render cache, batch, viewer session
	---------------------------------------------------------------------------

	-- Fake CLI with `render --cache-dir` (stable names, cached=true on the
	-- second call), `render --out-dir` (unique names) and `batch --list`.
	-- File names steer the outcome: *portrait* -> portrait frame,
	-- *nonsony* -> unsupported, *broken* -> error.
	local batchLog = root .. '/batch.log'
	local CACHE_CLI = [[
cmd=$1; shift
out=""; cache=""; list=""; size=640; crop=400; file=""; src=""
while [ $# -gt 0 ]; do
  case "$1" in
	--out-dir) out="$2"; shift;;
	--cache-dir) cache="$2"; shift;;
	--list) list="$2"; shift;;
	--size) size="$2"; shift;;
	--crop-size) crop="$2"; shift;;
	--source) src="$2"; shift;;
	--format|--jobs) shift;;
	*) file="$1";;
  esac
  shift
done
one() {
  f="$1"
  case "$f" in *portrait*) sw=1080; sh=1616;; *) sw=1616; sh=1080;; esac
  case "$f" in *nonsony*) printf 'status=unsupported\nmessage=Not a Sony file\n'; return;; esac
  case "$f" in *broken*) printf 'status=error\nmessage=corrupt\n'; return;; esac
  if [ "$cmd" = info ]; then
	printf 'status=ok\nimage_width=7008\nimage_height=4672\norientation=1\nnorm_x=0.5\nnorm_y=0.5\nfocus_mode=AF-S\n'
	return
  fi
  if [ -n "$cache" ] && [ -z "$src" ]; then
	k=$(printf '%s|%s|%s' "$f" "$size" "$crop" | cksum | cut -d' ' -f1)
	ov="$cache/$k-overview.jpg"; cr="$cache/$k-crop.jpg"
	if [ -f "$ov" ] && [ -f "$cr" ]; then c=true; else c=false; mkdir -p "$cache"; : > "$ov"; : > "$cr"; fi
	s2=embedded_preview
  else
	mkdir -p "$out"; n=$(date +%s)$$; ov="$out/ov-$n-$size.jpg"; cr="$out/cr-$n-$size.jpg"; : > "$ov"; : > "$cr"; c=false
	s2=embedded_preview; [ -n "$src" ] && s2=provided
  fi
  printf 'status=ok\nimage_width=7008\nimage_height=4672\norientation=1\nnorm_x=0.5\nnorm_y=0.5\nfocus_mode=AF-C\naf_area_mode=Zone\noverview=%s\ncrop=%s\nsource=%s\nsource_width=%s\nsource_height=%s\ncached=%s\n' "$ov" "$cr" "$s2" "$sw" "$sh" "$c"
}
if [ "$cmd" = batch ]; then
  { printf 'size=%s:' "$size"; tr '\n' ',' < "$list"; printf '\n'; } >> ']] .. batchLog .. [['
  while IFS= read -r line; do printf 'file=%s\n' "$line"; one "$line"; printf -- '---\n'; done < "$list"
  exit 0
fi
one "$file"
]]
	local function calls()
		local _, n = string.gsub(slurp(argsLog) or '', '\n', '')
		return n
	end
	local function logHas(text)
		for _, l in ipairs(logLines) do
			if string.find(l, text, 1, true) then
				return true
			end
		end
		return false
	end
	local function countLog(text)
		local n = 0
		for _, l in ipairs(logLines) do
			if string.find(l, text, 1, true) then
				n = n + 1
			end
		end
		return n
	end
	local cacheDir = root .. '/cache'

	-- 16. Cache mode: one `render --cache-dir` call, no `info`.
	installFakeCli(CACHE_CLI)
	local cp = makePhoto({ path = root .. '/photos/C1.ARW' })
	r = Cli.analyze(cp, { render = true, cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.kind, 'ok', 'cache: kind')
	eq(calls(), 1, 'cache: exactly one CLI call')
	local a1 = slurp(argsLog) or ''
	eq(string.find(a1, 'render ', 1, true) == 1, true, 'cache: render (no info)')
	eq(string.find(a1, '--cache-dir ' .. cacheDir, 1, true) ~= nil, true, 'cache: --cache-dir passed')
	eq(string.find(a1, '--out-dir', 1, true), nil, 'cache: no --out-dir')
	eq(string.find(a1, '--size 640', 1, true) ~= nil, true, 'cache: --size 640 for landscape')
	eq(r.ephemeral, false, 'cache: not ephemeral')
	eq(r.cached, false, 'cache: first render not cached')
	eq(r.size, 640, 'cache: size recorded')
	eq(Cli.isCacheable(r), true, 'cache: cacheable')
	eq(r.timing and r.timing.calls, 1, 'cache: timing calls')
	eq(Core.renderNote(r) ~= nil and string.find(Core.renderNote(r), 'rendered in', 1, true) ~= nil, true,
		'cache: status note says rendered')
	r = Cli.analyze(cp, { render = true, cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.cached, true, 'cache: second render cached')
	eq(Core.renderNote(r), 'cached', 'cache: status note cached')

	-- 17. Portrait guess from Lightroom's aspect -> --size 480, one call.
	installFakeCli(CACHE_CLI)
	r = Cli.analyze(makePhoto({ path = root .. '/photos/C2-portrait.ARW', aspectRatio = 2 / 3 }),
		{ render = true, cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
	eq(calls(), 1, 'portrait: one call')
	eq(r.size, 480, 'portrait: size 480')
	eq(r.aspect < 1, true, 'portrait: aspect from the overview source')

	-- 18. Wrong guess (rotated in Lightroom: Lr says portrait, camera frame
	-- is landscape) -> corrected once to 640.
	installFakeCli(CACHE_CLI)
	r = Cli.analyze(makePhoto({ path = root .. '/photos/C3.ARW', aspectRatio = 2 / 3 }),
		{ render = true, cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
	eq(calls(), 2, 'resize: two calls')
	eq(r.size, 640, 'resize: final size 640')
	eq(r.timing.calls, 2, 'resize: timing counts both calls')

	-- 19. Lightroom preview on -> info + --source + --out-dir, ephemeral.
	installFakeCli(CACHE_CLI)
	r = Cli.analyze(makePhoto({ path = root .. '/photos/C4.ARW', thumb = fakeJpeg(2560, 1707) }),
		{ render = true, cacheDir = cacheDir, useLrPreview = true, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.kind, 'ok', 'lr preview + cache: kind')
	eq(r.ephemeral, true, 'lr preview + cache: ephemeral')
	eq(r.sourceNote, 'Lightroom preview', 'lr preview + cache: source')
	local a4 = slurp(argsLog) or ''
	eq(string.find(a4, '--out-dir', 1, true) ~= nil and string.find(a4, '--cache-dir', 1, true) == nil, true,
		'lr preview + cache: --out-dir, not --cache-dir')
	-- Cropped photo with the option on: falls back to the embedded preview,
	-- which goes through the cache (not ephemeral).
	installFakeCli(CACHE_CLI)
	r = Cli.analyze(makePhoto({ path = root .. '/photos/C5.ARW', thumb = fakeJpeg(2560, 1707), develop = { HasCrop = true } }),
		{ render = true, cacheDir = cacheDir, useLrPreview = true, boxW = 640, boxH = 480, cropSize = 400 })
	eq(r.ephemeral, false, 'lr preview unusable: cache used')
	eq(string.find(r.sourceNote or '', 'Develop crop', 1, true) ~= nil, true, 'lr preview unusable: reason kept')

	-- 20. HEIF always takes the Lightroom-preview path.
	installFakeCli(CACHE_CLI)
	local hp = makePhoto({ path = root .. '/photos/C6.HIF', thumb = fakeJpeg(2560, 1707) })
	r = Cli.analyze(hp, { render = true, cacheDir = cacheDir, useLrPreview = false, boxW = 640, boxH = 480 })
	eq(hp.thumbRequests, 1, 'heif: Lightroom preview requested')
	eq(string.find(slurp(argsLog) or '', '--source', 1, true) ~= nil, true, 'heif: --source passed')

	-- 21. Cli.batch: blocks in input order, quoted paths, list file removed.
	installFakeCli(CACHE_CLI)
	local bp = { root .. "/photos/B1 it's.ARW", root .. '/photos/B2-nonsony.JPG', root .. '/photos/B3-broken.ARW' }
	for _, p in ipairs(bp) do
		spit(p, 'x')
	end
	local blocks, bmeta = Cli.batch(bp, { cacheDir = cacheDir, size = 640, cropSize = 400 })
	eq(#blocks, 3, 'batch: three blocks')
	eq(blocks[1] and blocks[1].file, bp[1], 'batch: first file (quote + space)')
	eq(blocks[1] and blocks[1].status, 'ok', 'batch: first ok')
	eq(blocks[2] and blocks[2].status, 'unsupported', 'batch: unsupported')
	eq(blocks[3] and blocks[3].status, 'error', 'batch: per-file error')
	eq(type(bmeta.elapsed), 'number', 'batch: elapsed')
	local a5 = slurp(argsLog) or ''
	eq(string.find(a5, 'batch --cache-dir ' .. cacheDir .. ' --list ', 1, true) == 1, true, 'batch: args')
	local leftovers = io.popen("ls '" .. root .. "/temp/focuspoint' | grep list- ; true"):read('*a')
	eq(leftovers, '', 'batch: list file deleted')

	-- 22. Cli.analyzeBatch (Read Focus Metadata): grouped by size, fallbacks.
	installFakeCli(CACHE_CLI)
	local mp = {
		makePhoto({ id = 1, path = root .. '/photos/M1.ARW' }),
		makePhoto({ id = 2, path = root .. '/photos/M2-portrait.ARW', aspectRatio = 2 / 3 }),
		makePhoto({ id = 3, path = root .. '/photos/M3.MP4', fileFormat = 'VIDEO' }),
		makePhoto({ id = 4, path = root .. '/photos/M4-nonsony.JPG' }),
		makePhoto({ id = 5, path = root .. '/photos/M5.HIF' }),
		makePhoto({ id = 6, path = root .. '/photos/M6-broken.ARW' }),
	}
	local mr = Cli.analyzeBatch(mp, { cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
	eq(mr[1].kind, 'ok', 'metadata batch: ok')
	eq(mr[1].info.focus_mode, 'AF-C', 'metadata batch: info from block')
	eq(mr[2].kind, 'ok', 'metadata batch: portrait ok')
	eq(mr[3].kind, 'video', 'metadata batch: video skipped')
	eq(mr[4].kind, 'unsupported', 'metadata batch: unsupported')
	eq(mr[5].kind, 'ok', 'metadata batch: heif via info')
	eq(mr[5].info.focus_mode, 'AF-S', 'metadata batch: heif info output')
	eq(mr[6].kind, 'error', 'metadata batch: broken file falls back to info (still error)')
	local _, nBatch = string.gsub(slurp(argsLog) or '', 'batch ', '')
	eq(nBatch, 2, 'metadata batch: one batch call per size group')
	-- Helper without `batch` -> one info call per photo.
	installFakeCli("if [ \"$1\" = batch ]; then echo 'error: unrecognized subcommand' >&2; exit 2; fi\n"
		.. "printf 'status=ok\\nfocus_mode=AF-S\\n'\n")
	mr = Cli.analyzeBatch({ mp[1], mp[2] }, { cacheDir = cacheDir })
	eq(mr[1].kind, 'ok', 'metadata batch fallback: ok')
	eq(mr[2].info.focus_mode, 'AF-S', 'metadata batch fallback: info used')

	-- 23. Viewer session: miss -> render, prefetch, hits without CLI calls.
	installFakeCli(CACHE_CLI)
	os.remove(batchLog)
	local vcache = root .. '/vcache'
	local photos = {}
	for i = 1, 20 do
		local name = string.format('V%02d', i)
		local o = { id = 100 + i, path = root .. '/photos/' .. name .. '.ARW' }
		if i == 7 then
			o.path = root .. '/photos/V07-portrait.ARW'
			o.aspectRatio = 2 / 3
		elseif i == 9 then
			o.aspectRatio = 2 / 3 -- rotated in Lightroom; the camera frame is landscape
		elseif i == 12 then
			o.path = root .. '/photos/V12-nonsony.JPG'
		elseif i == 13 then
			o.path = root .. '/photos/V13.MP4'
			o.fileFormat = 'VIDEO'
		elseif i == 14 then
			o.path = root .. '/photos/V14-offline.ARW'
			o.createFile = false
		elseif i == 15 then
			o.thumb = fakeJpeg(2560, 1707)
		end
		photos[i] = makePhoto(o)
	end
	local catalog = { target = photos[5], listCalls = 0, metaCalls = 0 }
	function catalog:getTargetPhoto()
		return self.target
	end
	function catalog:getMultipleSelectedOrAllPhotos()
		self.listCalls = self.listCalls + 1
		return photos
	end
	function catalog:batchGetRawMetadata(list, keys)
		self.metaCalls = self.metaCalls + 1
		local out = {}
		for _, p in ipairs(list) do
			local m = {}
			for _, k in ipairs(keys) do
				m[k] = p:getRawMetadata(k)
			end
			out[p] = m
		end
		return out
	end
	local props = { useLrPreview = false, prefetchNote = '' }
	Viewer.initProps(props)
	local session = Viewer.newSession(catalog, props, { cacheDir = vcache })
	local st = session.state

	session.step()
	eq(calls(), 0, 'session: miss waits for the debounce')
	eq(st.shownKey, nil, 'session: nothing shown yet')
	advance(0.1)
	session.step()
	eq(calls(), 1, 'session: miss rendered with one CLI call')
	eq(st.shownKey, 105, 'session: miss displayed')
	eq(props.landscapePath, st.results[105] and st.results[105].overview, 'session: overview shown')
	eq(props.flagEnabled, true, 'session: flag buttons enabled')
	eq(string.find(props.status, 'rendered in', 1, true) ~= nil, true, 'session: status shows render time')
	eq(logHas('timing: show kind=miss file=V05.ARW'), true, 'session: timing line for the miss')
	eq(st.onDemand, 0, 'session: on-demand counter back to 0')

	-- Prefetch until idle.
	local rounds, delay = 0, 0
	repeat
		delay = session.prefetchStep()
		rounds = rounds + 1
	until delay > 0 or rounds > 20
	eq(delay, 0.5, 'prefetch: goes idle')
	local firstBatch = string.match(slurp(batchLog) or '', '^([^\n]*)') or ''
	eq(string.find(firstBatch, 'size=640:' .. root .. '/photos/V06.ARW,' .. root .. '/photos/V04.ARW,'
		.. root .. '/photos/V08.ARW,', 1, true) == 1, true, 'prefetch: first batch ordered +1, -1, +3 (portrait +2 skipped)')
	eq(string.find(slurp(batchLog) or '', 'V13.MP4', 1, true), nil, 'prefetch: video never batched')
	eq(string.find(slurp(batchLog) or '', 'V14-offline', 1, true), nil, 'prefetch: offline file never batched')
	eq(st.results[107] ~= nil and st.results[107].size, 480, 'prefetch: portrait rendered at 480')
	eq(st.results[109] ~= nil and st.results[109].size, 640, 'prefetch: rotated-in-Lr photo corrected to 640')
	eq(st.results[112] ~= nil and st.results[112].kind, 'unsupported', 'prefetch: unsupported remembered')
	eq(st.results[113], nil, 'prefetch: no result for video')
	eq(st.missing[114], true, 'prefetch: offline file marked missing')
	eq(props.prefetchNote, '18 nearby photos pre-rendered', 'prefetch: progress note when done')
	eq(logHas('timing: batch purpose=prefetch'), true, 'prefetch: timing line per batch')
	eq(catalog.listCalls, 1, 'prefetch: photo list fetched once while target is unchanged')

	-- Flip to prefetched photos: shown at once, no CLI call.
	local before = calls()
	for _, i in ipairs({ 6, 7, 9, 12, 4 }) do
		catalog.target = photos[i]
		session.step()
		eq(st.shownKey, 100 + i, 'hit: shown immediately #' .. i)
	end
	eq(calls(), before, 'hit: no CLI calls for hits')
	eq(countLog('timing: show kind=hit'), 5, 'hit: timing lines')
	eq(string.find(props.status, 'cached', 1, true) ~= nil, true, 'hit: status says cached')
	catalog.target = photos[7]
	session.step()
	eq(props.showPortrait, true, 'hit: portrait slot for the portrait photo')
	eq(props.portraitPath, st.results[107].overview, 'hit: portrait overview')
	catalog.target = photos[12]
	session.step()
	eq(props.showMessage, true, 'hit: unsupported shows its message')
	eq(props.message, 'Not a Sony file', 'hit: unsupported message')

	-- A cache file vanished (CLI pruned it): miss, rendered again.
	os.remove(st.results[108].overview)
	catalog.target = photos[8]
	session.step()
	eq(st.shownKey, 112, 'vanished: not shown from memory')
	eq(st.results[108], nil, 'vanished: entry dropped')
	advance(0.1)
	session.step()
	eq(st.shownKey, 108, 'vanished: re-rendered and shown')
	eq(calls(), before + 1, 'vanished: one CLI call')
	eq(exists(st.results[108].overview), 'file', 'vanished: file back')

	-- Video and offline: explained, not errors.
	catalog.target = photos[13]
	session.step()
	advance(0.1)
	session.step()
	eq(st.shownKey, 113, 'video: shown')
	eq(string.find(props.message, 'Video', 1, true) ~= nil, true, 'video: message')
	catalog.target = photos[14]
	session.step()
	advance(0.1)
	session.step()
	eq(string.find(props.message, 'offline', 1, true) ~= nil, true, 'offline: message')

	-- Re-render button: forced, no debounce.
	catalog.target = photos[6]
	session.step()
	before = calls()
	session.forceRender()
	session.step()
	eq(calls(), before + 1, 'force: one CLI call')
	eq(logHas('timing: show kind=forced'), true, 'force: displayed again')

	-- No photo selected.
	catalog.target = nil
	session.step()
	eq(st.shownKey, false, 'none: state')
	eq(string.find(props.message, 'No photo selected', 1, true) ~= nil, true, 'none: message')
	eq(props.flagEnabled, false, 'none: flag buttons disabled')

	-- Target change refreshes the list (rate-limited); stays around target.
	catalog.target = photos[18]
	session.step()
	advance(1.5)
	session.prefetchStep()
	eq(catalog.listCalls, 2, 'list: refreshed after the target changed')

	-- Lightroom-preview mode: no hits, ephemeral renders, prefetch paused.
	props.useLrPreview = true
	session.lrPreviewChanged()
	catalog.target = photos[15]
	session.step()
	advance(0.1)
	session.step()
	eq(st.shownKey, 115, 'lr mode: rendered')
	eq(st.shownResult.sourceNote, 'Lightroom preview', 'lr mode: Lightroom preview used')
	eq(#st.shownEphemeral, 2, 'lr mode: ephemeral files tracked')
	local eph = st.shownEphemeral
	eq(session.prefetchStep(), 0.5, 'lr mode: prefetch paused')
	eq(string.find(props.prefetchNote, 'paused', 1, true) ~= nil, true, 'lr mode: paused note')
	-- Back to embedded: instant hit, the Lightroom-preview files are deleted.
	props.useLrPreview = false
	session.lrPreviewChanged()
	session.step()
	eq(st.shownKey, 115, 'lr off: shown')
	eq(st.shownResult.ephemeral, false, 'lr off: cache result shown')
	eq(exists(eph[1]), false, 'lr off: old ephemeral overview deleted')
	eq(exists(eph[2]), false, 'lr off: old ephemeral crop deleted')

	-- Deferred tasks (closer to Lightroom): an on-demand render runs in its
	-- own task, so hits keep being shown while it is in flight, a stale
	-- result is stored but not shown, and at most 2 renders run at once.
	local queue = {}
	local realStart = stubs.LrTasks.startAsyncTask
	stubs.LrTasks.startAsyncTask = function(fn)
		queue[#queue + 1] = fn
	end
	local fresh = {}
	for i = 1, 3 do
		fresh[i] = makePhoto({ id = 200 + i, path = root .. '/photos/F' .. i .. '.ARW' })
	end
	catalog.target = fresh[1]
	session.step()
	advance(0.1)
	session.step()
	eq(#queue, 1, 'deferred: render task started for the miss')
	eq(st.inflight[201], true, 'deferred: miss in flight')
	catalog.target = photos[6]
	session.step()
	eq(st.shownKey, 106, 'deferred: hit shown while a render is in flight')
	catalog.target = fresh[2]
	session.step()
	advance(0.1)
	session.step()
	catalog.target = fresh[3]
	session.step()
	advance(0.1)
	session.step()
	eq(#queue, 2, 'deferred: third miss waits (MAX_ONDEMAND = 2)')
	eq(session.prefetchStep(), Viewer.TIMING.POLL_INTERVAL, 'deferred: prefetch yields to on-demand renders')
	queue[1]()
	queue[2]()
	queue = {}
	eq(st.results[201] ~= nil and st.results[202] ~= nil, true, 'deferred: stale results kept for later')
	eq(st.shownKey, 106, 'deferred: stale results not shown')
	eq(st.onDemand, 0, 'deferred: counters back to 0')
	session.step()
	eq(#queue, 1, 'deferred: waiting miss starts once a slot is free')
	queue[1]()
	queue = {}
	eq(st.shownKey, 203, 'deferred: current target shown when its render finishes')
	catalog.target = fresh[1]
	session.step()
	eq(st.shownKey, 201, 'deferred: earlier stale render is now a hit')
	stubs.LrTasks.startAsyncTask = realStart

	-- Close: loops see `closed`, nothing ephemeral left to delete.
	local leftover = session.close()
	eq(#leftover, 0, 'close: no ephemeral files')
	eq(st.closed, true, 'close: closed')
	eq(session.prefetchStep(), 0, 'close: prefetch stops')
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

	-- v0.2: render cache, batch, viewer session against the real CLI.
	local cacheDir = root .. '/cache'
	sh("mkdir -p '" .. cacheDir .. "'")
	-- The CLI reports canonical paths (/tmp -> /private/tmp on macOS).
	local realCacheDir = io.popen("cd '" .. cacheDir .. "' && pwd -P"):read('*l') or cacheDir
	for pass = 1, 2 do
		local r = Cli.analyze(photo, { render = true, cacheDir = cacheDir, boxW = 640, boxH = 480, cropSize = 400 })
		print(string.format('cache pass %d: kind=%s cached=%s calls=%s exec=%dms size=%s overview=%s',
			pass, tostring(r.kind), tostring(r.cached), tostring(r.timing.calls), Core.ms(r.timing.exec),
			tostring(r.size), tostring(r.overview)))
		eq(r.ephemeral, false, 'real cache: not ephemeral')
		if r.kind == 'ok' or r.kind == 'no_focus' then
			eq(exists(r.overview), 'file', 'real cache: overview exists')
			eq(string.sub(r.overview, 1, #realCacheDir), realCacheDir, 'real cache: overview inside the cache dir')
			if pass == 2 then
				eq(r.cached, true, 'real cache: second call is a cache hit')
				eq(r.timing.calls, 1, 'real cache: one call')
			end
		end
	end

	local photos = {}
	local n = 0
	for _, img in ipairs(realImages) do
		n = n + 1
		photos[n] = makePhoto({ id = n, path = img, createFile = false })
	end
	local paths = {}
	for i, img in ipairs(realImages) do
		paths[i] = img
	end
	local blocks, meta = Cli.batch(paths, { cacheDir = cacheDir, size = 640, cropSize = 400 })
	print(string.format('batch: %d files -> %d blocks, exit=%s, %d ms', #paths, #blocks, tostring(meta.code), Core.ms(meta.elapsed)))
	eq(#blocks, #paths, 'real batch: one block per file')
	for i, b in ipairs(blocks) do
		eq(b.file, paths[i], 'real batch: input order #' .. i)
		print(string.format('  %s status=%s cached=%s source=%s', Core.leafName(b.file), tostring(b.status),
			tostring(b.cached), tostring(b.source)))
	end
	local blocks2, meta2 = Cli.batch(paths, { cacheDir = cacheDir, size = 640, cropSize = 400 })
	print(string.format('batch again: %d ms', Core.ms(meta2.elapsed)))
	for _, b in ipairs(blocks2) do
		if b.status == 'ok' or b.status == 'no_focus' then
			eq(b.cached, 'true', 'real batch: second batch is cached (' .. Core.leafName(b.file) .. ')')
		end
	end

	if n > 1 then
		local catalog = { target = photos[1] }
		function catalog:getTargetPhoto()
			return self.target
		end
		function catalog:getMultipleSelectedOrAllPhotos()
			return photos
		end
		function catalog:batchGetRawMetadata(list, keys)
			local out = {}
			for _, p in ipairs(list) do
				local m = {}
				for _, k in ipairs(keys) do
					m[k] = p:getRawMetadata(k)
				end
				out[p] = m
			end
			return out
		end
		local props = { useLrPreview = false, prefetchNote = '' }
		Viewer.initProps(props)
		local session = Viewer.newSession(catalog, props, { cacheDir = root .. '/vcache' })
		local st = session.state
		session.step()
		advance(0.1)
		session.step()
		eq(st.shownKey, 1, 'real session: first photo shown')
		local rounds = 0
		repeat
			rounds = rounds + 1
		until session.prefetchStep() > 0 or rounds > 50
		print('  prefetch: ' .. tostring(props.prefetchNote))
		for i = 2, n do
			catalog.target = photos[i]
			session.step()
			local res = st.results[i]
			if res then
				eq(st.shownKey, i, 'real session: hit shown at once #' .. i)
			else
				print('  (no cached result for ' .. realImages[i] .. ', e.g. unsupported/error)')
			end
		end
		for _, l in ipairs(logLines) do
			if string.find(l, 'timing:', 1, true) then
				print('  ' .. l)
			end
		end
		session.close()
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
