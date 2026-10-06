--[[----------------------------------------------------------------------------
FocusPointCli.lua

Everything that talks to the `focuspoint` CLI or to the file system:
  * locating / checking the binary (bin/focuspoint, bin/focuspoint.exe on Win)
  * running it with LrTasks.execute, stdout/stderr redirected to temp files
  * exporting a Lightroom preview (photo:requestJpegThumbnail) as --source
  * the whole "analyse one photo" pipeline used by the viewer and the modal
  * `focuspoint batch` (prefetch / Read Focus Metadata)
  * the persistent render cache dir and cleaning up old (non-cache) output

Render cache (SPEC v0.2): `render --cache-dir` / `batch --cache-dir` keep
their output in Cli.cacheDir() under stable names keyed by (file, size,
mtime, --size, --crop-size). Those files belong to the cache and must never
be deleted by the plug-in (the CLI prunes the cache itself, LRU). Results
rendered with --source (Lightroom preview) bypass the cache, go to
Cli.renderDir() with unique names and are marked `ephemeral`: whoever shows
them deletes them afterwards.

All functions that call the SDK's photo/catalog/LrTasks APIs must run inside
an LrTasks async task.
------------------------------------------------------------------------------]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local Core = require 'FocusPointCore'
local log = require 'FocusPointLog'

local Cli = {}

-- Requested Lightroom preview size (long edge). Request sizes are minimums;
-- Lightroom may return something larger (e.g. a 1:1 preview).
Cli.PREVIEW_REQUEST_SIZE = 2560
-- Seconds to wait for requestJpegThumbnail's callback before giving up and
-- letting the CLI use the embedded preview instead.
Cli.PREVIEW_TIMEOUT = 8

local counter = 0

local function nextId()
	counter = counter + 1
	-- LrDate.currentTime(): seconds since 2001-01-01 (fractional).
	return string.format('%.0f-%d', math.floor(LrDate.currentTime() * 1000), counter)
end

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

function Cli.binaryPath()
	local name = WIN_ENV and 'focuspoint.exe' or 'focuspoint'
	return LrPathUtils.child(LrPathUtils.child(_PLUGIN.path, 'bin'), name)
end

local function ensureDir(path)
	if LrFileUtils.exists(path) ~= 'directory' then
		LrFileUtils.createAllDirectories(path)
	end
	return path
end

--- <temp>/focuspoint
function Cli.workDir()
	return ensureDir(LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'focuspoint'))
end

--- <temp>/focuspoint/renders (passed to the CLI as --out-dir)
function Cli.renderDir()
	return ensureDir(LrPathUtils.child(Cli.workDir(), 'renders'))
end

--- Persistent render cache (--cache-dir):
-- macOS ~/Library/Caches/focuspoint, Windows <temp>/focuspoint/cache.
function Cli.cacheDirPath()
	if WIN_ENV then
		return LrPathUtils.child(LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'focuspoint'), 'cache')
	end
	local home = LrPathUtils.getStandardFilePath('home')
	return LrPathUtils.child(LrPathUtils.child(LrPathUtils.child(home, 'Library'), 'Caches'), 'focuspoint')
end

function Cli.cacheDir()
	return ensureDir(Cli.cacheDirPath())
end

Cli.INSTALL_HINT = 'Reinstall the plug-in with `nix run .#install` from the lr-focus-point '
	.. 'repository (it copies bin/focuspoint into the plug-in), then restart Lightroom '
	.. 'or reload the plug-in in File > Plug-in Manager.'

--- Returns true, or false plus a user-facing message.
function Cli.checkBinary()
	local bin = Cli.binaryPath()
	if LrFileUtils.exists(bin) ~= 'file' then
		return false, 'The focuspoint helper program is missing:\n' .. bin .. '\n\n' .. Cli.INSTALL_HINT
	end
	return true
end

--------------------------------------------------------------------------------
-- Small file helpers
--------------------------------------------------------------------------------

local function readFile(path)
	if not path or LrFileUtils.exists(path) ~= 'file' then
		return nil
	end
	-- LrFileUtils.readFile copes with non-ASCII paths better than io.open.
	local ok, data = pcall(LrFileUtils.readFile, path)
	if ok and type(data) == 'string' then
		return data
	end
	local f = io.open(path, 'rb')
	if not f then
		return nil
	end
	data = f:read('*a')
	f:close()
	return data
end

local function writeFile(path, data)
	local f, err = io.open(path, 'wb')
	if not f then
		return false, err
	end
	local ok, werr = f:write(data)
	f:close()
	if not ok then
		return false, werr
	end
	return true
end

function Cli.deleteFile(path)
	if path and path ~= '' and LrFileUtils.exists(path) == 'file' then
		local ok, err = LrFileUtils.delete(path)
		if not ok then
			log:warnf('Could not delete %s: %s', path, tostring(err))
		end
	end
end

--- Delete render outputs older than `maxAgeSeconds`.
-- fileAttributes().fileModificationDate is documented only as "The
-- modification date"; we assume a Cocoa timestamp comparable with
-- LrDate.currentTime() and skip files where it isn't a number.
function Cli.cleanupRenders(maxAgeSeconds)
	local ok, err = LrTasks.pcall(function()
		local now = LrDate.currentTime()
		local victims = {}
		-- Render output plus stray temp files (preview/stdout/stderr) that a
		-- crash may have left behind in the work dir.
		for _, dir in ipairs({ Cli.renderDir(), Cli.workDir() }) do
			-- Collect first: the SDK says not to `break` out of LrFileUtils.files.
			for path in LrFileUtils.files(dir) do
				local attrs = LrFileUtils.fileAttributes(path)
				local mod = attrs and attrs.fileModificationDate
				if type(mod) == 'number' and now - mod > maxAgeSeconds then
					victims[#victims + 1] = path
				end
			end
		end
		for _, path in ipairs(victims) do
			LrFileUtils.delete(path)
		end
		if #victims > 0 then
			log:infof('Cleaned up %d old render file(s)', #victims)
		end
	end)
	if not ok then
		log:warnf('Render cleanup failed: %s', tostring(err))
	end
end

--------------------------------------------------------------------------------
-- Running the CLI
--------------------------------------------------------------------------------

--- Run the binary with `args`; returns stdout, stderr, normalised exit code
-- and the elapsed wall time in seconds.
-- Must be called from an async task. LrTasks.execute "blocks only the task
-- that calls it", so several tasks may each run the CLI at the same time.
function Cli.exec(args)
	local work = Cli.workDir()
	local id = nextId()
	local outFile = LrPathUtils.child(work, 'out-' .. id .. '.txt')
	local errFile = LrPathUtils.child(work, 'err-' .. id .. '.txt')

	local cmd = Core.buildCommand(Cli.binaryPath(), args, outFile, errFile, WIN_ENV)
	log:debugf('exec: %s', cmd)
	local started = LrDate.currentTime()
	local rc = LrTasks.execute(cmd)
	local elapsed = LrDate.currentTime() - started

	local out = readFile(outFile)
	local err = readFile(errFile)
	Cli.deleteFile(outFile)
	Cli.deleteFile(errFile)

	local code = Core.exitCode(rc)
	log:debugf('focuspoint %s -> rc=%s (%d ms)', tostring(args[1]), tostring(rc), Core.ms(elapsed))
	if err and err ~= '' then
		log:debugf('stderr: %s', err)
	end
	return out, err, code, elapsed
end

--- `focuspoint --version` (first line), or nil.
function Cli.version()
	if not Cli.checkBinary() then
		return nil
	end
	local out = Cli.exec({ '--version' })
	if out then
		return string.match(out, '^%s*([^\r\n]+)')
	end
	return nil
end

--- Run `focuspoint <args...> --format kv`. Always returns a table; on
-- failure `status` is 'error' and `message` explains why.
-- Extra fields: _code (normalised exit code), _stderr, _elapsed (seconds),
-- _nocli (binary missing / not executable).
function Cli.run(args)
	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		return { status = 'error', message = binMsg, _nocli = true }
	end

	local fullArgs = {}
	for i = 1, #args do
		fullArgs[i] = args[i]
	end
	fullArgs[#fullArgs + 1] = '--format'
	fullArgs[#fullArgs + 1] = 'kv'

	local out, err, code, elapsed = Cli.exec(fullArgs)
	local result = Core.parseKv(out)
	result._code = code
	result._stderr = err
	result._elapsed = elapsed
	log:infof('focuspoint %s -> exit=%s status=%s cached=%s (%d ms)', tostring(args[1]), tostring(code),
		tostring(result.status), tostring(result.cached), Core.ms(elapsed))

	if not result.status then
		result.status = 'error'
		result.message = Core.describeExecFailure(code, err)
		if code == 126 or code == 127 then
			result._nocli = true
			result.message = result.message .. '\n\n' .. Cli.INSTALL_HINT
		end
	end
	return result
end

function Cli.info(path)
	return Cli.run({ 'info', path })
end

--- opts: cacheDir or outDir, source (optional), size, cropSize.
-- With a --source the CLI bypasses the cache, so --out-dir is used then.
function Cli.render(path, opts)
	local args = { 'render', path }
	if opts.cacheDir and not opts.source then
		args[#args + 1] = '--cache-dir'
		args[#args + 1] = opts.cacheDir
	else
		args[#args + 1] = '--out-dir'
		args[#args + 1] = opts.outDir or Cli.renderDir()
	end
	if opts.source then
		args[#args + 1] = '--source'
		args[#args + 1] = opts.source
	end
	if opts.size then
		args[#args + 1] = '--size'
		args[#args + 1] = tostring(math.floor(opts.size))
	end
	if opts.cropSize then
		args[#args + 1] = '--crop-size'
		args[#args + 1] = tostring(math.floor(opts.cropSize))
	end
	return Cli.run(args)
end

--- `focuspoint batch --cache-dir <dir> --list <tmpfile> ...` for `paths`.
-- opts: cacheDir (required), size, cropSize, jobs.
-- Returns blocks (array of kv tables, each with `file`, see
-- Core.parseKvBlocks) and a meta table { code, stderr, elapsed, nocli,
-- message (set when no block came back) }.
-- Paths containing a newline can't be listed; callers must leave them out.
function Cli.batch(paths, opts)
	local meta = { elapsed = 0 }
	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		meta.nocli = true
		meta.message = binMsg
		return {}, meta
	end
	if #paths == 0 then
		return {}, meta
	end
	local listFile = LrPathUtils.child(Cli.workDir(), 'list-' .. nextId() .. '.txt')
	local wrote, werr = writeFile(listFile, table.concat(paths, '\n') .. '\n')
	if not wrote then
		meta.message = 'could not write the batch list: ' .. tostring(werr)
		return {}, meta
	end
	local args = { 'batch', '--cache-dir', opts.cacheDir, '--list', listFile }
	if opts.size then
		args[#args + 1] = '--size'
		args[#args + 1] = tostring(math.floor(opts.size))
	end
	if opts.cropSize then
		args[#args + 1] = '--crop-size'
		args[#args + 1] = tostring(math.floor(opts.cropSize))
	end
	if opts.jobs then
		args[#args + 1] = '--jobs'
		args[#args + 1] = tostring(math.floor(opts.jobs))
	end
	args[#args + 1] = '--format'
	args[#args + 1] = 'kv'
	local out, err, code, elapsed = Cli.exec(args)
	Cli.deleteFile(listFile)
	local blocks = Core.parseKvBlocks(out)
	meta.code = code
	meta.stderr = err
	meta.elapsed = elapsed
	if #blocks == 0 then
		meta.message = Core.describeExecFailure(code, err)
		meta.nocli = code == 126 or code == 127
		log:warnf('focuspoint batch (%d files) returned nothing: %s', #paths, meta.message)
	end
	return blocks, meta
end

--------------------------------------------------------------------------------
-- Photo checks
--------------------------------------------------------------------------------

--- Inspect a photo before running the CLI.
-- Returns a table { ok = bool, kind = 'video'|'missing'|..., message,
-- path, fileName }.
function Cli.checkPhoto(photo)
	local state = {}
	if not photo then
		state.kind = 'none'
		state.message = 'No photo selected.'
		return state
	end
	state.fileName = photo:getFormattedMetadata('fileName')
	state.path = photo:getRawMetadata('path')

	local format = photo:getRawMetadata('fileFormat')
	if format == 'VIDEO' or photo:getRawMetadata('isVideo') == true then
		state.kind = 'video'
		state.message = 'Video files have no focus point to show.'
		return state
	end

	if not state.path or LrFileUtils.exists(state.path) ~= 'file' then
		state.kind = 'missing'
		state.message = 'The original file is offline or missing, so its focus data cannot be read'
			.. (state.path and (':\n' .. state.path) or '.')
		return state
	end

	state.ok = true
	return state
end

--------------------------------------------------------------------------------
-- Lightroom preview as --source
--------------------------------------------------------------------------------

-- Request objects returned by requestJpegThumbnail must stay referenced until
-- their callback fires (SDK: "Hold a reference to this object until your
-- callback is called, then release it."). Entries are removed by the
-- callback; one only lingers if Lightroom never calls back.
local pendingThumbRequests = {}

--- Is it safe to treat the Lightroom preview as the full, uncropped frame in
-- camera orientation? Returns true or false plus a reason (for the log).
function Cli.previewUsable(photo)
	local ok, settings = LrTasks.pcall(function()
		return photo:getDevelopSettings()
	end)
	if not ok or type(settings) ~= 'table' then
		return false, 'develop settings unavailable'
	end
	-- HasCrop is not in the SDK 6 docs' develop-settings list but is present
	-- in current Lightroom Classic; isCropped (getRawMetadata, SDK 2.0) and
	-- the crop rectangle are checked too in case it is missing.
	if settings.HasCrop == true then
		return false, 'photo has a Develop crop'
	end
	if photo:getRawMetadata('isCropped') == true then
		return false, 'photo is cropped'
	end
	local angle = tonumber(settings.CropAngle)
	if angle and math.abs(angle) > 0.001 then
		return false, 'photo is straightened (CropAngle)'
	end
	local function off(v, default)
		v = tonumber(v)
		return v ~= nil and math.abs(v - default) > 0.0005
	end
	if off(settings.CropLeft, 0) or off(settings.CropTop, 0)
		or off(settings.CropRight, 1) or off(settings.CropBottom, 1) then
		return false, 'crop rectangle is not the full frame'
	end
	-- Upright / manual Transform warps the frame. Key names are those used by
	-- current Lightroom Classic develop settings (not in the SDK 6 docs);
	-- missing keys are simply ignored.
	local transformKeys = {
		'PerspectiveVertical', 'PerspectiveHorizontal', 'PerspectiveRotate',
		'PerspectiveAspect', 'PerspectiveX', 'PerspectiveY',
	}
	for _, key in ipairs(transformKeys) do
		local v = tonumber(settings[key])
		if v and math.abs(v) > 0.001 then
			return false, 'Transform (' .. key .. ') is applied'
		end
	end
	local upright = tonumber(settings.PerspectiveUpright)
	if upright and upright ~= 0 then
		return false, 'Upright transform is applied'
	end
	local scale = tonumber(settings.PerspectiveScale)
	if scale and math.abs(scale - 100) > 0.001 then
		return false, 'Transform scale is applied'
	end
	return true
end

--- Ask Lightroom for a large JPEG preview and write it to a temp file.
-- Returns path, width, height on success or nil, reason.
function Cli.exportLrPreview(photo)
	local id = nextId()
	local state = { done = false }

	local function callback(data, errMsg)
		-- Guard: callbacks have been reported to fire more than once.
		if state.done then
			return
		end
		state.done = true
		state.data = data
		state.err = errMsg
		pendingThumbRequests[id] = nil
	end

	local ok, request = LrTasks.pcall(function()
		return photo:requestJpegThumbnail(Cli.PREVIEW_REQUEST_SIZE, Cli.PREVIEW_REQUEST_SIZE, callback)
	end)
	if not ok then
		return nil, 'requestJpegThumbnail failed: ' .. tostring(request)
	end
	-- The callback may already have run synchronously (cached preview).
	if not state.done then
		pendingThumbRequests[id] = request
	end

	local waited = 0
	while not state.done and waited < Cli.PREVIEW_TIMEOUT do
		LrTasks.sleep(0.05)
		waited = waited + 0.05
	end
	request = nil -- local reference no longer needed; table keeps it if pending

	if not state.done then
		return nil, string.format('no preview after %.1fs', Cli.PREVIEW_TIMEOUT)
	end
	local data = state.data
	state.data = nil
	if type(data) ~= 'string' or #data == 0 then
		return nil, 'no preview data: ' .. tostring(state.err)
	end

	local w, h = Core.jpegSize(data)
	local path = LrPathUtils.child(Cli.workDir(), 'src-' .. id .. '.jpg')
	local wrote, werr = writeFile(path, data)
	data = nil
	if not wrote then
		return nil, 'could not write preview: ' .. tostring(werr)
	end
	return path, w, h
end

--------------------------------------------------------------------------------
-- Result building
--------------------------------------------------------------------------------

--- Turn a render (or batch block) kv table into a result table as returned
-- by Cli.analyze. ctx: path, fileName, size (the --size used), ephemeral
-- (files are unique per call and must be deleted by whoever shows them),
-- sourceNote (pre-set reason, kept when the embedded preview was used),
-- aspect (fallback when the CLI reports no source size).
function Cli.resultFromKv(kv, ctx)
	ctx = ctx or {}
	kv = kv or {}
	local result = {
		info = kv,
		path = ctx.path or kv.file,
		fileName = ctx.fileName or Core.leafName(ctx.path or kv.file),
		size = ctx.size,
		ephemeral = ctx.ephemeral and true or false,
		cached = kv.cached == 'true',
		aspect = ctx.aspect,
	}
	if kv._nocli then
		result.kind = 'nocli'
		result.message = kv.message
		return result
	end

	result.overview = kv.overview
	result.crop = kv.crop
	if result.overview and LrFileUtils.exists(result.overview) ~= 'file' then
		result.overview = nil
	end
	if result.crop and LrFileUtils.exists(result.crop) ~= 'file' then
		result.crop = nil
	end
	-- Pick the viewer's landscape/portrait slot from the overview actually
	-- drawn (display orientation).
	local sw, sh = Core.num(kv.source_width), Core.num(kv.source_height)
	if sw and sh and sw > 0 and sh > 0 then
		result.aspect = sw / sh
	end
	if kv.source == 'provided' then
		result.sourceNote = 'Lightroom preview'
	elseif kv.source == 'embedded_preview' then
		result.sourceNote = ctx.sourceNote or 'embedded preview'
	elseif kv.source == 'image' then
		result.sourceNote = 'image file'
	end

	if kv.status == 'ok' then
		result.kind = 'ok'
	elseif kv.status == 'no_focus' then
		result.kind = 'no_focus'
		result.message = kv.message or 'The camera recorded no focus point for this photo.'
	elseif kv.status == 'unsupported' then
		result.kind = 'unsupported'
		result.message = kv.message or 'No focus information: this file is not a supported Sony ARW/JPEG/HEIF.'
	else
		result.kind = 'error'
		result.message = kv.message or 'The focuspoint helper reported an error.'
	end
	return result
end

--- Image files of a result (overview, crop) that exist on disk.
function Cli.resultFiles(result)
	local files = {}
	if result and result.overview then
		files[#files + 1] = result.overview
	end
	if result and result.crop then
		files[#files + 1] = result.crop
	end
	return files
end

--- Is a stored (cache) result still showable? Its image files must exist –
-- the CLI's LRU prune may have removed them.
function Cli.resultFilesExist(result)
	if type(result) ~= 'table' then
		return false
	end
	if result.overview and LrFileUtils.exists(result.overview) ~= 'file' then
		return false
	end
	if result.crop and LrFileUtils.exists(result.crop) ~= 'file' then
		return false
	end
	return true
end

--- Can this result be kept in an in-memory cache (and shown again later)?
-- Only CLI-cache-backed outcomes that depend on the file alone.
function Cli.isCacheable(result)
	if type(result) ~= 'table' or result.ephemeral then
		return false
	end
	local k = result.kind
	if k == 'unsupported' then
		return true
	end
	return (k == 'ok' or k == 'no_focus') and result.overview ~= nil
end

--------------------------------------------------------------------------------
-- Full pipeline
--------------------------------------------------------------------------------

local function guessAspect(photo)
	local ok, a = LrTasks.pcall(function()
		return photo:getRawMetadata('aspectRatio')
	end)
	return ok and tonumber(a) or nil
end

--- Analyse a photo and (optionally) render images.
-- opts:
--   render       (bool)  render images (otherwise `info` only)
--   cacheDir     (string) use the CLI render cache (one `render` call, no
--                `info`) unless a Lightroom preview is used
--   useLrPreview (bool)  try a Lightroom preview as --source (HEIF files
--                always do: the CLI can't decode HEVC)
--   boxW, boxH   (number) overview box; --size is chosen so the image fits
--   size         (number, optional) --size to try first (cache mode)
--   cropSize     (number)
--   isCancelled  (function, optional) return true to abandon early
--                (only consulted on the Lightroom-preview path)
-- Returns a result table:
--   kind     'ok' | 'no_focus' | 'unsupported' | 'error' | 'video' |
--            'missing' | 'nocli' | 'none' | 'cancelled'
--   message  user-facing text for anything but 'ok'
--   info     parsed CLI output (render output when rendering)
--   overview, crop  image paths (render only, may be nil)
--   fileName, path, aspect, size
--   ephemeral  true when overview/crop are unique files the caller deletes
--              (false: they live in the render cache – never delete them)
--   cached     the CLI served the render from its cache
--   sourceNote short note about which image source was used
--   timing     { total, exec, preview, calls } (seconds / count)
function Cli.analyze(photo, opts)
	opts = opts or {}
	local started = LrDate.currentTime()
	local timing = { exec = 0, preview = 0, calls = 0 }
	local cancelled = opts.isCancelled or function()
		return false
	end
	local function finish(r)
		timing.total = LrDate.currentTime() - started
		r.timing = timing
		return r
	end
	local function run(kv)
		timing.calls = timing.calls + 1
		timing.exec = timing.exec + (kv._elapsed or 0)
		return kv
	end

	local check = Cli.checkPhoto(photo)
	local result = { fileName = check.fileName, path = check.path }
	if not check.ok then
		result.kind = check.kind
		result.message = check.message
		return finish(result)
	end

	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		result.kind = 'nocli'
		result.message = binMsg
		return finish(result)
	end

	local boxW = opts.boxW or 640
	local boxH = opts.boxH or 480
	local cropSize = opts.cropSize or 400
	local heif = Core.isHeifPath(check.path)
	local ctx = { path = check.path, fileName = check.fileName }

	-- A. Fast path: one cached `render` call (no `info`, no Lr preview).
	if opts.render and opts.cacheDir and not opts.useLrPreview and not heif then
		local size = opts.size or Core.guessOverviewSize(guessAspect(photo), boxW, boxH)
		ctx.size = size
		local kv = run(Cli.render(check.path, { cacheDir = opts.cacheDir, size = size, cropSize = cropSize }))
		local r = Cli.resultFromKv(kv, ctx)
		-- The size was a guess (Lightroom's aspect can differ from the
		-- camera's, e.g. rotated in Lightroom): render again at the size that
		-- fills the box once the real aspect is known. Only once.
		local preferred = r.overview and r.aspect and Core.preferredOverviewSize(r.aspect, boxW, boxH)
		if preferred and preferred ~= size then
			log:infof('%s: overview size %d -> %d (aspect %.4f)', tostring(check.fileName), size, preferred, r.aspect)
			local ctx2 = { path = check.path, fileName = check.fileName, size = preferred }
			local r2 = Cli.resultFromKv(run(Cli.render(check.path, {
				cacheDir = opts.cacheDir, size = preferred, cropSize = cropSize,
			})), ctx2)
			if r2.kind ~= 'error' and r2.kind ~= 'nocli' then
				r = r2
			end
		end
		if not (r.kind == 'error' and kv.file_type == 'heif') then
			return finish(r)
		end
		-- A HEIF file without a HEIF extension: needs a Lightroom preview.
		heif = true
	end

	-- B. Metadata first (needed to validate a Lightroom preview and to
	--    choose --size), then render, optionally on a Lightroom preview.
	local info = run(Cli.info(check.path))
	result.info = info
	if info._nocli then
		result.kind = 'nocli'
		result.message = info.message
		return finish(result)
	end
	if info.status == 'unsupported' then
		result.kind = 'unsupported'
		result.message = info.message
			or 'No focus information: this file is not a supported Sony ARW/JPEG/HEIF.'
		return finish(result)
	end
	if info.status == 'error' then
		result.kind = 'error'
		result.message = info.message or 'The focuspoint helper reported an error.'
		return finish(result)
	end
	if not opts.render then
		result.kind = info.status == 'ok' and 'ok' or 'no_focus'
		if result.kind == 'no_focus' then
			result.message = info.message or 'The camera recorded no focus point for this photo.'
		end
		return finish(result)
	end
	if cancelled() then
		result.kind = 'cancelled'
		return finish(result)
	end

	local aspect = Core.displayedAspect(info)
	local sourcePath
	local sourceNote
	if opts.useLrPreview or heif then
		local usable, why = Cli.previewUsable(photo)
		if usable then
			local t0 = LrDate.currentTime()
			local p, pw, ph = Cli.exportLrPreview(photo)
			timing.preview = LrDate.currentTime() - t0
			if not p then
				log:infof('%s: not using Lr preview (%s)', tostring(check.fileName), tostring(pw))
				sourceNote = 'embedded preview'
			elseif aspect and not (pw and ph and Core.aspectMatches(pw / ph, aspect)) then
				-- Most likely the user rotated the photo in Lightroom (the
				-- focus coordinates are in camera orientation), or the preview
				-- is otherwise not the camera's full frame.
				log:infof('%s: Lr preview %sx%s does not match camera aspect %.4f; using embedded preview',
					tostring(check.fileName), tostring(pw), tostring(ph), aspect)
				Cli.deleteFile(p)
				sourceNote = 'embedded preview (Lightroom preview is rotated or reshaped)'
			else
				sourcePath = p
				if not aspect and pw and ph then
					aspect = pw / ph
				end
			end
		else
			log:infof('%s: not using Lr preview (%s)', tostring(check.fileName), tostring(why))
			sourceNote = 'embedded preview (' .. tostring(why) .. ')'
		end
	end
	if cancelled() then
		Cli.deleteFile(sourcePath)
		result.kind = 'cancelled'
		return finish(result)
	end

	if not aspect then
		-- Last resort for choosing --size: Lightroom's own aspect ratio.
		aspect = guessAspect(photo)
	end

	local size = Core.fitLongEdge(aspect, boxW, boxH)
	ctx.size = size
	ctx.aspect = aspect
	ctx.sourceNote = sourceNote
	ctx.ephemeral = sourcePath ~= nil or not opts.cacheDir
	local rendered = run(Cli.render(check.path, {
		cacheDir = opts.cacheDir,
		source = sourcePath,
		size = size,
		cropSize = cropSize,
	}))
	Cli.deleteFile(sourcePath)

	if rendered.status == 'error' and sourcePath and not rendered._nocli then
		-- Try once more without the Lightroom preview.
		log:warnf('%s: render with Lr preview failed (%s); retrying with embedded preview',
			tostring(check.fileName), tostring(rendered.message))
		local retryAspect = Core.displayedAspect(info) or aspect
		ctx.aspect = retryAspect
		ctx.size = Core.fitLongEdge(retryAspect, boxW, boxH)
		ctx.ephemeral = not opts.cacheDir
		ctx.sourceNote = 'embedded preview'
		rendered = run(Cli.render(check.path, {
			cacheDir = opts.cacheDir,
			size = ctx.size,
			cropSize = cropSize,
		}))
	end

	return finish(Cli.resultFromKv(rendered, ctx))
end

--- Analyse many photos with as few CLI calls as possible (Read Focus
-- Metadata): `focuspoint batch` through the render cache, grouped by the
-- overview size the floating viewer would use, so it also warms the cache
-- for the viewer. HEIF files, and any group the batch call fails for (e.g.
-- an older helper without `batch`), fall back to one `info` call per photo.
-- opts: cacheDir, boxW, boxH, cropSize.
-- Returns an array of result tables (see Cli.analyze) aligned with `photos`.
function Cli.analyzeBatch(photos, opts)
	local results = {}
	local groups, sizes = {}, {}
	for i, photo in ipairs(photos) do
		local check = Cli.checkPhoto(photo)
		if not check.ok then
			results[i] = { kind = check.kind, message = check.message, fileName = check.fileName, path = check.path }
		elseif Core.isHeifPath(check.path) or string.find(check.path, '[\r\n]') then
			results[i] = Cli.analyze(photo, { render = false })
		else
			local size = Core.guessOverviewSize(guessAspect(photo), opts.boxW or 640, opts.boxH or 480)
			local g = groups[size]
			if not g then
				g = {}
				groups[size] = g
				sizes[#sizes + 1] = size
			end
			g[#g + 1] = { index = i, photo = photo, path = check.path, fileName = check.fileName }
		end
	end
	table.sort(sizes)
	for _, size in ipairs(sizes) do
		local g = groups[size]
		local paths, seen = {}, {}
		for _, e in ipairs(g) do
			if not seen[e.path] then
				seen[e.path] = true
				paths[#paths + 1] = e.path
			end
		end
		local blocks, meta = Cli.batch(paths, { cacheDir = opts.cacheDir, size = size, cropSize = opts.cropSize })
		log:infof('timing: batch purpose=metadata n=%d size=%d blocks=%d exec_ms=%d',
			#paths, size, #blocks, Core.ms(meta.elapsed))
		local byFile = {}
		for _, b in ipairs(blocks) do
			byFile[b.file] = b
		end
		for _, e in ipairs(g) do
			local b = byFile[e.path]
			-- A per-file render error may still have readable metadata:
			-- those fall back to `info` below.
			if b and b.status ~= 'error' then
				results[e.index] = Cli.resultFromKv(b, { path = e.path, fileName = e.fileName, size = size })
			elseif meta.nocli then
				results[e.index] = { kind = 'nocli', message = meta.message, fileName = e.fileName, path = e.path }
			else
				results[e.index] = Cli.analyze(e.photo, { render = false })
			end
		end
	end
	return results
end

return Cli
