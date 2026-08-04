-- Cache the country's bounding box.
--
-- Every chunk of a harvest re-resolved it, and resolving it is not cheap: it is
-- an Overpass area lookup against the admin relation, the same expensive step
-- that dominates the tile queries themselves. Paying it once per country is
-- correct; paying it once per chunk means a fifty-chunk run pays it fifty times,
-- and on Moldova that overhead was a large share of a 150 second invocation
-- ceiling that the harvest has to fit inside.
--
-- Stored as jsonb rather than four columns because nothing in SQL ever looks
-- inside it. It is handed back to the tiler exactly as it arrived.
alter table public.countries
  add column road_limits_bounds jsonb;

comment on column public.countries.road_limits_bounds is
  'Cached Overpass bounding box {minLat,minLon,maxLat,maxLon} for the limit '
  'tiler. Cleared by a reset; refetched when null.';
