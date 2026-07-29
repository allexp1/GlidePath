-- GlidePath schema, part 1: extensions.
--
-- postgis  - spatial types and the distance/length maths the seed and sync
--            jobs use to turn OpenStreetMap geometry into zone lengths.
-- pg_cron  - the nightly schedule.
-- pg_net   - lets pg_cron make the HTTP call that invokes the Edge Function.
--
-- Supabase ships all three; on a local stack `supabase start` has them
-- available too. They live in the `extensions` schema by convention.

create schema if not exists extensions;

create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- gen_random_uuid() comes from pgcrypto on older servers and from core on
-- newer ones. Requesting it explicitly keeps the migration portable.
create extension if not exists pgcrypto with schema extensions;
