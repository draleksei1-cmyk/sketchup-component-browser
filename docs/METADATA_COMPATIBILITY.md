# Metadata compatibility

Library assets are identified by UUID, never by the display name, so duplicate names remain distinct assets. A future optional `object` (`Объект`) metadata field is additive: assets without it must continue to load unchanged. This change does not add a field to the interface.
