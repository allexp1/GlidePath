-- Lithuania.
--
-- Worth having beyond the original two launch countries: Lithuania has run
-- average-speed enforcement ("vidutinio greicio matuokliai") on its main
-- highways for years, and unlike Israel's brand new sections those are old
-- enough to be properly mapped in OpenStreetMap as type=enforcement relations.
--
-- That makes it the first country likely to exercise the zone path with real
-- data rather than hand-seeded geometry, which is the part of the app that has
-- never seen a live row.

insert into public.countries (code, name, enabled, overpass_iso_code)
values ('LT', 'Lithuania', true, 'LT')
on conflict (code) do update
  set name = excluded.name,
      enabled = excluded.enabled,
      overpass_iso_code = excluded.overpass_iso_code;
