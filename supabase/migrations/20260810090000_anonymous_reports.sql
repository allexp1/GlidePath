-- Let a driver report a wrong camera without an account.
--
-- `pending_reports` was written for a signed-in reporter: reporter_id is not
-- null, defaults to auth.uid(), and the only insert policy is `to
-- authenticated`. The app has no accounts and never will - that is a product
-- promise, not an unfinished feature - so as it stood the table could not
-- receive a single report from the app that exists.
--
-- The reason to fix it is what today's Overpass work showed. New York returned
-- 4,077 camera nodes of which 3,788 were licence-plate readers; the fix was a
-- translation rule, but nothing in the system would have *told* us, because the
-- only people who can see that a camera is wrong are the drivers passing it.
-- Data quality is the weakest part of this product and the feedback loop was
-- missing entirely.
--
-- The trade-off is real and worth naming: an anonymous write endpoint can be
-- spammed, and there is no rate limit here beyond what the platform provides.
-- It is acceptable only because nothing in this table is trusted. A report
-- changes no camera and reaches no phone; it sits at status 'pending' until a
-- human promotes it, exactly as a signed-in report does. The blast radius of
-- abuse is a queue somebody has to empty, not bad data in a driver's car.

alter table public.pending_reports
  alter column reporter_id drop not null;

alter table public.pending_reports
  alter column reporter_id drop default;

comment on column public.pending_reports.reporter_id is
  'The signed-in reporter, or null for an anonymous report from the app. Null '
  'is the normal case: the app has no accounts.';

-- Anonymous reports are insert-only and may not claim to be from anybody.
--
-- `reporter_id is null` in the with-check is the load-bearing part: without it
-- the anon role could file a report in a real user''s name, and the whole point
-- of the authenticated policy is that it cannot.
--
-- No select policy is added. Unreviewed reports stay invisible, which is what
-- stops the queue becoming a public feed of unverified camera locations - the
-- exact thing this app declines to be.
create policy "anyone may file an anonymous report"
  on public.pending_reports for insert
  to anon
  with check (
    reporter_id is null
    and status = 'pending'
    and reviewed_at is null
    and reviewed_by is null
  );
