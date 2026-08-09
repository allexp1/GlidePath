-- New York and Massachusetts as their own catalogue entries.
--
-- Every other row in this table is a country, and for the United States that
-- unit does not work. The country has millions of ways carrying a maxspeed tag:
-- the harvest would run for weeks, and the result is not a download any phone
-- could accept. New York is 160 tiles and Massachusetts is 32, which are
-- ordinary numbers.
--
-- So the catalogue gains a second kind of row. `overpass_iso_code` already
-- existed to let the Overpass lookup differ from the key, but `code` was
-- checked against `^[A-Z]{2}$`, so the constraint has to widen to admit a
-- subdivision. It widens to exactly ISO 3166-2's shape and no further: a
-- two-letter country, a hyphen, then one to three alphanumerics. Dropping the
-- check altogether would let a typo become a permanent primary key.
--
-- The query builder changed too: a hyphen means ISO 3166-2, which
-- OpenStreetMap files under a different tag at a different admin level, and
-- asking for ISO3166-1="US-NY" matches nothing and comes back as an empty
-- result indistinguishable from a state with no cameras in it.

alter table public.countries
  drop constraint countries_code_is_iso;

alter table public.countries
  add constraint countries_code_is_iso
  check (code ~ '^[A-Z]{2}$' or code ~ '^[A-Z]{2}-[A-Z0-9]{1,3}$');
--
-- Deliberately not the whole of ISO 3166-2. Rows are added where somebody
-- intends to harvest them; 3,000 unharvested subdivisions would bury the 243
-- countries in the app's list and answer a question nobody asked.
--
-- The United States row itself stays, and stays unsurveyed. It reads as "nobody
-- has looked yet", which is true of the country as a whole and is the honest
-- thing for someone who searches for it to see.

insert into public.countries (code, name, enabled, sync_enabled, overpass_iso_code)
values
  ('US-NY', 'New York (US)',      true, false, 'US-NY'),
  ('US-MA', 'Massachusetts (US)', true, false, 'US-MA')
on conflict (code) do update
   set name              = excluded.name,
       enabled           = excluded.enabled,
       overpass_iso_code = excluded.overpass_iso_code;

-- The names carry "(US)" because the list is sorted by name and read without
-- context. "New York" alone in a column of countries invites the reading that
-- the app thinks New York is one.
