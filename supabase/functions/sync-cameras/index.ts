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
  const { data, error } = await client
    .from('countries')
    .select('code, name, overpass_iso_code')
    .eq('sync_enabled', true)

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
  for (const country of countries) {
    const iso = country.overpass_iso_code ?? country.code
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
      failed: failures
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
