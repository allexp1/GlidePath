-- The nightly sync schedule.
--
-- pg_cron cannot call an Edge Function directly, so it makes an HTTP request
-- through pg_net. The URL and the service role key come from Supabase Vault
-- rather than being written into the migration, because a migration is
-- committed to git and a service role key must never be.
--
-- Before this schedule can do anything, store the two secrets once:
--
--   select vault.create_secret('https://YOUR-REF.supabase.co', 'project_url');
--   select vault.create_secret('YOUR-SERVICE-ROLE-KEY',        'service_role_key');
--
-- `make seed` prints this reminder. Until the secrets exist the job runs and
-- fails harmlessly, leaving last_sync_error set on every country.
--
-- 03:17 UTC rather than a round hour: Overpass is a shared volunteer service
-- and the top of the hour is when everybody else's cron fires.

do $$
begin
  -- Re-running migrations must not stack duplicate schedules.
  perform cron.unschedule('glidepath-nightly-sync');
exception
  when others then
    null;
end;
$$;

do $$
begin
  perform cron.schedule(
    'glidepath-nightly-sync',
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
