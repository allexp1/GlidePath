/**
 * The nightly job. Invoked by pg_cron through pg_net at 03:17 UTC.
 *
 * The one piece of scheduled work the backend does. It has no opinion about
 * driving: it fetches OpenStreetMap, translates it, merges it by OSM id, and
 * bumps each country's dataset version so phones know to ask for a delta.
 *
 *   supabase functions deploy sync-cameras
 *
 * Run it by hand against a local stack with:
 *
 *   supabase functions serve sync-cameras
 *   curl -i -X POST http://localhost:54321/functions/v1/sync-cameras \
 *        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY"
 */

import { createClient } from 'npm:@supabase/supabase-js@2'
import { recordSyncFailure, syncCountry } from '../_shared/sync.ts'
import type { DatabaseClient, SyncReport } from '../_shared/sync.ts'

interface CountryRow {
  code: string
  name: string
  overpass_iso_code: string | null
}

/// How long the run gives itself before it stops starting new countries.
///
/// The platform's ceiling is 150 seconds, and a country has taken anywhere
/// from twenty seconds to more than all of it - so this is not a budget that
/// can be divided evenly. It is only the point past which starting another one
/// is a coin toss that costs the entire report when it loses.
const DEADLINE_MS = 110_000

Deno.serve(async (request: Request) => {
  const startedAt = Date.now()

  const url = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!url || !serviceRoleKey) {
    return json({ error: 'SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set' }, 500)
  }

  // The service role bypasses row level security, which is what lets this write
  // to tables no client can touch. It never leaves the function.
  const client = createClient(url, serviceRoleKey, {
    auth: { persistSession: false }
  })

  // Allow a single country to be re-run without waiting for the schedule, which
  // is what you want when one country failed and the rest were fine.
  let only: string | null = null
  let dryRun = false
  try {
    const body = await request.json()
    if (typeof body?.country === 'string') only = body.country.toUpperCase()
    dryRun = body?.dryRun === true
  } catch {
    // No body, or not JSON. Both mean "run everything", which is what cron sends.
  }

  // sync_enabled, not enabled. Every country is listed in the app; only a
  // handful should be pulled from Overpass nightly.
  //
  // Stalest first, and this ordering is load-bearing rather than tidy. An Edge
  // Function is killed at 150 seconds and a country costs the best part of a
  // minute, so a run covers two or three of them and no more. Without an order
  // the query returns the same countries in the same sequence every night, the
  // ones at the front are re-synced daily, and the ones past the ceiling are
  // never synced again - silently, because the run reports success for
  // everything it did reach.
  //
  // Observed exactly that: a full run got through Israel and Moldova and was
  // killed before Lithuania, which had last been synced ten days earlier.
  //
  // Ordering by last_synced_at makes the cut-off rotate. Whoever was skipped
  // last night is at the front tonight, so three countries are covered every
  // two nights instead of one country never being covered at all. nullsFirst
  // puts a country that has never been synced ahead of every country that has.
  const { data, error } = await client
    .from('countries')
    .select('code, name, overpass_iso_code')
    .eq('sync_enabled', true)
    .order('last_sync_attempt_at', { ascending: true, nullsFirst: true })

  if (error) {
    return json({ error: `could not list countries: ${error.message}` }, 500)
  }

  const countries = ((data ?? []) as CountryRow[]).filter(
    (country) => only === null || country.code === only
  )

  if (countries.length === 0) {
    return json(
      {
        error: only
          ? `country ${only} does not have sync_enabled set`
          : 'no countries have sync_enabled set'
      },
      404
    )
  }

  const reports: SyncReport[] = []
  const failures: { country: string; error: string }[] = []

  // Sequential on purpose. Overpass is a shared volunteer service and firing
  // parallel country-sized queries at it is how you get rate limited.
  const skipped: string[] = []

  for (const country of countries) {
    // Stop before the platform stops us.
    //
    // Being killed at 150 seconds throws away the report, so the run ends as a
    // 504 saying nothing about what it did - which is how three nights of zero
    // progress looked exactly like three nights of normal operation. Returning
    // under our own power means the response names what was covered and what
    // was not.
    if (Date.now() - startedAt > DEADLINE_MS) {
      skipped.push(country.code)
      continue
    }

    const iso = country.overpass_iso_code ?? country.code

    // Before the work, never after. A country killed mid-sync writes nothing,
    // so an attempt stamped afterwards would never be written at all - and the
    // country would be first in the queue again tomorrow, and the night after,
    // starving everything behind it. Stamped here it rotates like any other.
    if (!dryRun) {
      await client.from('countries')
        .update({ last_sync_attempt_at: new Date().toISOString() })
        .eq('code', country.code)
    }

    try {
      const report = await syncCountry(client as unknown as DatabaseClient, country.code, iso, {
        dryRun,
        log: (message) => console.log(message)
      })
      reports.push(report)
      console.log(
        `[${country.code}] done: ${report.cameras + report.zoneMarkers} cameras ` +
          `(${report.zoneMarkers} of them zone entry/exit), ${report.zones} zones, ` +
          `version ${report.datasetVersion}`
      )
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught)
      console.error(`[${country.code}] failed: ${message}`)
      failures.push({ country: country.code, error: message })

      // One country failing must not stop the others. Record it against the
      // country so the dashboard shows which dataset is going stale.
      if (!dryRun) {
        await recordSyncFailure(client as unknown as DatabaseClient, country.code, caught)
      }
    }
  }

  return json(
    {
      dryRun,
      durationMs: Date.now() - startedAt,
      synced: reports,
      failed: failures,
      // Named rather than silently dropped: "covered two of five" is a
      // different fact from "covered everything", and the difference is
      // invisible from a list of successes.
      skippedForTime: skipped
    },
    // Partial failure is still a failure worth alerting on, but only when
    // nothing succeeded is it a hard error.
    failures.length > 0 && reports.length === 0 ? 500 : 200
  )
})

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}
