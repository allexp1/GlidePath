-- GlidePath schema, part 5: the bookkeeping the sync job leans on.
--
-- These are service-role only. They are data plumbing, not product logic: none
-- of them decides anything a driver experiences, they just keep updated_at,
-- verified and dataset_version consistent so delta sync stays trustworthy.

-- ---------------------------------------------------------------------------
-- Closing out a sync run
-- ---------------------------------------------------------------------------

-- Called once per country after the nightly job has finished upserting.
--
-- Anything sourced from OpenStreetMap that the job did not touch this run has
-- vanished upstream. It is marked unverified rather than deleted: OSM edits get
-- reverted, areas get re-tagged, and a mapping accident must not be able to
-- silently switch off warnings for a real camera. Flipping the flag bumps
-- updated_at, so phones pick the change up on their next delta.
--
-- Manual rows are never touched. Israel's hand-seeded sections do not appear in
-- Overpass and would be wiped on the first run otherwise.
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

  -- A camera seen again after having been marked missing is trustworthy once
  -- more. Without this a single Overpass timeout would permanently degrade the
  -- dataset.
  update public.cameras
     set verified = true
   where country_code = p_country_code
     and source = 'osm'
     and not verified
     and last_seen_at >= p_run_started_at;

  update public.countries
     set dataset_version = dataset_version + 1,
         last_synced_at = now(),
         last_sync_error = null
   where code = p_country_code
  returning dataset_version into v_version;

  return v_version;
end;
$$;

revoke all on function public.finish_country_sync(text, timestamptz, text) from public;
grant execute on function public.finish_country_sync(text, timestamptz, text) to service_role;

-- ---------------------------------------------------------------------------
-- Recomputing where rest stops sit along a zone
-- ---------------------------------------------------------------------------

-- The phone needs distance-along-the-road for every rest stop so it can offer
-- the driver one that is still ahead of them. Computing it here, once, beats
-- projecting on the phone every second.
create or replace function public.refresh_rest_stop_distances(p_zone_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line extensions.geometry;
  v_length double precision;
  v_updated integer;
begin
  -- Stitch the zone's segments back into one line, in order.
  --
  -- ST_Collect rather than ST_Union: Union dissolves and re-nodes the input,
  -- which can flip the direction of the result. Direction matters here, because
  -- ST_LineLocatePoint measures from the start of the line and a reversed line
  -- would place every rest stop at the wrong end of the zone.
  select extensions.st_linemerge(
           extensions.st_collect(polyline::extensions.geometry order by sequence)
         )
    into v_line
    from public.road_segments
   where zone_id = p_zone_id;

  if v_line is null then
    return 0;
  end if;

  -- Segments that do not actually join leave a MultiLineString behind, and
  -- ST_LineLocatePoint has no meaning on one. Better to leave the distances
  -- null, which makes the phone skip those stops, than to record a wrong one
  -- and route a driver backwards.
  if extensions.st_geometrytype(v_line) <> 'ST_LineString' then
    return 0;
  end if;

  v_length := extensions.st_length(v_line::extensions.geography);
  if v_length is null or v_length <= 0 then
    return 0;
  end if;

  update public.rest_stops r
     set distance_along_meters = extensions.st_linelocatepoint(
           v_line,
           r.location::extensions.geometry
         ) * v_length
   where r.zone_id = p_zone_id;

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.refresh_rest_stop_distances(uuid) from public;
grant execute on function public.refresh_rest_stop_distances(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Promoting community reports
-- ---------------------------------------------------------------------------

-- What the dashboard calls when a human accepts a report. Promoted rows are
-- marked source = 'report' so the nightly OSM job leaves them alone.
create or replace function public.approve_report(p_report_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_report public.pending_reports;
  v_camera_id uuid;
begin
  select * into v_report from public.pending_reports where id = p_report_id;

  if v_report.id is null then
    raise exception 'report % not found', p_report_id;
  end if;
  if v_report.status <> 'pending' then
    raise exception 'report % has already been %', p_report_id, v_report.status;
  end if;

  case v_report.kind
    when 'new_camera' then
      insert into public.cameras (country_code, location, type, speed_limit_kph, source, verified)
      values (
        v_report.country_code,
        v_report.location,
        coalesce(v_report.camera_type, 'fixed'),
        v_report.speed_limit_kph,
        'report',
        true
      )
      returning id into v_camera_id;

    when 'camera_gone' then
      update public.cameras set verified = false where id = v_report.camera_id
      returning id into v_camera_id;

    when 'wrong_limit' then
      update public.cameras set speed_limit_kph = v_report.speed_limit_kph
       where id = v_report.camera_id
      returning id into v_camera_id;

    when 'wrong_type' then
      update public.cameras set type = v_report.camera_type
       where id = v_report.camera_id
      returning id into v_camera_id;

    when 'wrong_location' then
      update public.cameras set location = v_report.location
       where id = v_report.camera_id
      returning id into v_camera_id;

    else
      raise exception 'report kind % has no promotion path', v_report.kind;
  end case;

  update public.pending_reports
     set status = 'approved',
         reviewed_at = now(),
         reviewed_by = auth.uid()
   where id = p_report_id;

  -- Drivers should get the correction on their next launch, not their next
  -- nightly sync.
  update public.countries
     set dataset_version = dataset_version + 1
   where code = v_report.country_code;

  return v_camera_id;
end;
$$;

revoke all on function public.approve_report(uuid) from public;
grant execute on function public.approve_report(uuid) to service_role;

create or replace function public.reject_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.pending_reports
     set status = 'rejected',
         reviewed_at = now(),
         reviewed_by = auth.uid()
   where id = p_report_id
     and status = 'pending';
end;
$$;

revoke all on function public.reject_report(uuid) from public;
grant execute on function public.reject_report(uuid) to service_role;
