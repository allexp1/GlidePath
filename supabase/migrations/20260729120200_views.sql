-- GlidePath schema, part 3: the read surface.
--
-- The phone talks to these views, never to the tables. Two reasons:
--
-- 1. PostgREST hands back geography columns as WKB hex, which would mean a WKB
--    parser on the phone for no benefit. The views project plain lat/lon
--    doubles and GeoJSON instead.
-- 2. They are the delta sync contract. Every view carries updated_at, so a
--    client syncs with `?updated_at=gt.<last>` and nothing else.
--
-- security_invoker means row level security is evaluated as the caller, not as
-- the view owner. Without it these views would be a hole straight through RLS.

-- ---------------------------------------------------------------------------

create view public.cameras_public
with (security_invoker = true) as
select
  c.id,
  c.country_code,
  extensions.st_y(c.location::extensions.geometry) as latitude,
  extensions.st_x(c.location::extensions.geometry) as longitude,
  c.type,
  c.direction_degrees,
  c.speed_limit_kph,
  c.zone_id,
  c.verified,
  c.osm_id,
  c.updated_at
from public.cameras c;

comment on view public.cameras_public is
  'Every camera, including unverified ones. The client decides how to treat '
  'verified = false; it must still receive the row so it can stop warning.';

-- ---------------------------------------------------------------------------

create view public.zones_public
with (security_invoker = true) as
select
  z.id,
  z.country_code,
  z.name,
  z.road_ref,
  extensions.st_y(z.entry_point::extensions.geometry) as entry_latitude,
  extensions.st_x(z.entry_point::extensions.geometry) as entry_longitude,
  extensions.st_y(z.exit_point::extensions.geometry) as exit_latitude,
  extensions.st_x(z.exit_point::extensions.geometry) as exit_longitude,
  z.distance_meters,
  z.speed_limit_kph,
  z.minimum_speed_kph,
  z.direction_degrees,
  z.verified,
  z.osm_id,

  -- The road geometry as an ordered array of GeoJSON LineStrings, one per
  -- segment. The client concatenates them; a repeated junction point between
  -- consecutive segments is harmless because a zero-length step contributes
  -- nothing to distance along the path.
  segments.geojson as path_segments,

  z.updated_at
from public.zones z
left join lateral (
  select jsonb_agg(
           extensions.st_asgeojson(rs.polyline::extensions.geometry)::jsonb
           order by rs.sequence
         ) as geojson
  from public.road_segments rs
  where rs.zone_id = z.id
) segments on true;

-- ---------------------------------------------------------------------------

create view public.rest_stops_public
with (security_invoker = true) as
select
  r.id,
  r.country_code,
  r.zone_id,
  r.name,
  extensions.st_y(r.location::extensions.geometry) as latitude,
  extensions.st_x(r.location::extensions.geometry) as longitude,
  r.kind,
  r.distance_along_meters,
  r.updated_at
from public.rest_stops r;

-- ---------------------------------------------------------------------------

create view public.countries_public
with (security_invoker = true) as
select
  c.code,
  c.name,
  c.enabled,
  c.dataset_version,
  c.min_compatible_version,
  c.last_synced_at,
  c.updated_at,
  (select count(*) from public.cameras where country_code = c.code) as camera_count,
  (select count(*) from public.zones where country_code = c.code) as zone_count
from public.countries c
where c.enabled;

comment on view public.countries_public is
  'The download list. camera_count and zone_count let the app show a size '
  'estimate before a driver commits to a download on mobile data.';
