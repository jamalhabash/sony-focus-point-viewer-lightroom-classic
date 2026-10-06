--[[----------------------------------------------------------------------------
FocusPointViewer.lua

The floating "Focus Point Viewer" window (LrDialogs.presentFloatingDialog,
SDK 5.0+) and the view/flag helpers shared with the one-off modal.

How the viewer follows the active photo (v0.2, "instant flipping")
-------------------------------------------------------------------
All state of one open viewer lives in a session (Viewer.newSession), driven
by three kinds of LrTasks tasks. Lightroom runs tasks cooperatively on its
main thread and only switches at yielding SDK calls (LrTasks.sleep/yield/
execute, and possibly catalog/photo calls), so plain Lua table updates
between such calls are atomic; the code re-checks shared state after every
call that may yield.

* Poll loop (every POLL_INTERVAL = 50 ms): reads catalog:getTargetPhoto().
  On a change it looks the photo up in the in-memory result map
  (photo.localIdentifier -> result, files verified to still exist) and shows
  a hit immediately. A miss is rendered once the target has been stable for
  MISS_DEBOUNCE (80 ms) – in its own async task, so the poll loop keeps
  showing hits while a render runs. At most MAX_ONDEMAND renders at once.
  selectionChangeObserver only records a timestamp (used for timing logs).
* On-demand render task: one `focuspoint render --cache-dir` call (plus
  `info` and a Lightroom preview when that option is on, or for HEIF). The
  result goes into the map; it is shown if its photo is still the target.
* Prefetch task (only while "Use Lightroom preview" is off): plans around
  the target in catalog:getMultipleSelectedOrAllPhotos() order (+1, -1, +2,
  +3, -2, ... see Core.prefetchOrder), renders up to PREFETCH_BATCH photos
  per `focuspoint batch` call, feeds the map and re-plans after every batch.
  It does not start a batch while an on-demand render is running; a running
  batch never blocks an on-demand render (separate task / process).

Cache-backed results (render cache, Cli.cacheDir()) are never deleted by the
plug-in. Results drawn on a Lightroom preview are `ephemeral` (unique files)
and are deleted when replaced or when the window closes.

Every displayed photo writes a `timing:` line to the log (grep for it).
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
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

local POLL_INTERVAL = 0.05 -- seconds between getTargetPhoto() polls
local MISS_DEBOUNCE = 0.08 -- a cache miss is rendered once the target was stable this long
local FLAG_REFRESH = 0.5 -- seconds between pickStatus refreshes of the shown photo
local MAX_ONDEMAND = 2 -- concurrent on-demand renders

local PREFETCH_BATCH = 12 -- photos per `focuspoint batch` call
local PREFETCH_LOOKAHEAD = 24 -- see Core.pickBatch
local PREFETCH_CAP = 1000 -- photos around the target considered for prefetching
local PREFETCH_BACKWARD_WEIGHT = 1.5 -- forward bias, see Core.prefetchOrder
local PREFETCH_IDLE = 0.5 -- seconds to wait when there is nothing to prefetch
local LIST_MIN_AGE = 1 -- min seconds between photo-list refreshes
local LIST_MAX_AGE = 5 -- refresh at least this often (+1 s per 2000 photos)

Viewer.TIMING = {
	POLL_INTERVAL = POLL_INTERVAL,
	MISS_DEBOUNCE = MISS_DEBOUNCE,
}

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

-- v0.1 stored `useLrPreview` (default on). v0.2 makes the embedded JPEG the
-- default (much faster, cacheable) under a NEW key, so existing installs get
-- the new default too. The old key is left alone and ignored.
Viewer.PREF_LR_PREVIEW = 'lrPreviewForOverview'
Viewer.LR_PREVIEW_LABEL = 'Use Lightroom preview for overview (shows edits, slower)'

function Viewer.prefs()
	local prefs = LrPrefs.prefsForPlugin()
	if prefs[Viewer.PREF_LR_PREVIEW] == nil then
		prefs[Viewer.PREF_LR_PREVIEW] = false
	end
	return prefs
end

function Viewer.useLrPreviewPref()
	return Viewer.prefs()[Viewer.PREF_LR_PREVIEW] == true
end

--------------------------------------------------------------------------------
-- Property table helpers
--------------------------------------------------------------------------------

--- Initialise the bindable keys used by buildContents(). (prefetchNote is
-- owned by the viewer session and not reset here.)
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
-- `note` (optional) is appended to the status line, e.g. "cached".
function Viewer.applyResult(props, result, flagText, note)
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
	if note and note ~= '' then
		status = status .. (status ~= '' and Core.SEPARATOR or '') .. note
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
-- opts.showPrefetch: show the prefetch progress note (props.prefetchNote)
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
			title = Viewer.LR_PREVIEW_LABEL,
			value = bind 'useLrPreview',
			tooltip = 'Draw the overview on Lightroom\'s own preview (only for uncropped, '
				.. 'unrotated photos), so it shows your edits. Slower: every photo is rendered '
				.. 'when you reach it and nothing is pre-rendered. Off (default): use the JPEG '
				.. 'embedded in the raw file; nearby photos are pre-rendered and cached. The zoomed '
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
	if opts.showPrefetch then
		bottom[#bottom + 1] = f:static_text {
			title = bind 'prefetchNote',
			size = 'small',
			-- Explicit width: the bound text starts empty and layout is
			-- computed once.
			width_in_chars = 36,
			fill_horizontal = 1,
			alignment = 'right',
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
-- Viewer session (state + logic of one open floating viewer)
--------------------------------------------------------------------------------

local function now()
	return LrDate.currentTime()
end

local function deleteFiles(list)
	for _, p in ipairs(list or {}) do
		Cli.deleteFile(p)
	end
end

--- Create the state machine behind a floating viewer.
-- catalog: LrCatalog; props: property table (see buildContents, plus
-- useLrPreview and prefetchNote). opts.sizes defaults to Viewer.SIZES.
-- Returns a table of functions:
--   step()          one poll: follow the target, show hits, start renders
--   prefetchStep()  plan + run one prefetch batch; returns seconds to wait
--   observeSelection()  for selectionChangeObserver
--   forceRender()   "Re-render" button
--   lrPreviewChanged()  after props.useLrPreview changed
--   close()         stop everything; returns ephemeral files to delete
--   state           the raw state table (for tests / diagnostics)
-- step/prefetchStep must run inside an LrTasks task.
function Viewer.newSession(catalog, props, opts)
	opts = opts or {}
	local sizes = opts.sizes or Viewer.SIZES
	local session = {}
	local s = {
		closed = false,
		cacheDir = opts.cacheDir or Cli.cacheDir(),
		-- In-memory results: localIdentifier -> result (cache-backed only).
		results = {},
		failed = {}, -- localIdentifier -> true: prefetch gave an error; on-demand still retries
		missing = {}, -- localIdentifier -> true: original offline (reset on list refresh)
		sizeHint = {}, -- localIdentifier -> preferred --size once the real aspect is known
		inflight = {}, -- localIdentifier -> true: on-demand render running
		onDemand = 0, -- number of on-demand renders running
		prefetchInflight = {}, -- localIdentifier -> true: in the running batch
		-- Target tracking.
		targetKey = nil, -- localIdentifier of the target (false = none, nil = not polled yet)
		targetSerial = 0, -- bumped on every target change
		changeStart = 0, -- best estimate of when the target changed
		detectedAt = 0, -- when the poll noticed it
		observedAt = nil, -- last selectionChangeObserver call
		missNoted = false,
		forceKey = nil,
		-- What is on screen.
		shownKey = nil,
		shownPhoto = nil,
		shownResult = nil,
		shownEphemeral = {},
		lastFlagCheck = 0,
		-- Prefetch.
		list = nil, -- photos (getMultipleSelectedOrAllPhotos)
		ids = {}, -- index -> localIdentifier
		indexOf = {}, -- localIdentifier -> first index
		listAt = -1e9,
		listSerial = -1,
		lastIndex = nil,
		meta = {}, -- localIdentifier -> { path, skip, size }
		prefetchDone = 0,
		prefetchTotal = 0,
		batches = 0,
	}
	session.state = s

	local function setProp(key, value)
		if not s.closed and props[key] ~= value then
			props[key] = value
		end
	end

	local function lrMode()
		return props.useLrPreview == true
	end

	local function currentTarget()
		local photo = catalog:getTargetPhoto()
		if photo then
			return photo.localIdentifier, photo
		end
		return false, nil
	end

	local function logTiming(key, result, t)
		local timing = result and result.timing or {}
		log:infof('timing: show kind=%s file=%s id=%s total_ms=%d detect_ms=%d lookup_ms=%d wait_ms=%d '
			.. 'exec_ms=%d preview_ms=%d calls=%d cli_cached=%s result=%s',
			tostring(t.kind), tostring(result and result.fileName), tostring(key),
			Core.ms(t.displayed - t.start), Core.ms(t.detected - t.start), Core.ms(t.lookup or 0),
			Core.ms(t.queued and (t.queued - t.start) or 0),
			Core.ms(timing.exec or 0), Core.ms(timing.preview or 0), timing.calls or 0,
			tostring(result and result.cached), tostring(result and result.kind))
	end

	--- Show `result` for target `key`. Returns false (and shows nothing) if
	-- the target moved on or the window closed meanwhile.
	local function display(key, photo, result, t)
		local flag = Viewer.flagText(photo) -- catalog call: may yield
		if s.closed or s.targetKey ~= key then
			return false
		end
		local old = s.shownEphemeral
		s.shownKey = key
		s.shownPhoto = photo
		s.shownResult = result
		s.shownEphemeral = result.ephemeral and Cli.resultFiles(result) or {}
		s.lastFlagCheck = now()
		Viewer.applyResult(props, result, flag, t.note)
		props.flagEnabled = true
		t.displayed = now()
		logTiming(key, result, t)
		-- Delete the previous Lightroom-preview render only after the new
		-- result is displayed.
		deleteFiles(old)
		return true
	end

	local function showNone()
		s.shownKey = false
		s.shownPhoto = nil
		s.shownResult = nil
		local old = s.shownEphemeral
		s.shownEphemeral = {}
		Viewer.showMessageOnly(props, 'No photo selected.\n\nSelect a photo in the Library grid or filmstrip.', '')
		deleteFiles(old)
	end

	--- In-memory hit for `key` whose files still exist, or nil.
	local function lookup(key)
		local r = s.results[key]
		if not r then
			return nil
		end
		if not Cli.resultFilesExist(r) then
			-- Pruned from the CLI cache (or deleted by the user).
			s.results[key] = nil
			log:infof('cache entry for %s vanished; rendering again', tostring(r.fileName))
			return nil
		end
		return r
	end

	local function startOnDemand(key, photo, forced)
		s.inflight[key] = true
		s.onDemand = s.onDemand + 1
		local useLr = lrMode()
		local t = {
			kind = forced and 'forced' or (useLr and 'lrpreview' or 'miss'),
			start = s.changeStart,
			detected = s.detectedAt,
			queued = now(),
		}
		LrTasks.startAsyncTask(function()
			local ok, err = LrTasks.pcall(function()
				local result = Cli.analyze(photo, {
					render = true,
					cacheDir = s.cacheDir,
					useLrPreview = useLr,
					boxW = sizes.overviewW,
					boxH = sizes.overviewH,
					cropSize = sizes.crop,
					size = s.sizeHint[key],
					-- Only the (slow) Lightroom-preview path checks this; a
					-- cache render is worth finishing for later flips.
					isCancelled = function()
						return s.closed or s.targetKey ~= key
					end,
				})
				if result.kind == 'cancelled' then
					log:debugf('discarded stale render for %s', tostring(result.fileName))
					return
				end
				if Cli.isCacheable(result) then
					s.results[key] = result
					s.failed[key] = nil
					if result.size then
						s.sizeHint[key] = result.size
					end
				end
				local shown = false
				-- (A render made before the Lightroom-preview option was
				-- toggled is kept but not shown; the poll starts a new one.)
				if not s.closed and s.targetKey == key and (forced or s.shownKey ~= key)
					and useLr == lrMode() then
					t.note = Core.renderNote(result)
					shown = display(key, photo, result, t)
				end
				if not shown and result.ephemeral then
					deleteFiles(Cli.resultFiles(result))
				end
			end)
			s.inflight[key] = nil
			s.onDemand = s.onDemand - 1
			if not ok then
				log:errorf('render failed: %s', tostring(err))
				if not s.closed and s.targetKey == key then
					-- Show the error instead of retrying in a loop.
					s.shownKey = key
					s.shownPhoto = nil
					Viewer.showMessageOnly(props, 'Error: ' .. tostring(err), '')
				end
			end
		end, 'FocusPoint render')
	end

	function session.observeSelection()
		s.observedAt = now()
	end

	function session.step()
		local tNow = now()
		local key, photo = currentTarget()
		if s.closed then
			return
		end
		if key ~= s.targetKey then
			s.targetKey = key
			s.targetSerial = s.targetSerial + 1
			-- The observer usually fires right at the change; the poll can
			-- notice it up to POLL_INTERVAL later.
			local start = tNow
			if s.observedAt and s.observedAt > s.detectedAt and s.observedAt <= tNow then
				start = s.observedAt
			end
			s.changeStart = start
			s.detectedAt = tNow
			s.missNoted = false
		end

		if key == false then
			if s.shownKey ~= false then
				showNone()
			end
			return
		end

		local forced = s.forceKey ~= nil and s.forceKey == key
		if key ~= s.shownKey or forced then
			if not forced and not lrMode() then
				local t0 = now()
				local hit = lookup(key)
				if hit then
					display(key, photo, hit, {
						kind = 'hit',
						start = s.changeStart,
						detected = s.detectedAt,
						lookup = now() - t0,
						note = 'cached',
					})
					return
				end
			end
			if s.inflight[key] then
				return -- its result will be shown when it arrives
			end
			if not forced and (tNow - s.changeStart < MISS_DEBOUNCE or s.onDemand >= MAX_ONDEMAND) then
				return
			end
			if not s.missNoted then
				s.missNoted = true
				local name = photo:getFormattedMetadata('fileName') or ''
				setProp('status', 'Reading focus point for ' .. name .. '\226\128\166') -- "…"
				-- That call may have yielded: re-check before starting.
				if s.closed or s.targetKey ~= key or s.inflight[key] then
					return
				end
			end
			if forced then
				s.forceKey = nil
			end
			startOnDemand(key, photo, forced)
			return
		end

		-- Keep the flag label in sync with changes made in Lightroom itself.
		if s.shownPhoto and tNow - s.lastFlagCheck >= FLAG_REFRESH then
			s.lastFlagCheck = tNow
			local shownPhoto = s.shownPhoto
			local text = Viewer.flagText(shownPhoto)
			if s.shownPhoto == shownPhoto then
				setProp('flagText', text)
			end
		end
	end

	function session.forceRender()
		if s.targetKey then
			s.results[s.targetKey] = nil
			s.forceKey = s.targetKey
			s.changeStart = now() -- for the timing log
			s.detectedAt = s.changeStart
		end
	end

	function session.lrPreviewChanged()
		-- Re-evaluate the current photo: a hit shows at once when the option
		-- was turned off; turning it on renders on the Lightroom preview.
		s.shownKey = nil
		s.forceKey = nil
		s.missNoted = false
		s.changeStart = now() -- for the timing log
		s.detectedAt = s.changeStart
		if lrMode() then
			setProp('prefetchNote', 'pre-rendering paused (Lightroom preview is on)')
		end
	end

	-- Prefetch -----------------------------------------------------------------

	local function refreshList()
		local tNow = now()
		local age = tNow - s.listAt
		local n = s.list and #s.list or 0
		local targetMissing = s.targetKey and s.indexOf[s.targetKey] == nil
		local need = s.list == nil or age >= LIST_MAX_AGE + n / 2000
			or (age >= LIST_MIN_AGE and (s.listSerial ~= s.targetSerial or targetMissing))
		if not need then
			return
		end
		local serial = s.targetSerial
		-- Documented as "all selected photos if more than one is selected, or
		-- all visible photos if only one or none is selected". The order is
		-- not documented; it is assumed to be the filmstrip order. If it is
		-- not, prefetching still works, just less targeted.
		local photos = catalog:getMultipleSelectedOrAllPhotos() or {}
		local ids, indexOf = {}, {}
		for i, p in ipairs(photos) do
			local id = p.localIdentifier
			ids[i] = id
			if indexOf[id] == nil then
				indexOf[id] = i
			end
			if i % 500 == 0 then
				LrTasks.yield() -- don't stall Lightroom's UI on huge lists
			end
		end
		s.list = photos
		s.ids = ids
		s.indexOf = indexOf
		s.listAt = now()
		s.listSerial = serial
		s.missing = {}
		log:infof('timing: prefetch-list n=%d list_ms=%d', #photos, Core.ms(now() - tNow))
	end

	--- Fetch path / type / aspect for the listed indices we don't know yet.
	local function ensureMeta(indices)
		local need, needIds = {}, {}
		for _, i in ipairs(indices) do
			local id = s.ids[i]
			if id ~= nil and s.meta[id] == nil and s.list[i] then
				need[#need + 1] = s.list[i]
				needIds[#needIds + 1] = id
			end
		end
		if #need == 0 then
			return
		end
		local raw = catalog:batchGetRawMetadata(need, { 'path', 'fileFormat', 'isVideo', 'aspectRatio' }) or {}
		-- The result is keyed by LrPhoto; match by localIdentifier in case
		-- the keys are not the very same Lua objects we passed in.
		local byId = {}
		for p, m in pairs(raw) do
			local okId, id = pcall(function()
				return p.localIdentifier
			end)
			if okId and id ~= nil then
				byId[id] = m
			end
		end
		for j, photo in ipairs(need) do
			local m = raw[photo] or byId[needIds[j]] or {}
			local path = m.path
			local skip = type(path) ~= 'string' or path == ''
				or m.fileFormat == 'VIDEO' or m.isVideo == true
				or Core.isHeifPath(path) -- needs a Lightroom preview; on-demand only
				or string.find(path, '[\r\n]') ~= nil -- can't go into the list file
			s.meta[needIds[j]] = {
				path = path,
				skip = skip and true or false,
				size = Core.guessOverviewSize(m.aspectRatio, sizes.overviewW, sizes.overviewH),
			}
		end
	end

	local function classify(i)
		local id = s.ids[i]
		if id == nil or s.results[id] or s.failed[id] or s.missing[id]
			or s.inflight[id] or s.prefetchInflight[id] then
			return nil
		end
		local m = s.meta[id]
		if not m or m.skip then
			return nil
		end
		return s.sizeHint[id] or m.size
	end

	local function updateProgress(target, order, active)
		local total, done = 0, 0
		local function count(i)
			local id = s.ids[i]
			local m = id ~= nil and s.meta[id]
			if m and not m.skip and not s.missing[id] then
				total = total + 1
				if s.results[id] or s.failed[id] then
					done = done + 1
				end
			end
		end
		count(target)
		for _, i in ipairs(order) do
			count(i)
		end
		s.prefetchDone, s.prefetchTotal = done, total
		setProp('prefetchNote', Core.prefetchNote(done, total, active))
	end

	--- One prefetch round. Returns the number of seconds to wait before the
	-- next one (0 = go on right away).
	function session.prefetchStep()
		if s.closed then
			return 0
		end
		if lrMode() then
			setProp('prefetchNote', 'pre-rendering paused (Lightroom preview is on)')
			return PREFETCH_IDLE
		end
		if s.onDemand > 0 then
			return POLL_INTERVAL -- let the on-demand render have the CPU
		end
		if not Cli.checkBinary() then
			return 5
		end
		refreshList()
		if s.closed then
			return 0
		end
		local idx = s.targetKey and s.indexOf[s.targetKey] or nil
		if not idx then
			-- Target not in the list (e.g. a stack member, or the list is
			-- stale): keep working around the last known position.
			idx = s.lastIndex
		end
		if not idx or idx > #s.ids then
			setProp('prefetchNote', '')
			return PREFETCH_IDLE
		end
		s.lastIndex = idx

		local order = Core.prefetchOrder(#s.ids, idx, PREFETCH_CAP, PREFETCH_BACKWARD_WEIGHT)
		local window = { idx }
		for _, i in ipairs(order) do
			window[#window + 1] = i
		end
		ensureMeta(window)
		if s.closed then
			return 0
		end

		local picked, size = Core.pickBatch(order, classify, PREFETCH_BATCH, PREFETCH_LOOKAHEAD)
		if #picked == 0 then
			updateProgress(idx, order, false)
			return PREFETCH_IDLE
		end
		updateProgress(idx, order, true)

		local paths, idsByPath = {}, {}
		for _, i in ipairs(picked) do
			local id = s.ids[i]
			local path = s.meta[id].path
			if LrFileUtils.exists(path) ~= 'file' then
				s.missing[id] = true
			else
				if not idsByPath[path] then
					idsByPath[path] = {}
					paths[#paths + 1] = path
				end
				local list = idsByPath[path]
				list[#list + 1] = id
				s.prefetchInflight[id] = true
			end
		end
		if #paths == 0 then
			return 0
		end

		local blocks, meta = Cli.batch(paths, {
			cacheDir = s.cacheDir,
			size = size,
			cropSize = sizes.crop,
		})
		for _, path in ipairs(paths) do
			for _, id in ipairs(idsByPath[path]) do
				s.prefetchInflight[id] = nil
			end
		end
		if s.closed then
			return 0
		end
		s.batches = s.batches + 1
		if #blocks == 0 then
			-- The whole call failed (e.g. a helper without `batch`, or one
			-- being replaced): don't blame the files, back off and retry.
			log:warnf('timing: batch purpose=prefetch n=%d size=%d exec_ms=%d FAILED: %s',
				#paths, size, Core.ms(meta.elapsed), tostring(meta.message))
			return 5
		end

		local byFile = {}
		for _, b in ipairs(blocks) do
			byFile[b.file] = b
		end
		local cachedCount, renderedCount, failedCount, resized = 0, 0, 0, 0
		for _, path in ipairs(paths) do
			local b = byFile[path]
			local r = b and Cli.resultFromKv(b, { path = path, size = size })
			local preferred = r and r.overview and r.aspect
				and Core.preferredOverviewSize(r.aspect, sizes.overviewW, sizes.overviewH)
			for _, id in ipairs(idsByPath[path]) do
				if preferred and preferred ~= size then
					-- Lightroom's aspect was misleading (e.g. rotated in
					-- Lightroom): render again at the right size later.
					s.sizeHint[id] = preferred
					resized = resized + 1
				elseif r and Cli.isCacheable(r) then
					if not s.results[id] then
						s.results[id] = r
					end
				else
					s.failed[id] = true
				end
			end
			if not r or not Cli.isCacheable(r) then
				failedCount = failedCount + 1
			elseif r.cached then
				cachedCount = cachedCount + 1
			else
				renderedCount = renderedCount + 1
			end
		end
		log:infof('timing: batch purpose=prefetch n=%d size=%d exec_ms=%d cached=%d rendered=%d failed=%d resized=%d target_index=%d',
			#paths, size, Core.ms(meta.elapsed), cachedCount, renderedCount, failedCount, resized, idx)
		updateProgress(idx, order, true)
		return 0
	end

	function session.close()
		s.closed = true
		local files = s.shownEphemeral
		s.shownEphemeral = {}
		return files
	end

	return session
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
	props.prefetchNote = ''
	props.useLrPreview = prefs[Viewer.PREF_LR_PREVIEW] == true

	local session = Viewer.newSession(catalog, props, { sizes = Viewer.SIZES })
	local s = session.state
	-- Stop the loops even if presentFloatingDialog never returns normally
	-- (e.g. it throws), so they can't outlive the window/context.
	context:addCleanupHandler(function()
		s.closed = true
	end)

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
				props.flagText = text
				if err then
					props.status = err
				end
			elseif err then
				LrDialogs.showBezel(err)
			end
		end)
	end

	props:addObserver('useLrPreview', function(_, _, value)
		prefs[Viewer.PREF_LR_PREVIEW] = value and true or false
		session.lrPreviewChanged()
	end)

	local contents = Viewer.buildContents(f, props, {
		sizes = Viewer.SIZES,
		onFlag = onFlag,
		onRefresh = function()
			session.forceRender()
		end,
		showPreviewToggle = true,
		showPrefetch = true,
	})

	-- Remove Lightroom-preview renders left over from earlier sessions
	-- (older than 10 minutes, so a concurrently open "Show Focus Point"
	-- isn't affected). The render cache is pruned by the CLI itself.
	Cli.cleanupRenders(600)

	-- The polling / display loop.
	LrTasks.startAsyncTask(function()
		log:info('viewer loop started')
		while not s.closed do
			local ok, err = LrTasks.pcall(session.step)
			if not ok then
				log:errorf('viewer step failed: %s', tostring(err))
				if not s.closed then
					props.status = 'Error: ' .. tostring(err)
				end
				-- Don't spin on the same failing photo.
				s.shownKey = s.targetKey
				s.forceKey = nil
			end
			LrTasks.sleep(POLL_INTERVAL)
		end
		log:info('viewer loop stopped')
	end, 'FocusPoint viewer loop')

	-- The prefetch loop.
	LrTasks.startAsyncTask(function()
		log:info('prefetch loop started')
		while not s.closed do
			local ok, delay = LrTasks.pcall(session.prefetchStep)
			if not ok then
				log:errorf('prefetch step failed: %s', tostring(delay))
				delay = 2
			end
			if type(delay) == 'number' and delay > 0 then
				LrTasks.sleep(delay)
			else
				LrTasks.yield()
			end
		end
		log:infof('prefetch loop stopped (%d batches, %d/%d nearby photos pre-rendered)',
			s.batches, s.prefetchDone, s.prefetchTotal)
	end, 'FocusPoint prefetch')

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
			session.observeSelection()
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
	active = nil
	local files = session.close()
	-- Give Lightroom a moment to release the pictures before deleting them
	-- (only Lightroom-preview renders; cache files stay).
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
