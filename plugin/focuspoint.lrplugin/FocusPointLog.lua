--[[----------------------------------------------------------------------------
FocusPointLog.lua

Shared LrLogger instance. LrLogger 'logfile' output goes to a file named after
the logger ("focuspoint.log"):
  * Lightroom Classic 14+: ~/Library/Logs/Adobe/Lightroom/LrClassicLogs/
    (Windows: %LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\)
  * older versions: ~/Documents/LrClassicLogs/ (or ~/Documents/ for very old)
The 14+ location is per the Focus-Points plug-in's notes quoting Adobe; the
SDK 6 reference only says "~/Documents".
------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('focuspoint')
logger:enable('logfile')

return logger
