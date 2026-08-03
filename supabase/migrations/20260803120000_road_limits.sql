-- Posted speed limits for the road the driver is actually on.
--
-- Everything before this migration answers "what is enforced *here*", at a
-- camera or across a section. This answers the ordinary question in between:
-- what does the sign say on this road, right now.
--
-- It is a different shape of dataset from the rest of the schema and the
-- differences drive most of the decisions below:
--
-- * **It is large.** Cameras in a country number in the hundreds. Ways with a
--   posted limit number in the hundreds of thousands. Geometry is simplified to
--   8 m before it ever reaches here, and it still dwarfs everything else.
-- * **It is harvested in tiles.** Overpass cannot return a country's road
--   network in one answer, so a run is a few hundred separate queries and can
--   legitimately stop half way. `finish_road_limit_sync` therefore has to be
--   told whether the run it is closing actually covered the country.
-- * **It carries its own version.** A phone that has downloaded limits should
--   not re-download them because a camera moved, and should not re-download a
--   country's cameras because a limit was retagged.

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

create table public.road_limits (
  id uuid primary key default gen_random_uuid(),
  country_code text not null references public.countries (code) on update cascade,

  name text,
  road_ref text,

  -- The OSM highway class. Kept because it is the only thing that explains a
  -- surprising limit after the fact, and because a future decision to stop
  -- serving some class of road should not need a re-harvest.
  highway text not null,

  polyline extensions.geography(LineString, 4326) not null,

  -- What to use when the direction of travel cannot be established.
  limit_kph double precision not null,

  -- Set only where the two directions genuinely differ. Forward means along
  -- the stored geometry, which is OSM's digitisation order.
  forward_limit_kph double precision,
  backward_limit_kph double precision,

  source public.data_source not null default 'osm',
  osm_id text,

  -- A way that vanished upstream, same contract as cameras: never hard
  -- deleted, because a delta sync cannot carry a deletion and because an OSM
  -- edit war must not be able to silently change what the app tells a driver.
  -- The phone ignores unverified limits.
  verified boolean not null default true,

  last_seen_at timestamptz,
  updated_at timestamptz not null default now(),

  constraint road_limits_limit_sane check (limit_kph > 0 and limit_kph <= 200),
  constraint road_limits_forward_sane check (
    forward_limit_kph is null or (forward_limit_kph > 0 and forward_limit_kph <= 200)
  ),
  constraint road_limits_backward_sane check (
    backward_limit_kph is null or (backward_limit_kph > 0 and backward_limit_kph <= 200)
  )
);

comment on table public.road_limits is
  'Posted speed limits per OSM way. Large: hundreds of thousands of rows per '
  'country. Downloaded to the phone as a separate opt-in per country.';

create unique index road_limits_osm_id_key on public.road_limits (osm_id);

create index road_limits_country_idx on public.road_limits (country_code);

-- The delta sync index. Compound rather than on updated_at alone: every query
-- the phone makes is filtered by country first, and a national dataset this
-- size makes the difference between the two plans very visible.
create index road_limits_country_updated_idx
  on public.road_limits (country_code, updated_at);

create index road_limits_gix on public.road_limits using gist (polyline);

create trigger road_limits_touch_updated_at
  before update on public.road_limits
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Country bookkeeping
-- ---------------------------------------------------------------------------

alter table public.countries
  -- Its own version line. Bumping dataset_version for a limit change would make
  -- every phone re-check its cameras, and bumping it for a camera change would
  -- make every phone re-check a dataset three orders of magnitude larger.
  add column road_limit_version bigint not null default 0,

  -- Maintained by finish_road_limit_sync rather than counted in the view. The
  -- catalogue is 243 rows and a count(*) per row over a table this size is the
  -- one query in this schema that could genuinely time out.
  add column road_limit_count integer not null default 0,

  add column road_limits_synced_at timestamptz,
  add column road_limits_sync_error text;

-- ---------------------------------------------------------------------------
-- Read surface
-- ---------------------------------------------------------------------------

create view public.road_limits_public
with (security_invoker = true) as
select
  r.id,
  r.country_code,
  r.name,
  r.road_ref,
  r.highway,
  r.limit_kph,
  r.forward_limit_kph,
  r.backward_limit_kph,
  r.verified,
  extensions.st_asgeojson(r.polyline::extensions.geometry)::jsonb as path,
  r.updated_at
from public.road_limits r;

comment on view public.road_limits_public is
  'Speed limits with the geometry as GeoJSON, matching zones_public. Filter by '
  'country_code and updated_at; never select this unfiltered.';

-- countries_public gains the three columns the download screen needs to offer
-- limits as a separate download and to say how big it is. Replaced rather than
-- altered: existing columns keep their names, types and order, so this is the
-- one shape `create or replace view` accepts.
create or replace view public.countries_public
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
  (select count(*) from public.zones where country_code = c.code) as zone_count,
  c.road_limit_version,
  c.road_limit_count,
  c.road_limits_synced_at
from public.countries c
where c.enabled;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.road_limits enable row level security;

create policy "road limits are world readable"
  on public.road_limits for select
  to anon, authenticated
  using (true);

grant select on public.road_limits to anon, authenticated;
grant select on public.road_limits_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Closing out a limit harvest
-- ---------------------------------------------------------------------------

-- The road-limit equivalent of finish_country_sync, with one extra argument
-- that matters more here than anywhere else in the schema.
--
-- A camera harvest is a single query: either it worked or it did not. A limit
-- harvest is a few hundred tiled queries, and stopping after 200 of them is a
-- perfectly ordinary outcome - a rate limit, a timeout, someone pressing
-- ctrl-C. Every way in the 300 tiles that were never fetched looks exactly like
-- a way that has been deleted from OpenStreetMap.
--
-- So the caller has to say whether it covered the country. A partial run writes
-- what it found and touches nothing else. Only a complete run is allowed to
-- conclude that an unseen way is a gone way, and even then the same
-- more-than-half guard as finish_country_sync applies, because a complete run
-- made entirely of empty answers is still a failed harvest.
create or replace function public.finish_road_limit_sync(
  p_country_code text,
  p_run_started_at timestamptz,
  p_complete boolean default false,
  p_error text default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_version bigint;
  v_held bigint;
  v_missing bigint;
  v_note text := null;

  c_ceiling constant numeric := 0.5;
  c_floor constant bigint := 100;
begin
  if p_error is not null then
    update public.countries
       set road_limits_sync_error = p_error,
           road_limits_synced_at = now()
     where code = p_country_code;

    select road_limit_version into v_version
      from public.countries where code = p_country_code;
    return v_version;
  end if;

  if not p_complete then
    v_note := 'partial harvest: tiles were left unfetched, so nothing was retired';
  else
    select count(*),
           count(*) filter (where last_seen_at is null or last_seen_at < p_run_started_at)
      into v_held, v_missing
      from public.road_limits
     where country_code = p_country_code and source = 'osm' and verified;

    if v_held >= c_floor and v_missing::numeric / v_held > c_ceiling then
      v_note := format(
        'refused to unverify %s of %s road limits in one run; treating the harvest as incomplete',
        v_missing, v_held
      );
    else
      update public.road_limits
         set verified = false
       where country_code = p_country_code
         and source = 'osm'
         and verified
         and (last_seen_at is null or last_seen_at < p_run_started_at);
    end if;
  end if;

  -- Recovery runs whatever happened. A way seen again is a way that is there,
  -- and restoring a limit is never the dangerous direction.
  update public.road_limits
     set verified = true
   where country_code = p_country_code
     and source = 'osm'
     and not verified
     and last_seen_at >= p_run_started_at;

  update public.countries
     set road_limit_version = road_limit_version + 1,
         road_limit_count = (
           select count(*) from public.road_limits
            where country_code = p_country_code and verified
         ),
         road_limits_synced_at = now(),
         road_limits_sync_error = v_note
   where code = p_country_code
  returning road_limit_version into v_version;

  return v_version;
end;
$$;

revoke all on function public.finish_road_limit_sync(text, timestamptz, boolean, text) from public;
grant execute on function public.finish_road_limit_sync(text, timestamptz, boolean, text) to service_role;

comment on function public.finish_road_limit_sync(text, timestamptz, boolean, text) is
  'Closes a road-limit harvest. Only a run that reports covering the whole '
  'country may retire unseen ways, because a tiled harvest stopping early is '
  'indistinguishable from every way in the missing tiles having been deleted.';
