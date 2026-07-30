-- Stop a failed harvest from fading a whole country.
--
-- `finish_country_sync` marks anything it did not see this run as unverified,
-- which is the right behaviour for a camera that has genuinely been removed from
-- OpenStreetMap. It is the wrong behaviour when the reason the job did not see it
-- is that Overpass answered with an empty result set.
--
-- That is not hypothetical. Two runs against Lithuania minutes apart returned 0
-- and then 578 camera nodes for the same query, over the same area filter, with
-- HTTP 200 both times. Had there been 578 rows stored already, the empty run
-- would have marked every one of them unverified and the app would have shown
-- every camera in the country as a faded guess until the next good run.
--
-- So: a run that would unverify most of a country is not believed. A real mapping
-- change removes a camera or two, not half the dataset. The suspicion is recorded
-- against the country rather than silently swallowed, because a country that
-- genuinely was decommissioned wholesale needs somebody to look at it.

create or replace function public.finish_country_sync(
  p_country_code text,
  p_run_started_at timestamptz,
  p_error text default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_version bigint;
  v_cameras_held bigint;
  v_cameras_missing bigint;
  v_zones_held bigint;
  v_zones_missing bigint;
  v_refused text := null;

  -- Above this share of a country going missing in one run, disbelieve the run.
  c_ceiling constant numeric := 0.5;
  -- Below this many rows, shares are meaningless: three cameras vanishing out of
  -- four is entirely possible in a country with four.
  c_floor constant bigint := 10;
begin
  if p_error is not null then
    update public.countries
       set last_sync_error = p_error,
           last_synced_at = now()
     where code = p_country_code;

    select dataset_version into v_version
      from public.countries where code = p_country_code;
    return v_version;
  end if;

  select count(*),
         count(*) filter (where last_seen_at is null or last_seen_at < p_run_started_at)
    into v_cameras_held, v_cameras_missing
    from public.cameras
   where country_code = p_country_code and source = 'osm' and verified;

  select count(*),
         count(*) filter (where last_seen_at is null or last_seen_at < p_run_started_at)
    into v_zones_held, v_zones_missing
    from public.zones
   where country_code = p_country_code and source = 'osm' and verified;

  if v_cameras_held >= c_floor and v_cameras_missing::numeric / v_cameras_held > c_ceiling then
    v_refused := format(
      'refused to unverify %s of %s cameras in one run; treating the harvest as incomplete',
      v_cameras_missing, v_cameras_held
    );
  elsif v_zones_held >= c_floor and v_zones_missing::numeric / v_zones_held > c_ceiling then
    v_refused := format(
      'refused to unverify %s of %s zones in one run; treating the harvest as incomplete',
      v_zones_missing, v_zones_held
    );
  end if;

  if v_refused is null then
    update public.cameras
       set verified = false
     where country_code = p_country_code
       and source = 'osm'
       and verified
       and (last_seen_at is null or last_seen_at < p_run_started_at);

    update public.zones
       set verified = false
     where country_code = p_country_code
       and source = 'osm'
       and verified
       and (last_seen_at is null or last_seen_at < p_run_started_at);
  end if;

  -- A camera seen again after having been marked missing is trustworthy once
  -- more. Without this a single Overpass timeout would permanently degrade the
  -- dataset. Runs unconditionally: recovery is never the risky direction.
  update public.cameras
     set verified = true
   where country_code = p_country_code
     and source = 'osm'
     and not verified
     and last_seen_at >= p_run_started_at;

  update public.zones
     set verified = true
   where country_code = p_country_code
     and source = 'osm'
     and not verified
     and last_seen_at >= p_run_started_at;

  update public.countries
     set dataset_version = dataset_version + 1,
         last_synced_at = now(),
         last_sync_error = v_refused
   where code = p_country_code
  returning dataset_version into v_version;

  return v_version;
end;
$$;

revoke all on function public.finish_country_sync(text, timestamptz, text) from public;
grant execute on function public.finish_country_sync(text, timestamptz, text) to service_role;

comment on function public.finish_country_sync(text, timestamptz, text) is
  'Closes a sync run. Refuses to unverify more than half a country at once, '
  'because that is what a failed Overpass harvest looks like rather than a '
  'mapping change, and records the refusal in countries.last_sync_error.';
