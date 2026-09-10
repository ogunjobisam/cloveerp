-- A zone is a place that holds other places.
--
-- The warehouse layout screen offers a parent for every location, and the
-- natural parent — the zone — was not a kind of place the enum admitted, so a
-- hierarchy could only be built out of bulk locations pretending to be zones.
-- Stock never stands in a zone; it stands in the bins beneath it.
alter type erp.location_type add value if not exists 'zone' before 'bulk';