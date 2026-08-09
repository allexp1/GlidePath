-- A subdivision belongs to a country, and the catalogue has to say so.
--
-- 20260809180000 added New York and Massachusetts as rows of their own, which
-- made them harvestable but also made them peers of Lithuania and Moldova: the
-- app sorts by name, so Massachusetts landed between them, and the search field
-- offered "245 countries". A state is not a country, and a list that says it is
-- is wrong in a way that undermines everything else the list claims.
--
-- The fix is a parent, not a naming convention. With it the app can show one
-- United States row that opens into its states, and can count countries without
-- counting states.
--
-- Nullable and self-referencing: almost every row is a country and has no
-- parent. `on delete cascade` because a subdivision without its country is
-- meaningless, and `on update cascade` to match the rest of the schema.

alter table public.countries
  add column if not exists parent_code text
    references public.countries (code) on update cascade on delete cascade;

comment on column public.countries.parent_code is
  'The country this row is a subdivision of, or null when the row is itself a '
  'country. Set for ISO 3166-2 rows such as US-NY.';

-- A subdivision's parent must be the country its own code names, or the tree
-- and the code disagree and one of them is lying to the app.
alter table public.countries
  drop constraint if exists countries_parent_matches_code;

alter table public.countries
  add constraint countries_parent_matches_code
  check (
    parent_code is null
    or (code like '%-%' and parent_code = split_part(code, '-', 1))
  );

update public.countries set parent_code = 'US' where code in ('US-NY', 'US-MA');

-- Now that the app can group them, the names no longer have to disambiguate
-- themselves. "New York" reads correctly inside a list titled United States,
-- and "New York (US)" reads like an apology.
update public.countries set name = 'New York'      where code = 'US-NY';
update public.countries set name = 'Massachusetts' where code = 'US-MA';

create index if not exists countries_parent_code_idx
  on public.countries (parent_code)
  where parent_code is not null;

create or replace view public.countries_public
with (security_invoker = true) as
select
  c.code,
  c.name,
  c.enabled,
  c.dataset_version,
  c.min_compatible_version,
  c.last_synced_at,
  c.updated_at,
  (select count(*) from public.cameras where country_code = c.code) as camera_count,
  (select count(*) from public.zones where country_code = c.code) as zone_count,
  c.road_limit_version,
  c.road_limit_count,
  c.road_limits_synced_at,
  -- Appended rather than placed beside `name` where it belongs: `create or
  -- replace view` may only add columns at the end, and dropping the view would
  -- take its grants and the policies that read through it with it.
  c.parent_code
from public.countries c
where c.enabled;

comment on view public.countries_public is
  'The download list. camera_count and zone_count let the app show a size '
  'estimate before a driver commits to a download on mobile data. parent_code '
  'is set on subdivisions, which the app nests under their country rather than '
  'listing alongside one.';
