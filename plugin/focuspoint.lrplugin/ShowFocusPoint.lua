--[[----------------------------------------------------------------------------
ShowFocusPoint.lua

Menu item: "Show Focus Point" – one-off modal dialog for the active photo.
Uses the CLI render cache (one `render --cache-dir` call; instant when the
photo was shown at this size before) unless the Lightroom-preview option is
on. Only Lightroom-preview renders (ephemeral files) are deleted on close.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Core = require 'FocusPointCore'
local Cli = require 'FocusPointCli'
local Viewer = require 'FocusPointViewer'
local log = require 'FocusPointLog'

LrFunctionContext.postAsyncTaskWithContext('FocusPointShow', function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)

	local catalog = LrApplication.activeCatalog()
	local photo = catalog:getTargetPhoto()
	if not photo then
		LrDialogs.message('Show Focus Point', 'Select a photo first.', 'info')
		return
	end

	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		LrDialogs.message('Focus Point helper not found', binMsg, 'critical')
		return
	end

	local useLrPreview = Viewer.useLrPreviewPref()
	Cli.cleanupRenders(600)

	local progress = LrProgressScope {
		title = 'Reading focus point',
		functionContext = context,
	}
	progress:setCaption(photo:getFormattedMetadata('fileName') or '')

	local sizes = Viewer.MODAL_SIZES
	local result = Cli.analyze(photo, {
		render = true,
		cacheDir = Cli.cacheDir(),
		useLrPreview = useLrPreview,
		boxW = sizes.overviewW,
		boxH = sizes.overviewH,
		cropSize = sizes.crop,
	})
	progress:done()
	local timing = result.timing or {}
	log:infof('timing: modal file=%s total_ms=%d exec_ms=%d preview_ms=%d calls=%d cli_cached=%s result=%s',
		tostring(result.fileName), Core.ms(timing.total), Core.ms(timing.exec or 0), Core.ms(timing.preview or 0),
		timing.calls or 0, tostring(result.cached), tostring(result.kind))

	-- Cache files belong to the render cache; only delete Lightroom-preview
	-- renders.
	local files = result.ephemeral and Cli.resultFiles(result) or {}
	context:addCleanupHandler(function()
		for _, p in ipairs(files) do
			Cli.deleteFile(p)
		end
	end)

	if not result.overview then
		-- Nothing to show: a plain message is friendlier than an empty window.
		local title = result.fileName or 'Show Focus Point'
		local style = (result.kind == 'error' or result.kind == 'nocli') and 'critical' or 'info'
		LrDialogs.message(title, result.message or 'No focus information available.', style)
		return
	end

	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	Viewer.initProps(props)
	Viewer.applyResult(props, result, Viewer.flagText(photo), Core.renderNote(result))
	props.flagEnabled = true

	local contents = Viewer.buildContents(f, props, {
		sizes = sizes,
		onFlag = function(value)
			Viewer.setFlag(photo, value, function(text, err)
				props.flagText = text
				if err then
					props.status = err
				end
			end)
		end,
	})

	LrDialogs.presentModalDialog {
		title = 'Focus Point ' .. '\226\128\148 ' .. (result.fileName or ''), -- "— "
		contents = contents,
		actionVerb = 'Close',
		cancelVerb = '< exclude >',
		save_frame = 'focusPointModalFrame',
	}
	log:info('modal closed')
	-- Let Lightroom release the pictures before the cleanup handler deletes them.
	LrTasks.sleep(0.2)
end)
