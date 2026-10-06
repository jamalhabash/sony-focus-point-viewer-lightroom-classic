--[[----------------------------------------------------------------------------
Info.lua – Focus Point (Lightroom Classic plug-in)

Shows where a Sony a7 IV focused, while culling. The heavy lifting (maker-note
parsing, drawing) is done by the bundled `bin/focuspoint` CLI.
------------------------------------------------------------------------------]]

-- Returns a fresh table each call so the Library and File menus don't share
-- table instances.
local function menuItems()
	return {
		{
			title = 'Focus Point Viewer\226\128\166', -- "Focus Point Viewer…"
			file = 'ShowFocusPointViewer.lua',
		},
		{
			title = 'Show Focus Point',
			file = 'ShowFocusPoint.lua',
			enabledWhen = 'photosSelected',
		},
		{
			title = 'Read Focus Metadata for Selected Photos',
			file = 'ReadFocusMetadata.lua',
			enabledWhen = 'photosSelected',
		},
	}
end

return {
	LrSdkVersion = 10.0,
	LrSdkMinimumVersion = 6.0,

	LrToolkitIdentifier = 'dev.focuspoint.lightroom',
	LrPluginName = 'Focus Point',

	-- Library > Plug-in Extras
	LrLibraryMenuItems = menuItems(),
	-- File > Plug-in Extras (available in every module, incl. Develop)
	LrExportMenuItems = menuItems(),

	LrMetadataProvider = 'MetadataDefinition.lua',
	LrMetadataTagsetFactory = 'MetadataTagset.lua',

	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	VERSION = { major = 0, minor = 1, revision = 0, build = 0, display = '0.1.0' },
}
