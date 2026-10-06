--[[----------------------------------------------------------------------------
PluginInfoProvider.lua

Adds a status section to File > Plug-in Manager: helper binary location,
whether it was found, its version, and where the log file is.
------------------------------------------------------------------------------]]

local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Cli = require 'FocusPointCli'

local function logFolder()
	local home = LrPathUtils.getStandardFilePath('home')
	if WIN_ENV then
		return LrPathUtils.child(home, 'AppData\\Local\\Adobe\\Lightroom\\Logs\\LrClassicLogs')
	end
	return LrPathUtils.child(home, 'Library/Logs/Adobe/Lightroom/LrClassicLogs')
end

return {
	sectionsForTopOfDialog = function(f, propertyTable)
		local found, msg = Cli.checkBinary()
		propertyTable.binaryStatus = found and 'found' or 'MISSING'
		propertyTable.binaryVersion = found and 'checking\226\128\166' or '-'
		if found then
			LrTasks.startAsyncTask(function()
				local ok, version = LrTasks.pcall(Cli.version)
				propertyTable.binaryVersion = (ok and version) or 'unknown (could not run it)'
			end, 'FocusPoint version check')
		end

		local bind = LrView.bind
		local rows = {
			bind_to_object = propertyTable,
			spacing = f:control_spacing(),
			f:row {
				f:static_text { title = 'Helper:', width = 80 },
				f:static_text { title = Cli.binaryPath(), selectable = true, fill_horizontal = 1 },
			},
			f:row {
				f:static_text { title = 'Status:', width = 80 },
				f:static_text { title = bind 'binaryStatus', width_in_chars = 10 },
			},
			f:row {
				f:static_text { title = 'Version:', width = 80 },
				f:static_text { title = bind 'binaryVersion', fill_horizontal = 1 },
			},
			f:row {
				f:static_text { title = 'Log file:', width = 80 },
				f:static_text {
					title = LrPathUtils.child(logFolder(), 'focuspoint.log')
						.. '  (Lightroom Classic 14+; older versions: ~/Documents/LrClassicLogs)',
					selectable = true,
					fill_horizontal = 1,
				},
			},
		}
		if not found then
			rows[#rows + 1] = f:static_text {
				title = msg,
				fill_horizontal = 1,
				height_in_lines = 4,
			}
		end

		return {
			{
				title = 'Focus Point',
				synopsis = found and 'Helper found' or 'Helper MISSING',
				f:column(rows),
			},
		}
	end,
}
