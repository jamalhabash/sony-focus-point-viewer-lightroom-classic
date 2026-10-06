--[[----------------------------------------------------------------------------
ReadFocusMetadata.lua

Menu item: "Read Focus Metadata for Selected Photos".
Runs `focuspoint info` for every selected photo and stores the result in the
plug-in metadata fields declared in MetadataDefinition.lua.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local Core = require 'FocusPointCore'
local Cli = require 'FocusPointCli'
local log = require 'FocusPointLog'

-- Searchable plug-in fields must not exceed 511 bytes.
local MAX_FIELD_BYTES = 500
-- Photos per catalog write transaction.
local WRITE_BATCH = 200

local function field(v)
	if v == nil or v == '' then
		return nil
	end
	return Core.truncateUtf8(v, MAX_FIELD_BYTES)
end

--- Map an analysis result to { fieldId = value } or nil to leave the photo
-- untouched (missing file, error, video).
local function fieldsFor(result)
	local info = result.info or {}
	if result.kind == 'ok' or result.kind == 'no_focus' then
		return {
			focusMode = field(info.focus_mode),
			afAreaMode = field(info.af_area_mode),
			focusPoint = result.kind == 'ok' and field(Core.formatFocusPoint(info)) or nil,
			afTracking = field(Core.trackingText(info)),
			focusStatus = result.kind == 'ok' and 'ok' or 'no focus',
		}
	elseif result.kind == 'unsupported' then
		return {
			focusMode = nil,
			afAreaMode = nil,
			focusPoint = nil,
			afTracking = nil,
			focusStatus = 'unsupported',
		}
	end
	return nil
end

local FIELD_IDS = { 'focusMode', 'afAreaMode', 'focusPoint', 'afTracking', 'focusStatus' }

local function writeBatch(catalog, updates, first, last)
	return catalog:withWriteAccessDo('Read Focus Metadata', function()
		for i = first, last do
			local u = updates[i]
			for _, id in ipairs(FIELD_IDS) do
				-- nil clears a stale value from an earlier run.
				u.photo:setPropertyForPlugin(_PLUGIN, id, u.fields[id])
			end
		end
	end, { timeout = 30 })
end

LrFunctionContext.postAsyncTaskWithContext('FocusPointReadMetadata', function(context)
	LrDialogs.attachErrorDialogToFunctionContext(context)

	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	if not photos or #photos == 0 then
		LrDialogs.message('Read Focus Metadata', 'Select one or more photos first.', 'info')
		return
	end

	local okBin, binMsg = Cli.checkBinary()
	if not okBin then
		LrDialogs.message('Focus Point helper not found', binMsg, 'critical')
		return
	end

	local progress = LrProgressScope {
		title = 'Reading focus metadata',
		functionContext = context,
	}
	progress:setCancelable(true)

	local counts = { ok = 0, no_focus = 0, unsupported = 0, skipped = 0, error = 0 }
	local updates = {}
	local firstError
	local total = #photos

	for i, photo in ipairs(photos) do
		if progress:isCanceled() then
			break
		end
		progress:setPortionComplete(i - 1, total)
		local result = Cli.analyze(photo, { render = false })
		progress:setCaption(result.fileName or '')

		if result.kind == 'nocli' then
			progress:done()
			LrDialogs.message('Focus Point helper not usable', result.message, 'critical')
			return
		end

		local fields = fieldsFor(result)
		if fields then
			updates[#updates + 1] = { photo = photo, fields = fields }
			counts[result.kind] = (counts[result.kind] or 0) + 1
		elseif result.kind == 'error' then
			counts.error = counts.error + 1
			firstError = firstError or ((result.fileName or '?') .. ': ' .. tostring(result.message))
			log:warnf('read metadata error for %s: %s', tostring(result.fileName), tostring(result.message))
		else
			-- video / missing original
			counts.skipped = counts.skipped + 1
		end
		LrTasks.yield()
	end

	local canceled = progress:isCanceled()
	progress:setCaption('Saving\226\128\166')

	local written = 0
	local i = 1
	while i <= #updates do
		local last = math.min(i + WRITE_BATCH - 1, #updates)
		local outcome = writeBatch(catalog, updates, i, last)
		if outcome == 'aborted' then
			LrDialogs.message('Read Focus Metadata',
				'The catalog was busy; only ' .. written .. ' of ' .. #updates
				.. ' photos were updated. Please try again.', 'warning')
			progress:done()
			return
		end
		written = last
		i = last + 1
	end
	progress:done()

	local lines = {
		string.format('%d with a focus point', counts.ok),
		string.format('%d without a focus point (e.g. manual focus)', counts.no_focus),
		string.format('%d not supported (non-Sony or unknown format)', counts.unsupported),
	}
	if counts.skipped > 0 then
		lines[#lines + 1] = string.format('%d skipped (videos or offline originals)', counts.skipped)
	end
	if counts.error > 0 then
		lines[#lines + 1] = string.format('%d failed; first error: %s', counts.error, firstError or '?')
	end
	if canceled then
		lines[#lines + 1] = 'Canceled before all photos were read.'
	end
	log:infof('read metadata: ok=%d no_focus=%d unsupported=%d skipped=%d error=%d',
		counts.ok, counts.no_focus, counts.unsupported, counts.skipped, counts.error)

	if counts.error > 0 or canceled then
		LrDialogs.message('Read Focus Metadata', table.concat(lines, '\n'), 'warning')
	else
		LrDialogs.showBezel(string.format('Focus metadata read for %d photo(s)', written), 3)
	end
end)
