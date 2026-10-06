--[[----------------------------------------------------------------------------
FocusPointViewer.lua

The floating "Focus Point Viewer" window (LrDialogs.presentFloatingDialog,
SDK 5.0+) and the view/flag helpers shared with the one-off modal.

How the viewer follows the active photo
---------------------------------------
* One long-running LrTasks loop polls catalog:getTargetPhoto() every
  POLL_INTERVAL seconds. selectionChangeObserver only bumps a counter (it runs
  on Lightroom's UI path, where yielding / catalog work is not advisable, and
  a forum report says catalog writes from it fail); the poll is authoritative
  and also covers cases where the observer might not fire.
* A change of target photo is debounced (DEBOUNCE seconds of quiet) so holding
  an arrow key doesn't queue a render per photo; only the latest is rendered.
* Renders happen inside the loop task, one at a time. Each render remembers
  the photo (localIdentifier) it started for and re-checks the live target
  between pipeline stages and before displaying; if the active photo changed
  meanwhile the result is discarded (and its files deleted) and the loop
  renders the new target instead.
* Every render writes new, uniquely named files (the CLI guarantees this) –
  Lightroom caches f:picture images by path.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Core = require 'FocusPointCore'
local Cli = require 'FocusPointCli'
local log = require 'FocusPointLog'

local Viewer = {}

-- Floating viewer geometry (points). The overview box is 4:3 so a 3:2
-- landscape frame renders at 640x427 and a 2:3 portrait frame at 320x480;
-- both slots live in one fixed-size overlapping container, so the window
-- never changes size while culling.
Viewer.SIZES = {
	overviewW = 640,
	overviewH = 480,
	crop = 400,
}

-- Larger geometry for the one-off modal.
Viewer.MODAL_SIZES = {
	overviewW = 800,
	overviewH = 600,
	crop = 500,
}

local POLL_INTERVAL = 0.1 -- seconds between getTargetPhoto() polls
local DEBOUNCE = 0.25 -- seconds the selection must be stable before rendering
local FLAG_REFRESH = 0.5 -- seconds between pickStatus refreshes of the shown photo

-- Singleton state for the floating viewer (module state persists while the
-- plug-in is loaded, so choosing the menu item twice brings the existing
-- window to the front instead of opening a second one).
local active = nil

function Viewer.blankImage()
	return LrPathUtils.child(_PLUGIN.path, 'blank.png')
end

--------------------------------------------------------------------------------
-- Preferences
--------------------------------------------------------------------------------

function Viewer.prefs()
	local prefs = LrPrefs.prefsForPlugin()
	if prefs.useLrPreview == nil then
		prefs.useLrPreview = true
	end
	return prefs
end

--------------------------------------------------------------------------------
-- Property table helpers
--------------------------------------------------------------------------------

--- Initialise the bindable keys used by buildContents().
function Viewer.initProps(props)
	local blank = Viewer.blankImage()
	props.landscapePath = blank
	props.portraitPath = blank
	props.cropPath = blank
	props.showLandscape = false
	props.showPortrait = false
	props.showCrop = false
	props.message = ''
	props.showMessage = true
	props.summary = ''
	props.status = ''
	props.flagText = ''
	props.flagEnabled = false
end

--- Show an analysis result (from Cli.analyze) in the property table.
function Viewer.applyResult(props, result, flagText)
	local blank = Viewer.blankImage()
	local portrait = result.aspect ~= nil and result.aspect < 1

	if result.overview then
		props.landscapePath = portrait and blank or result.overview
		props.portraitPath = portrait and result.overview or blank
		props.showLandscape = not portrait
		props.showPortrait = portrait
	else
		props.landscapePath = blank
		props.portraitPath = blank
		props.showLandscape = false
		props.showPortrait = false
	end
	if result.crop then
		props.cropPath = result.crop
		props.showCrop = true
	else
		props.cropPath = blank
		props.showCrop = false
	end

	if result.kind == 'ok' then
		props.message = ''
		props.showMessage = false
	else
		props.message = result.message or ''
		props.showMessage = result.overview == nil
	end

	props.summary = Core.summaryLine(result.info, result.fileName)
	local status = ''
	if result.kind == 'ok' then
		local fp = Core.formatFocusPoint(result.info)
		status = 'Focus point' .. (fp and (' at ' .. fp) or '')
	elseif result.message then
		status = result.message
	end
	if result.sourceNote then
		status = status .. (status ~= '' and Core.SEPARATOR or '') .. 'overview: ' .. result.sourceNote
	end
	props.status = status
	props.flagText = flagText or ''
end

--- Reset the view to "nothing to show" with a message.
function Viewer.showMessageOnly(props, message, status)
	Viewer.initProps(props)
	props.message = message or ''
	props.showMessage = true
	props.status = status or ''
end

--------------------------------------------------------------------------------
-- Flags
--------------------------------------------------------------------------------

function Viewer.flagText(photo)
	if not photo then
		return ''
	end
	local ok, status = LrTasks.pcall(function()
		return photo:getRawMetadata('pickStatus')
	end)
	if not ok then
		return ''
	end
	return 'Flag: ' .. Core.flagLabel(status)
end

--- Set pick status (1 pick, -1 reject, 0 unflag) on `photo`, then call
-- onDone(newFlagText, errorMessageOrNil). Runs in its own async task.
function Viewer.setFlag(photo, value, onDone)
	if not photo then
		return
	end
	LrTasks.startAsyncTask(function()
		local catalog = LrApplication.activeCatalog()
		local label = value == 1 and 'Set Flag: Picked' or (value == -1 and 'Set Flag: Rejected' or 'Set Flag: Unflagged')
		local ok, outcome = LrTasks.pcall(function()
			return catalog:withWriteAccessDo(label, function()
				photo:setRawMetadata('pickStatus', value)
			end, { timeout = 5 })
		end)
		local err
		if not ok then
			err = 'Could not change the flag: ' .. tostring(outcome)
			log:errorf('setFlag failed: %s', tostring(outcome))
		elseif outcome == 'aborted' then
			err = 'Could not change the flag: the catalog is busy, try again.'
			log:warn('setFlag: write access aborted (timeout)')
		end
		if onDone then
			onDone(Viewer.flagText(photo), err)
		end
	end, 'FocusPoint setFlag')
end

--------------------------------------------------------------------------------
-- View construction
--------------------------------------------------------------------------------

--- Build the dialog contents bound to `props`.
-- opts.sizes: geometry table (Viewer.SIZES / Viewer.MODAL_SIZES)
-- opts.onFlag(value): called by Pick / Reject / Unflag (omit to hide them)
-- opts.onRefresh(): "Re-render" button (omit to hide)
-- opts.showPreviewToggle: show the "Use Lightroom preview" checkbox
function Viewer.buildContents(f, props, opts)
	local sz = opts.sizes or Viewer.SIZES
	local bind = LrView.bind
	-- Slot sizes: exact 3:2 / 2:3 frames that fit the overview box.
	local landW = sz.overviewW
	local landH = Core.round(sz.overviewW * 2 / 3)
	if landH > sz.overviewH then
		landH = sz.overviewH
		landW = Core.round(sz.overviewH * 3 / 2)
	end
	local portH = sz.overviewH
	local portW = Core.round(sz.overviewH * 2 / 3)
	local totalW = sz.overviewW + sz.crop + 16

	-- f:picture is given explicit width/height equal to the size we render
	-- at, so layout never depends on the (changing) image. The SDK does not
	-- document whether f:picture scales a differently-sized image; we avoid
	-- relying on it for the common 3:2 case.
	local overview = f:view {
		place = 'overlapping',
		width = sz.overviewW,
		height = sz.overviewH,
		f:picture {
			value = bind 'landscapePath',
			visible = bind 'showLandscape',
			width = landW,
			height = landH,
			place_horizontal = 0.5,
			place_vertical = 0.5,
		},
		f:picture {
			value = bind 'portraitPath',
			visible = bind 'showPortrait',
			width = portW,
			height = portH,
			place_horizontal = 0.5,
			place_vertical = 0.5,
		},
		f:static_text {
			title = bind 'message',
			visible = bind 'showMessage',
			width = sz.overviewW - 40,
			height_in_lines = 6,
			alignment = 'center',
			place_horizontal = 0.5,
			place_vertical = 0.5,
		},
	}

	local right = {
		spacing = f:control_spacing(),
		f:view {
			width = sz.crop,
			height = sz.crop,
			f:picture {
				value = bind 'cropPath',
				visible = bind 'showCrop',
				width = sz.crop,
				height = sz.crop,
			},
		},
		f:static_text {
			title = bind 'flagText',
			font = '<system/bold>',
			width = sz.crop,
		},
	}
	if opts.onFlag then
		right[#right + 1] = f:row {
			spacing = f:control_spacing(),
			f:push_button {
				title = 'Pick',
				enabled = bind 'flagEnabled',
				action = function()
					opts.onFlag(1)
				end,
			},
			f:push_button {
				title = 'Reject',
				enabled = bind 'flagEnabled',
				action = function()
					opts.onFlag(-1)
				end,
			},
			f:push_button {
				title = 'Unflag',
				enabled = bind 'flagEnabled',
				action = function()
					opts.onFlag(0)
				end,
			},
		}
	end

	local bottom = {
		spacing = f:control_spacing(),
	}
	if opts.showPreviewToggle then
		bottom[#bottom + 1] = f:checkbox {
			title = 'Use Lightroom preview for overview (shows your edits)',
			value = bind 'useLrPreview',
			tooltip = 'Draw the overview on Lightroom\'s own preview (only for uncropped, '
				.. 'unrotated photos). Off: use the JPEG embedded in the raw file. The zoomed '
				.. 'crop always comes from the highest-resolution image available.',
		}
	end
	if opts.onRefresh then
		bottom[#bottom + 1] = f:push_button {
			title = 'Re-render',
			action = function()
				opts.onRefresh()
			end,
		}
	end

	local column = {
		bind_to_object = props,
		spacing = f:control_spacing(),
		f:row {
			spacing = 16,
			overview,
			f:column(right),
		},
		f:static_text {
			title = bind 'summary',
			width = totalW,
			truncation = 'middle',
		},
		f:static_text {
			title = bind 'status',
			width = totalW,
			height_in_lines = 2,
			size = 'small',
		},
	}
	if #bottom > 0 then
		column[#column + 1] = f:row(bottom)
	end
	return f:column(column)
end

--------------------------------------------------------------------------------
-- Floating viewer
--------------------------------------------------------------------------------

local function runViewer(context)
	local catalog = LrApplication.activeCatalog()
	local prefs = Viewer.prefs()
	local f = LrView.osFactory()
	local props = LrBinding.makePropertyTable(context)
	Viewer.initProps(props)
	props.useLrPreview = prefs.useLrPreview and true or false

	local s = {
		closed = false,
		selectionSerial = 0, -- bumped by selectionChangeObserver (diagnostics only)
		targetKey = nil, -- localIdentifier of the current target (false = none)
		changedAt = 0,
		renderedKey = nil, -- key last rendered (nil = never)
		force = false, -- re-render even if the key is unchanged
		shownPhoto = nil, -- photo whose result is on screen (flag buttons act on it)
		shownFiles = {}, -- image files currently displayed
		lastFlagCheck = 0,
	}
	-- Stop the polling loop even if presentFloatingDialog never returns
	-- normally (e.g. it throws), so it can't outlive the window/context.
	context:addCleanupHandler(function()
		s.closed = true
	end)

	local function setProp(key, value)
		if not s.closed then
			props[key] = value
		end
	end

	local function deleteFiles(list)
		for _, p in ipairs(list) do
			Cli.deleteFile(p)
		end
	end

	local function resultFiles(result)
		local files = {}
		if result and result.overview then
			files[#files + 1] = result.overview
		end
		if result and result.crop then
			files[#files + 1] = result.crop
		end
		return files
	end

	local function currentKey()
		local photo = catalog:getTargetPhoto()
		if photo then
			return photo.localIdentifier, photo
		end
		return false, nil
	end

	local function onFlag(value)
		local photo = s.shownPhoto
		if not photo or s.closed then
			return
		end
		Viewer.setFlag(photo, value, function(text, err)
			if s.closed then
				return
			end
			-- Only update if that photo is still the one on screen.
			if s.shownPhoto == photo then
				setProp('flagText', text)
				if err then
					setProp('status', err)
				end
			elseif err then
				LrDialogs.showBezel(err)
			end
		end)
	end

	local function render(key, photo)
		if not photo then
			s.shownPhoto = nil
			Viewer.showMessageOnly(props, 'No photo selected.\n\nSelect a photo in the Library grid or filmstrip.', '')
			local old = s.shownFiles
			s.shownFiles = {}
			deleteFiles(old)
			return true
		end

		local fileName = photo:getFormattedMetadata('fileName') or ''
		setProp('status', 'Reading focus point for ' .. fileName .. '\226\128\166') -- "…"
		-- Stale = the window closed or the active photo is no longer the one
		-- this render started for (generation check against the live target).
		local function stale()
			if s.closed then
				return true
			end
			local k = currentKey()
			return k ~= key
		end

		local result = Cli.analyze(photo, {
			render = true,
			useLrPreview = props.useLrPreview == true,
			boxW = Viewer.SIZES.overviewW,
			boxH = Viewer.SIZES.overviewH,
			cropSize = Viewer.SIZES.crop,
			isCancelled = stale,
		})

		if result.kind == 'cancelled' or stale() then
			deleteFiles(resultFiles(result))
			log:debugf('discarded stale render for %s', fileName)
			return false
		end

		local old = s.shownFiles
		s.shownFiles = resultFiles(result)
		s.shownPhoto = photo
		Viewer.applyResult(props, result, Viewer.flagText(photo))
		-- Flags can be set even when there is no focus data to show.
		props.flagEnabled = true
		-- Delete the previous render only after the new one is displayed.
		deleteFiles(old)
		return true
	end

	local function step()
		local now = LrDate.currentTime()
		local key, photo = currentKey()
		if key ~= s.targetKey then
			-- New target: restart the debounce window.
			s.targetKey = key
			s.changedAt = now
		end

		local wanted = s.force or key ~= s.renderedKey
		if wanted and (s.force or now - s.changedAt >= DEBOUNCE) then
			s.force = false
			if render(key, photo) then
				s.renderedKey = key
			end
			return
		end

		-- Keep the flag label in sync with changes made in Lightroom itself.
		if s.shownPhoto and now - s.lastFlagCheck >= FLAG_REFRESH then
			s.lastFlagCheck = now
			local text = Viewer.flagText(s.shownPhoto)
			if text ~= props.flagText then
				setProp('flagText', text)
			end
		end
	end

	props:addObserver('useLrPreview', function(_, _, value)
		prefs.useLrPreview = value and true or false
		s.force = true
	end)

	local contents = Viewer.buildContents(f, props, {
		sizes = Viewer.SIZES,
		onFlag = onFlag,
		onRefresh = function()
			s.force = true
		end,
		showPreviewToggle = true,
	})

	-- Remove render output left over from earlier sessions (older than 10
	-- minutes, so a concurrently open "Show Focus Point" isn't affected).
	Cli.cleanupRenders(600)

	-- The polling / rendering loop.
	LrTasks.startAsyncTask(function()
		log:info('viewer loop started')
		while not s.closed do
			local ok, err = LrTasks.pcall(step)
			if not ok then
				log:errorf('viewer step failed: %s', tostring(err))
				if not s.closed then
					props.status = 'Error: ' .. tostring(err)
				end
				-- Don't spin on the same failing photo.
				s.renderedKey = s.targetKey
				s.force = false
			end
			LrTasks.sleep(POLL_INTERVAL)
		end
		log:info('viewer loop stopped')
	end, 'FocusPoint viewer loop')

	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		Viewer.showMessageOnly(props, binMsg, '')
	else
		Viewer.showMessageOnly(props, 'Loading\226\128\166', '')
	end

	LrDialogs.presentFloatingDialog(_PLUGIN, {
		title = 'Focus Point',
		contents = contents,
		blockTask = true, -- keeps `context` (and the property table) alive while open
		save_frame = 'focusPointViewerFrame',
		selectionChangeObserver = function()
			s.selectionSerial = s.selectionSerial + 1
		end,
		onShow = function(handles)
			if active and type(handles) == 'table' then
				active.toFront = handles.toFront
				active.close = handles.close
			end
		end,
		windowWillClose = function()
			s.closed = true
			active = nil
		end,
	})

	-- presentFloatingDialog (blockTask = true) returns once the window closed.
	s.closed = true
	active = nil
	local files = s.shownFiles
	s.shownFiles = {}
	-- Give Lightroom a moment to release the pictures before deleting them.
	LrTasks.startAsyncTask(function()
		LrTasks.sleep(1)
		deleteFiles(files)
	end, 'FocusPoint viewer cleanup')
	log:info('viewer closed')
end

function Viewer.open()
	if active then
		if active.toFront then
			pcall(active.toFront)
		end
		return
	end
	active = {}
	LrFunctionContext.postAsyncTaskWithContext('FocusPointViewer', function(context)
		LrDialogs.attachErrorDialogToFunctionContext(context)
		context:addCleanupHandler(function()
			active = nil
		end)
		runViewer(context)
	end)
end

return Viewer
