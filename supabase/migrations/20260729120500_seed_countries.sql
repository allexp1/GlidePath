-- The two launch countries.
--
-- Israel: 250 new average-speed cameras across 125 sections, enforcement from
-- Q3 2026. OpenStreetMap will not carry these until well after they go live, so
-- the sections are seeded by hand from police announcements. See
-- supabase/seed/israel_zones.json and docs/ISRAEL_ZONES.md.
--
-- Moldova: mostly mobile traps and point cameras, thin rural coverage. Offline
-- mode carries the weight here.

insert into public.countries (code, name, enabled, overpass_iso_code)
values
  ('IL', 'Israel', true, 'IL'),
  ('MD', 'Moldova', true, 'MD')
on conflict (code) do update
  set name = excluded.name,
      enabled = excluded.enabled,
      overpass_iso_code = excluded.overpass_iso_code;
