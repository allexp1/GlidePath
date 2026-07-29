-- GlidePath schema, part 4: row level security.
--
-- The shape of it: camera data is public and read-only to everyone, community
-- reports are write-only to the driver who filed them, and every write that
-- actually changes what drivers see is done by the service role from the
-- nightly job or the seed script.
--
-- The anon key is therefore safe to ship inside the app binary, which is the
-- whole reason the phone can talk to Supabase directly with no server in
-- between.

-- ---------------------------------------------------------------------------
-- Public read
-- ---------------------------------------------------------------------------

alter table public.countries enable row level security;
alter table public.zones enable row level security;
alter table public.road_segments enable row level security;
alter table public.cameras enable row level security;
alter table public.rest_stops enable row level security;

create policy "countries are world readable"
  on public.countries for select
  to anon, authenticated
  using (true);

create policy "zones are world readable"
  on public.zones for select
  to anon, authenticated
  using (true);

create policy "road segments are world readable"
  on public.road_segments for select
  to anon, authenticated
  using (true);

create policy "cameras are world readable"
  on public.cameras for select
  to anon, authenticated
  using (true);

create policy "rest stops are world readable"
  on public.rest_stops for select
  to anon, authenticated
  using (true);

-- No insert, update or delete policies on any of the above. Without a policy
-- the action is denied, so writes are possible only for the service role, which
-- bypasses RLS entirely.

-- ---------------------------------------------------------------------------
-- Community reports
-- ---------------------------------------------------------------------------

alter table public.pending_reports enable row level security;

-- A signed-in driver may file a report, but only in their own name. The
-- with check clause is what stops a report being attributed to someone else.
create policy "drivers may file their own reports"
  on public.pending_reports for insert
  to authenticated
  with check (reporter_id = auth.uid());

-- They can see what they filed and what came of it. They cannot see anyone
-- else's, which keeps unreviewed reports from becoming a de facto public feed
-- of unverified camera locations.
create policy "drivers may read their own reports"
  on public.pending_reports for select
  to authenticated
  using (reporter_id = auth.uid());

-- Deliberately no update or delete policy. A report is a statement of what
-- someone saw at a moment in time; editing it after review would corrupt the
-- audit trail the dashboard depends on.

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

-- Supabase's default privileges usually cover this, but a self-hosted stack or
-- a project with tightened defaults will not, and a missing grant fails in a
-- confusing way at runtime. Being explicit costs nothing.

grant usage on schema public to anon, authenticated;

grant select on
  public.countries,
  public.zones,
  public.road_segments,
  public.cameras,
  public.rest_stops
to anon, authenticated;

grant select on
  public.cameras_public,
  public.zones_public,
  public.rest_stops_public,
  public.countries_public
to anon, authenticated;

grant insert, select on public.pending_reports to authenticated;

-- The views need to reach PostGIS functions.
grant usage on schema extensions to anon, authenticated;
