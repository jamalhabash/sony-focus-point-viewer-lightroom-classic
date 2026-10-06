--[[----------------------------------------------------------------------------
MetadataTagset.lua  (LrMetadataTagsetFactory)

Optional "Focus Point" tagset for the Metadata panel's preset popup.
------------------------------------------------------------------------------]]

return {
	id = 'focusPointTagset',
	title = 'Focus Point',
	items = {
		'com.adobe.filename',
		'com.adobe.model',
		'com.adobe.lens',
		'com.adobe.exposure',
		'com.adobe.separator',
		{ 'com.adobe.label', label = 'Autofocus' },
		'dev.focuspoint.lightroom.focusMode',
		'dev.focuspoint.lightroom.afAreaMode',
		'dev.focuspoint.lightroom.focusPoint',
		'dev.focuspoint.lightroom.afTracking',
		'dev.focuspoint.lightroom.focusStatus',
	},
}
