-- Stop one slow country starving every other one.
--
-- The nightly run is ordered stalest-first so the cut-off rotates: an Edge
-- Function is killed at 150 seconds, a run covers two or three countries, and
-- whoever was skipped last night is at the front tonight. That is the right
-- design and it has one failure mode nobody thought about - a country that
-- cannot finish *at all* inside the ceiling.
--
-- Lithuania became one. It is stalest, so it goes first; it is killed before it
-- can write anything, so `last_synced_at` never moves; so it is stalest again
-- tomorrow. Three nights in a row it consumed the entire budget and nothing
-- behind it was ever reached, and every symptom pointed the wrong way: pg_cron
-- reported success (it had queued the request), the function returned 504
-- (which is normal - it is *meant* to be killed), and `last_sync_error` stayed
-- null because a killed process runs no error handler.
--
-- The fix is to order by when a country was last *tried* rather than when it
-- last *succeeded*. Attempted is stamped before the work starts, so it survives
-- the process being killed, and a country that cannot complete drops to the
-- back of the queue like any other. It is deliberately a second column rather
-- than a redefinition of the first: `last_synced_at` means "this data is known
-- good as of", and a failed attempt must never be allowed to say that.

alter table public.countries
  add column if not exists last_sync_attempt_at timestamptz;

comment on column public.countries.last_sync_attempt_at is
  'When a sync was last started for this country, successful or not. Stamped '
  'before the work begins so it survives the Edge Function being killed at its '
  '150s ceiling. The nightly run orders by this so a country that can never '
  'finish rotates to the back instead of blocking every country behind it.';

-- Seed from the last success so the first run after this migration does not
-- treat every country as never-attempted and shuffle the order arbitrarily.
update public.countries
   set last_sync_attempt_at = last_synced_at
 where last_sync_attempt_at is null;

create index if not exists countries_sync_attempt_idx
  on public.countries (last_sync_attempt_at nulls first)
  where sync_enabled;

notify pgrst, 'reload schema';

-- Four runs a day instead of one.
--
-- Not because the work grew, but because how long it takes is wildly variable:
-- measured on the same afternoon, one run covered three countries in two
-- minutes and the next spent 147 seconds on the smallest country in the
-- catalogue. Overpass is a shared volunteer service and what it gives a
-- datacentre IP is not what it gives a laptop.
--
-- With one attempt a night, a slow night covers nothing and the data is a day
-- staler with no way to tell. With four, a bad run costs six hours and the next
-- one resumes where it stopped, because the attempt clock above means it never
-- retries the same country first.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'zonexplo-nightly-sync'),
  schedule := '17 3,9,15,21 * * *'
);
