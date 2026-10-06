--[[----------------------------------------------------------------------------
ShowFocusPoint.lua

Menu item: "Show Focus Point" – one-off modal dialog for the active photo.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

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

	local prefs = Viewer.prefs()
	Cli.cleanupRenders(600)

	local progress = LrProgressScope {
		title = 'Reading focus point',
		functionContext = context,
	}
	progress:setCaption(photo:getFormattedMetadata('fileName') or '')

	local sizes = Viewer.MODAL_SIZES
	local result = Cli.analyze(photo, {
		render = true,
		useLrPreview = prefs.useLrPreview ~= false,
		boxW = sizes.overviewW,
		boxH = sizes.overviewH,
		cropSize = sizes.crop,
	})
	progress:done()

	local files = {}
	if result.overview then
		files[#files + 1] = result.overview
	end
	if result.crop then
		files[#files + 1] = result.crop
	end
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
	Viewer.applyResult(props, result, Viewer.flagText(photo))
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
