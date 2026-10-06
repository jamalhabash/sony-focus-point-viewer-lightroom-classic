--[[----------------------------------------------------------------------------
FocusPointCli.lua

Everything that talks to the `focuspoint` CLI or to the file system:
  * locating / checking the binary (bin/focuspoint, bin/focuspoint.exe on Win)
  * running it with LrTasks.execute, stdout/stderr redirected to temp files
  * exporting a Lightroom preview (photo:requestJpegThumbnail) as --source
  * the whole "analyse one photo" pipeline used by the viewer and the modal
  * cleaning up old render output

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

--- Run `focuspoint <args...> --format kv`. Always returns a table; on
-- failure `status` is 'error' and `message` explains why.
-- Extra fields: _code (normalised exit code), _stderr.
--- Run the binary with `args`; returns stdout, stderr, normalised exit code.
-- Must be called from an async task (LrTasks.execute yields).
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
	log:debugf('focuspoint %s -> rc=%s (%.2fs)', tostring(args[1]), tostring(rc), elapsed)
	if err and err ~= '' then
		log:debugf('stderr: %s', err)
	end
	return out, err, code
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

	local out, err, code = Cli.exec(fullArgs)
	local result = Core.parseKv(out)
	result._code = code
	result._stderr = err
	log:infof('focuspoint %s -> exit=%s status=%s', tostring(args[1]), tostring(code), tostring(result.status))

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

--- opts: outDir, source (optional), size, cropSize
function Cli.render(path, opts)
	local args = { 'render', path, '--out-dir', opts.outDir or Cli.renderDir() }
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
-- Full pipeline
--------------------------------------------------------------------------------

--- Analyse a photo and (optionally) render images.
-- opts:
--   render       (bool)  run `render` (otherwise `info` only)
--   useLrPreview (bool)  try a Lightroom preview as --source
--   boxW, boxH   (number) overview box; --size is chosen so the image fits
--   cropSize     (number)
--   isCancelled  (function, optional) return true to abandon early
-- Returns a result table:
--   kind     'ok' | 'no_focus' | 'unsupported' | 'error' | 'video' |
--            'missing' | 'nocli' | 'none' | 'cancelled'
--   message  user-facing text for anything but 'ok'
--   info     parsed CLI output (render output when rendering)
--   overview, crop  image paths (render only, may be nil)
--   fileName, path
--   sourceNote  short note about which image source was used
function Cli.analyze(photo, opts)
	opts = opts or {}
	local cancelled = opts.isCancelled or function()
		return false
	end

	local check = Cli.checkPhoto(photo)
	local result = { fileName = check.fileName, path = check.path }
	if not check.ok then
		result.kind = check.kind
		result.message = check.message
		return result
	end

	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		result.kind = 'nocli'
		result.message = binMsg
		return result
	end

	-- 1. Metadata only (fast): tells us whether there is anything to draw and
	--    the displayed aspect, which we need to validate the Lr preview and to
	--    choose --size.
	local info = Cli.info(check.path)
	result.info = info
	if info._nocli then
		result.kind = 'nocli'
		result.message = info.message
		return result
	end
	if info.status == 'unsupported' then
		result.kind = 'unsupported'
		result.message = info.message
			or 'No focus information: this file is not a supported Sony ARW/JPEG/HEIF.'
		return result
	end
	if info.status == 'error' then
		result.kind = 'error'
		result.message = info.message or 'The focuspoint helper reported an error.'
		return result
	end
	if not opts.render then
		result.kind = info.status == 'ok' and 'ok' or 'no_focus'
		if result.kind == 'no_focus' then
			result.message = info.message or 'The camera recorded no focus point for this photo.'
		end
		return result
	end
	if cancelled() then
		result.kind = 'cancelled'
		return result
	end

	-- 2. Optional Lightroom preview as the image source.
	local aspect = Core.displayedAspect(info)
	local sourcePath
	if opts.useLrPreview then
		local usable, why = Cli.previewUsable(photo)
		if usable then
			local p, pw, ph = Cli.exportLrPreview(photo)
			if not p then
				log:infof('%s: not using Lr preview (%s)', tostring(check.fileName), tostring(pw))
				result.sourceNote = 'embedded preview'
			elseif aspect and not (pw and ph and Core.aspectMatches(pw / ph, aspect)) then
				-- Most likely the user rotated the photo in Lightroom (the
				-- focus coordinates are in camera orientation), or the preview
				-- is otherwise not the camera's full frame.
				log:infof('%s: Lr preview %sx%s does not match camera aspect %.4f; using embedded preview',
					tostring(check.fileName), tostring(pw), tostring(ph), aspect)
				Cli.deleteFile(p)
				result.sourceNote = 'embedded preview (Lightroom preview is rotated or reshaped)'
			else
				sourcePath = p
				if not aspect and pw and ph then
					aspect = pw / ph
				end
			end
		else
			log:infof('%s: not using Lr preview (%s)', tostring(check.fileName), tostring(why))
			result.sourceNote = 'embedded preview (' .. tostring(why) .. ')'
		end
	end
	if cancelled() then
		Cli.deleteFile(sourcePath)
		result.kind = 'cancelled'
		return result
	end

	if not aspect then
		-- Last resort for choosing --size: Lightroom's own aspect ratio.
		aspect = tonumber(photo:getRawMetadata('aspectRatio'))
	end
	-- The viewer uses this to pick the landscape or portrait picture slot.
	result.aspect = aspect

	-- 3. Render.
	local boxW = opts.boxW or 640
	local boxH = opts.boxH or 480
	local rendered = Cli.render(check.path, {
		outDir = Cli.renderDir(),
		source = sourcePath,
		size = Core.fitLongEdge(aspect, boxW, boxH),
		cropSize = opts.cropSize or 400,
	})
	Cli.deleteFile(sourcePath)

	result.info = rendered
	if rendered._nocli then
		result.kind = 'nocli'
		result.message = rendered.message
		return result
	end
	if rendered.status == 'error' and sourcePath then
		-- Try once more without the Lightroom preview.
		log:warnf('%s: render with Lr preview failed (%s); retrying with embedded preview',
			tostring(check.fileName), tostring(rendered.message))
		local retryAspect = Core.displayedAspect(info) or aspect
		result.aspect = retryAspect
		rendered = Cli.render(check.path, {
			outDir = Cli.renderDir(),
			size = Core.fitLongEdge(retryAspect, boxW, boxH),
			cropSize = opts.cropSize or 400,
		})
		result.info = rendered
		result.sourceNote = 'embedded preview'
	end

	result.overview = rendered.overview
	result.crop = rendered.crop
	if rendered.overview and LrFileUtils.exists(rendered.overview) ~= 'file' then
		result.overview = nil
	end
	if rendered.crop and LrFileUtils.exists(rendered.crop) ~= 'file' then
		result.crop = nil
	end
	if rendered.source == 'provided' then
		result.sourceNote = 'Lightroom preview'
	elseif rendered.source == 'embedded_preview' then
		result.sourceNote = result.sourceNote or 'embedded preview'
	elseif rendered.source == 'image' then
		result.sourceNote = 'image file'
	end

	if rendered.status == 'ok' then
		result.kind = 'ok'
	elseif rendered.status == 'no_focus' then
		result.kind = 'no_focus'
		result.message = rendered.message or 'The camera recorded no focus point for this photo.'
	elseif rendered.status == 'unsupported' then
		result.kind = 'unsupported'
		result.message = rendered.message or 'No focus information for this file type.'
	else
		result.kind = 'error'
		result.message = rendered.message or 'The focuspoint helper reported an error.'
	end
	return result
end

return Cli
