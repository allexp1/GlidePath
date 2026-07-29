-- GlidePath schema, part 2: the tables.
--
-- The backend is a shared notebook, not a brain. Nothing here computes an
-- allowance, decides a coaching tier, or knows where a driver is. It stores
-- camera and zone geometry, and stamps every row with updated_at so a phone
-- can ask "what changed since I last looked".

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

-- Mirrors CameraType in GlidePathCore one for one. Adding a value here means
-- adding a case there.
create type public.camera_type as enum (
  'fixed',
  'red_light',
  'combined',
  'seatbelt_phone',
  'bus_lane',
  'mobile_hotspot',
  'zone_entry',
  'zone_exit'
);

create type public.rest_stop_kind as enum (
  'rest_area',
  'fuel_station',
  'services',
  'parking',
  'viewpoint'
);

-- Where a row came from. 'osm' rows are owned by the nightly sync and will be
-- overwritten by it; 'manual' rows are hand-entered and the sync must never
-- touch them. Israel's new average-speed sections arrive as 'manual' because
-- OpenStreetMap will not have them until well after enforcement starts.
create type public.data_source as enum ('osm', 'manual', 'report');

create type public.report_kind as enum (
  'new_camera',
  'camera_gone',
  'wrong_limit',
  'wrong_type',
  'wrong_location'
);

create type public.report_status as enum ('pending', 'approved', 'rejected');

-- ---------------------------------------------------------------------------
-- Countries
-- ---------------------------------------------------------------------------

create table public.countries (
  code text primary key,
  name text not null,

  -- Only enabled countries are pulled by the nightly job and offered in the
  -- app's download list.
  enabled boolean not null default true,

  -- Bumped every time the nightly job changes anything in this country. The
  -- phone stores the version it last synced at and asks for the delta.
  dataset_version bigint not null default 1,

  -- A phone whose stored version is below this must throw its copy away and
  -- download the country again. Raised by hand when a change is not
  -- expressible as a delta, such as re-splitting zones or fixing a systematic
  -- geometry error.
  min_compatible_version bigint not null default 1,

  -- ISO 3166-1 alpha-2 code used to build the Overpass area filter.
  overpass_iso_code text,

  last_synced_at timestamptz,
  last_sync_error text,
  updated_at timestamptz not null default now(),

  constraint countries_code_is_iso check (code ~ '^[A-Z]{2}$'),
  constraint countries_version_floor check (min_compatible_version <= dataset_version)
);

comment on table public.countries is
  'One row per downloadable country. dataset_version drives delta sync.';

-- ---------------------------------------------------------------------------
-- Zones: average-speed enforcement sections
-- ---------------------------------------------------------------------------

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  country_code text not null references public.countries (code) on update cascade,

  name text,
  road_ref text,

  entry_point extensions.geography(Point, 4326) not null,
  exit_point extensions.geography(Point, 4326) not null,

  -- Distance along the road between the two cameras. This is the number the
  -- allowance math divides by, so it must follow the carriageway, not the
  -- straight line between the endpoints.
  distance_meters double precision not null,

  speed_limit_kph double precision not null,

  -- A posted legal minimum, where one exists. The phone will never coach below
  -- it. Null is common and simply means "no posted minimum".
  minimum_speed_kph double precision,

  -- Direction of travel the section applies to. A dual carriageway is two
  -- zones, one per direction.
  direction_degrees double precision,

  source public.data_source not null default 'osm',
  osm_id text,

  -- False means "we believe this exists but nobody has confirmed it". The
  -- nightly job flips this to false rather than deleting a row that vanished
  -- upstream, so a mapping mistake in OpenStreetMap cannot silently blind the
  -- app.
  verified boolean not null default false,

  -- Last time the nightly job saw this in the upstream data.
  last_seen_at timestamptz,

  updated_at timestamptz not null default now(),

  constraint zones_distance_positive check (distance_meters > 0),
  constraint zones_limit_positive check (speed_limit_kph > 0 and speed_limit_kph <= 200),
  constraint zones_minimum_below_limit check (
    minimum_speed_kph is null
    or (minimum_speed_kph > 0 and minimum_speed_kph < speed_limit_kph)
  ),
  constraint zones_direction_range check (
    direction_degrees is null
    or (direction_degrees >= 0 and direction_degrees < 360)
  )
);

-- An OSM element maps to at most one zone.
--
-- Not a partial index, despite most hand-seeded Israeli zones having no OSM id
-- at all: PostgreSQL treats nulls as distinct in a unique index, so any number
-- of null osm_ids coexist happily. A plain index is also the only kind
-- `on conflict (osm_id)` can infer, which is what the nightly upsert relies on.
create unique index zones_osm_id_key on public.zones (osm_id);

create index zones_country_idx on public.zones (country_code);
create index zones_updated_at_idx on public.zones (updated_at);
create index zones_entry_gix on public.zones using gist (entry_point);

-- ---------------------------------------------------------------------------
-- Road geometry
-- ---------------------------------------------------------------------------

-- The polyline a zone follows. Split into ordered segments because a section
-- assembled from OSM ways arrives in pieces, and stitching them in the database
-- would be logic the backend is not supposed to have.
create table public.road_segments (
  id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones (id) on delete cascade,
  sequence integer not null default 0,
  polyline extensions.geography(LineString, 4326) not null,
  updated_at timestamptz not null default now(),

  unique (zone_id, sequence)
);

create index road_segments_zone_idx on public.road_segments (zone_id);
create index road_segments_gix on public.road_segments using gist (polyline);

-- ---------------------------------------------------------------------------
-- Cameras
-- ---------------------------------------------------------------------------

create table public.cameras (
  id uuid primary key default gen_random_uuid(),
  country_code text not null references public.countries (code) on update cascade,

  location extensions.geography(Point, 4326) not null,
  type public.camera_type not null,

  -- Direction of travel this camera catches, not where the housing points.
  -- Null means both directions, which is also how unknown is stored: a warning
  -- about an irrelevant camera is a much smaller failure than silence about a
  -- real one.
  direction_degrees double precision,

  speed_limit_kph double precision,

  -- Set for zone entry and exit markers.
  zone_id uuid references public.zones (id) on delete set null,

  source public.data_source not null default 'osm',
  osm_id text,
  verified boolean not null default true,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now(),

  constraint cameras_limit_sane check (
    speed_limit_kph is null or (speed_limit_kph > 0 and speed_limit_kph <= 200)
  ),
  constraint cameras_direction_range check (
    direction_degrees is null
    or (direction_degrees >= 0 and direction_degrees < 360)
  ),
  -- A zone marker without a zone is meaningless.
  constraint cameras_zone_marker_has_zone check (
    type not in ('zone_entry', 'zone_exit') or zone_id is not null
  )
);

create unique index cameras_osm_id_key on public.cameras (osm_id);

create index cameras_country_idx on public.cameras (country_code);
create index cameras_updated_at_idx on public.cameras (updated_at);
create index cameras_zone_idx on public.cameras (zone_id) where zone_id is not null;

-- The index that matters at runtime: "cameras near this point", which the app
-- runs every time it refreshes its geofences.
create index cameras_location_gix on public.cameras using gist (location);

-- ---------------------------------------------------------------------------
-- Rest stops
-- ---------------------------------------------------------------------------

create table public.rest_stops (
  id uuid primary key default gen_random_uuid(),
  country_code text not null references public.countries (code) on update cascade,
  zone_id uuid references public.zones (id) on delete cascade,

  name text,
  location extensions.geography(Point, 4326) not null,
  kind public.rest_stop_kind not null,

  -- Distance from the zone entry along the road. Precomputed by the seed and
  -- sync jobs so the phone never has to project on the hot path.
  distance_along_meters double precision,

  source public.data_source not null default 'osm',
  osm_id text,
  last_seen_at timestamptz,
  updated_at timestamptz not null default now()
);

create unique index rest_stops_osm_id_key on public.rest_stops (osm_id);

create index rest_stops_zone_idx on public.rest_stops (zone_id) where zone_id is not null;
create index rest_stops_country_idx on public.rest_stops (country_code);
create index rest_stops_updated_at_idx on public.rest_stops (updated_at);
create index rest_stops_location_gix on public.rest_stops using gist (location);

-- ---------------------------------------------------------------------------
-- Community reports
-- ---------------------------------------------------------------------------

-- Drivers write here; nothing here is served to other drivers until a human
-- promotes it. Keeping reports in their own table is what lets the read tables
-- stay world-readable without also being world-writable.
create table public.pending_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references auth.users (id) on delete cascade,

  country_code text references public.countries (code) on update cascade,
  kind public.report_kind not null,

  location extensions.geography(Point, 4326) not null,
  camera_type public.camera_type,
  speed_limit_kph double precision,

  -- Set when the report is about an existing row.
  camera_id uuid references public.cameras (id) on delete set null,

  note text,
  status public.report_status not null default 'pending',

  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,

  constraint pending_reports_note_length check (note is null or length(note) <= 500),
  constraint pending_reports_limit_sane check (
    speed_limit_kph is null or (speed_limit_kph > 0 and speed_limit_kph <= 200)
  )
);

create index pending_reports_status_idx on public.pending_reports (status, created_at desc);
create index pending_reports_reporter_idx on public.pending_reports (reporter_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

-- Delta sync is only as trustworthy as this column, so it is maintained by a
-- trigger rather than by whoever happens to be writing.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger countries_touch_updated_at
  before update on public.countries
  for each row execute function public.touch_updated_at();

create trigger zones_touch_updated_at
  before update on public.zones
  for each row execute function public.touch_updated_at();

create trigger road_segments_touch_updated_at
  before update on public.road_segments
  for each row execute function public.touch_updated_at();

create trigger cameras_touch_updated_at
  before update on public.cameras
  for each row execute function public.touch_updated_at();

create trigger rest_stops_touch_updated_at
  before update on public.rest_stops
  for each row execute function public.touch_updated_at();
