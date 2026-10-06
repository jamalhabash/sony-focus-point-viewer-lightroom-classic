--[[----------------------------------------------------------------------------
MetadataDefinition.lua  (LrMetadataProvider)

Plug-in metadata fields filled by "Read Focus Metadata for Selected Photos".
They appear in the Metadata panel (tagsets "Focus Point", "All Plug-in
Metadata", "All") and, being searchable, can be used in the Library Filter
(Text / smart collections). Browsable fields also appear as columns in the
Library Filter's Metadata browser.

Field ids must not change once released (they key the stored values). If a
field definition changes incompatibly (e.g. searchable), bump its `version`
and `schemaVersion`.
------------------------------------------------------------------------------]]

return {
	metadataFieldsForPhotos = {
		{
			id = 'focusMode',
			title = 'Focus Mode',
			dataType = 'string',
			readOnly = true,
			searchable = true,
			browsable = true,
		},
		{
			id = 'afAreaMode',
			title = 'AF Area Mode',
			dataType = 'string',
			readOnly = true,
			searchable = true,
			browsable = true,
		},
		{
			-- "x%, y%" of the displayed frame. Searchable but not browsable:
			-- nearly every photo has a different value.
			id = 'focusPoint',
			title = 'Focus Point',
			dataType = 'string',
			readOnly = true,
			searchable = true,
		},
		{
			id = 'afTracking',
			title = 'AF Tracking',
			dataType = 'string',
			readOnly = true,
			searchable = true,
			browsable = true,
		},
		{
			-- ok / no focus / unsupported – handy for finding MF shots or
			-- photos the plug-in can't read.
			id = 'focusStatus',
			title = 'Focus Data',
			dataType = 'string',
			readOnly = true,
			searchable = true,
			browsable = true,
		},
	},
	schemaVersion = 1,
}
