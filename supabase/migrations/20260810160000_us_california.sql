-- California, so the thing can be tested without leaving the desk.
--
-- The iOS Simulator's default location is Apple's own campus, and every
-- simulated drive Apple ships starts in the Bay Area. Until now that meant the
-- one place a developer can actually exercise the app was the one place with no
-- data in it: the map came up, the card said "watching the road", and nothing
-- ever happened - which is indistinguishable from every real bug this app can
-- have.
--
-- It is a state rather than the country for the same reason New York and
-- Massachusetts are: the United States cannot be harvested or downloaded whole.
-- California alone is around 400 tiles of speed limits.

insert into public.countries (code, name, enabled, sync_enabled, overpass_iso_code, parent_code)
values ('US-CA', 'California', true, false, 'US-CA', 'US')
on conflict (code) do update
   set name              = excluded.name,
       enabled           = excluded.enabled,
       overpass_iso_code = excluded.overpass_iso_code,
       parent_code       = excluded.parent_code;
