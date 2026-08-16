-- Make the report queue reach a human.
--
-- Reports land at 'pending' and reach no phone, which is what makes an
-- anonymous write endpoint acceptable. It also makes the queue invisible: it
-- changes nothing, warns nobody, and waits for someone to remember to look. In
-- practice nobody remembers, and the feedback loop the reporting was built for
-- quietly does not close.
--
-- Two rhythms, because reports are not equally urgent. One mail a day for the
-- queue, and one the moment a single camera collects three independent reports
-- - one person is an opinion, three is evidence, and evidence about a camera
-- warning drivers wrongly should not wait for morning.

-- ---------------------------------------------------------------------------
-- The daily digest
-- ---------------------------------------------------------------------------

select cron.schedule(
  'zonexplo-report-digest',
  '0 7 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
           || '/functions/v1/report-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')
    ),
    body := jsonb_build_object('trigger', 'cron'),
    timeout_milliseconds := 60000
  );
  $$
);

-- ---------------------------------------------------------------------------
-- The escalation
-- ---------------------------------------------------------------------------

-- Fires on the threshold being *crossed*, not on every report after it.
-- Without the equality a busy camera would send a mail per report, which is
-- the spam this design exists to avoid - and the mail would be filtered inside
-- a week, taking the urgent ones with it.
create or replace function public.notify_corroborated_report()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net, vault
as $$
declare
  v_count integer;
  v_url text;
  v_key text;
begin
  if new.camera_id is null then
    return new;
  end if;

  select count(*) into v_count
    from public.pending_reports
   where camera_id = new.camera_id
     and status = 'pending';

  if v_count <> 3 then
    return new;
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';

  -- A missing secret must not fail the driver's report. The report is the
  -- thing that matters; the mail is a convenience on top of it, and the daily
  -- digest will carry it regardless.
  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url := v_url || '/functions/v1/report-digest?urgent=' || new.camera_id,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body := jsonb_build_object('trigger', 'corroboration'),
    timeout_milliseconds := 60000
  );

  return new;
end;
$$;

create trigger pending_reports_corroboration
  after insert on public.pending_reports
  for each row
  execute function public.notify_corroborated_report();

comment on function public.notify_corroborated_report() is
  'Mails a human the moment a camera collects a third pending report. Fires on '
  'the threshold being crossed rather than on every later report, and never '
  'fails the insert - a driver''s report must not depend on the mail working.';
