-- The app was renamed from GlidePath to Zonexplo, and the nightly schedule
-- carries the old name.
--
-- This is a new migration rather than an edit to 20260729120600_schedule.sql,
-- and the distinction matters. That migration has already run against the
-- project: editing it would change what the file claims was applied without
-- changing anything in the database, and the schedule would keep its old name
-- forever while the repository insisted otherwise. Applied migrations are a
-- record of what happened, not a description of the current state.
--
-- The job body is copied verbatim from the original. Only the name changes.

do $$
begin
  perform cron.unschedule('glidepath-nightly-sync');
exception
  when others then
    -- Nothing to remove on a database created after the rename, or on a local
    -- stack with no pg_cron. Neither is a failure.
    null;
end;
$$;

do $$
begin
  -- Re-running migrations must not stack duplicate schedules.
  perform cron.unschedule('zonexplo-nightly-sync');
exception
  when others then
    null;
end;
$$;

do $$
begin
  perform cron.schedule(
    'zonexplo-nightly-sync',
    '17 3 * * *',
    $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
             || '/functions/v1/sync-cameras',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
      ),
      body := jsonb_build_object('trigger', 'cron'),
      timeout_milliseconds := 300000
    );
    $job$
  );
exception
  when others then
    -- A local `supabase start` stack may not have pg_cron wired up. The schema
    -- is still valid and the Edge Function can be invoked by hand, so this is a
    -- warning rather than a failed migration.
    raise warning 'could not install the nightly sync schedule: %', sqlerrm;
end;
$$;
