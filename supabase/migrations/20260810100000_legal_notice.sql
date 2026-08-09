-- Where warning about cameras is restricted, and what to tell the driver.
--
-- The catalogue offers 243 countries and says nothing about the law in any of
-- them. Several are not like the others:
--
--   Germany      StVO §23(1c) prohibits *operating* a camera-warning device
--                while driving. Possessing the app is not the offence; having
--                it running is.
--   Austria      The devices themselves are prohibited.
--   Switzerland  Likewise, and enforced more energetically than most.
--   France       Exact camera positions may not be shown. Apps must display
--                broad "zones de danger" instead.
--
-- The posture chosen here is informed consent: name the specific law, make the
-- driver acknowledge it before the country downloads, and let them decide.
-- That is a real choice and not a dodge - the alternative, silently hiding
-- countries, decides for an adult in a jurisdiction we have not checked, and
-- would also hide the country from someone merely planning a trip.
--
-- Two things it does not do, and both are the app owner's to resolve rather
-- than this table's. It does not make the app legal to operate where it is not:
-- the driver is told and takes responsibility, which is the same footing every
-- navigation app with camera alerts stands on. And it does not implement
-- France's zones-de-danger requirement, which is a different display, not a
-- warning - so France carries a notice describing the requirement rather than
-- claiming compliance.
--
-- Held in the database rather than the binary so a legal change, or advice
-- someone actually pays for, does not need an App Store release.

create type public.legal_stance as enum (
  'unrestricted',
  -- Using a camera warner while driving is an offence here.
  'use_restricted',
  -- The device or app itself is prohibited.
  'prohibited',
  -- Legal, but exact positions may not be shown.
  'coarse_only'
);

alter table public.countries
  add column if not exists legal_stance public.legal_stance not null default 'unrestricted';

alter table public.countries
  add column if not exists legal_note text;

comment on column public.countries.legal_note is
  'Shown to the driver before this country downloads. Names the specific law '
  'rather than warning vaguely: "it may be illegal" is not something anyone '
  'can act on.';

update public.countries
   set legal_stance = 'use_restricted',
       legal_note = 'German law (StVO §23(1c)) prohibits operating a device that warns '
                 || 'about speed cameras while you are driving. Having the app is not the '
                 || 'offence; running it while driving is. Police may require it to be '
                 || 'switched off and can issue a fine.'
 where code = 'DE';

update public.countries
   set legal_stance = 'prohibited',
       legal_note = 'Austria prohibits devices that warn about speed cameras. Using this '
                 || 'app while driving in Austria is against the law and the device itself '
                 || 'may be confiscated.'
 where code = 'AT';

update public.countries
   set legal_stance = 'prohibited',
       legal_note = 'Switzerland prohibits speed camera warning devices and enforces this '
                 || 'strictly. Penalties are severe and equipment can be seized.'
 where code = 'CH';

update public.countries
   set legal_stance = 'coarse_only',
       legal_note = 'French law requires that apps show broad danger zones rather than exact '
                 || 'camera positions. Zonexplo shows exact positions, so it does not meet '
                 || 'that requirement.'
 where code = 'FR';

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
  c.parent_code,
  c.legal_stance,
  c.legal_note
from public.countries c
where c.enabled;
