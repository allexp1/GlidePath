-- Server-side progress for a road-limit harvest.
--
-- The harvest was built as a seed-CLI job for a good reason: it is a few
-- hundred tiled Overpass queries and runs for the better part of an hour on a
-- large country, which is far longer than an Edge Function is allowed to live.
-- The comment at the top of _shared/limits.ts says exactly that.
--
-- What that reasoning missed is that the length only rules out doing it in *one*
-- invocation. `syncRoadLimits` already accepts a set of finished tiles and
-- reports each one as it lands, because it was written to survive a ctrl-C. Move
-- that resume point from a local checkpoint file into the database and the same
-- function can be driven by many short invocations instead of one long process
-- - which is what lets a country be harvested by anyone who can call the
-- function, rather than only from a laptop with the seed CLI installed.
--
-- Two pieces of state are needed for that, and both are here.

-- ---------------------------------------------------------------------------
-- Which tiles are already done
-- ---------------------------------------------------------------------------

create table public.road_limit_harvest (
  country_code text not null references public.countries (code) on update cascade,

  -- geo.ts tileKey(): the four corners to four decimal places. Opaque here; the
  -- only thing this table does with it is hand it back to the next invocation.
  tile_key text not null,

  completed_at timestamptz not null default now(),

  primary key (country_code, tile_key)
);

comment on table public.road_limit_harvest is
  'Tiles already fetched by an in-flight road-limit harvest. Rows are deleted '
  'when the country completes, so a non-empty set means a run is part way '
  'through and the next invocation should resume rather than start over.';

-- Bookkeeping the service role writes and nobody reads. RLS on with no policy
-- at all is the correct shape for that: the service role bypasses RLS, and
-- every other role is denied by default.
alter table public.road_limit_harvest enable row level security;

-- ---------------------------------------------------------------------------
-- When the current run began
-- ---------------------------------------------------------------------------

alter table public.countries
  -- Held across invocations, and that is the whole point of storing it.
  --
  -- finish_road_limit_sync retires ways whose last_seen_at predates the run. A
  -- chunked harvest that used each invocation's own clock would therefore
  -- retire everything the previous chunk had just written, and the country
  -- would converge on holding only the final chunk's tiles. The first
  -- invocation stamps this; every later one reuses it; finishing clears it.
  add column road_limits_run_started_at timestamptz;

comment on column public.countries.road_limits_run_started_at is
  'Start of the in-flight harvest, or null when none is running. Every chunk of '
  'a resumed run must pass this same value to finish_road_limit_sync.';
