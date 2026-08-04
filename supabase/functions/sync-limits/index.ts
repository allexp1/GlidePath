/**
 * Harvesting a country's posted speed limits, one short chunk at a time.
 *
 * The camera sync (sync-cameras) finishes inside a single invocation. This one
 * cannot: a national road-limit harvest is a few hundred Overpass queries and
 * runs far longer than an Edge Function is allowed to live. So it does not try.
 * Each call does as much as fits in its budget, writes down which tiles it
 * finished, and returns `done: false`. Call it again and it carries on.
 *
 *   supabase functions deploy sync-limits
 *
 *   curl -X POST "$SUPABASE_URL/functions/v1/sync-limits" \
 *        -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
 *        -H "Content-Type: application/json" \
 *        -d '{"country":"MD"}'
 *
 * Keep calling until the response says `done: true`. The alternative to this
 * shape is the seed CLI (`make seed-limits CODE=MD`), which does the whole
 * country in one local process and needs Deno on the machine running it. Both
 * drive the same `syncRoadLimits`; they differ only in who holds the clock.
 *
 * Deliberately NOT on the nightly schedule. Cron would fire this once and get
 * one chunk, which looks like success and leaves the country part harvested
 * forever.
 */

import { createClient } from 'npm:@supabase/supabase-js@2'
import { recordRoadLimitFailure, syncRoadLimits } from '../_shared/limits.ts'
import type { DatabaseClient } from '../_shared/sync.ts'

/**
 * How long to spend fetching before stopping cleanly.
 *
 * Under the platform's own ceiling by enough to leave room for the tile in
 * flight when the budget runs out, because the deadline is only checked
 * between tiles and a slow Overpass answer can take 30 s on its own. Being
 * killed mid-request is survivable - the tile just is not recorded and the next
 * call refetches it - but it costs a whole tile of work, so it is worth
 * avoiding.
 */
const DEFAULT_BUDGET_MS = 100_000

/** A hard stop as well as a deadline, so one pathologically slow call cannot run away. */
const DEFAULT_MAX_TILES = 40

interface CountryRow {
  code: string
  name: string
  overpass_iso_code: string | null
  road_limits_run_started_at: string | null
}

Deno.serve(async (request: Request) => {
  const startedAt = Date.now()

  const url = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!url || !serviceRoleKey) {
    return json({ error: 'SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set' }, 500)
  }

  const client = createClient(url, serviceRoleKey, {
    auth: { persistSession: false }
  })

  let body: Record<string, unknown> = {}
  try {
    body = (await request.json()) ?? {}
  } catch {
    // No body. Unlike sync-cameras there is no sensible "run everything"
    // default here: harvesting every country at once would take days.
  }

  const country = typeof body.country === 'string' ? body.country.toUpperCase() : null
  if (!country) {
    return json({ error: 'a country code is required, e.g. {"country":"MD"}' }, 400)
  }

  const budgetMs = numberOr(body.budgetMs, DEFAULT_BUDGET_MS)
  const maxTiles = numberOr(body.maxTiles, DEFAULT_MAX_TILES)
  const dryRun = body.dryRun === true

  const { data: countryData, error: countryError } = await client
    .from('countries')
    .select('code, name, overpass_iso_code, road_limits_run_started_at')
    .eq('code', country)
    .maybeSingle()

  if (countryError) {
    return json({ error: `could not read country ${country}: ${countryError.message}` }, 500)
  }
  if (!countryData) {
    return json({ error: `no country with code ${country}` }, 404)
  }

  const row = countryData as CountryRow
  const iso = row.overpass_iso_code ?? row.code

  try {
    // `reset` throws away the resume point and starts the country over. Wanted
    // when the tolerance or tile size changed and the half-finished run was
    // built with the old ones.
    if (body.reset === true) {
      await client.from('road_limit_harvest').delete().eq('country_code', country)
      await client
        .from('countries')
        .update({ road_limits_run_started_at: null })
        .eq('code', country)
      row.road_limits_run_started_at = null
    }

    const completedTiles = await loadCompletedTiles(client, country)

    // A run start already on the country means an open harvest to continue. The
    // second half of the condition catches a stamp left behind by a run whose
    // tiles were cleared without clearing it, which would otherwise date the
    // resumed run to whenever that abandoned attempt began.
    let runStartedAt = row.road_limits_run_started_at
    if (runStartedAt === null || completedTiles.size === 0) {
      runStartedAt = new Date().toISOString()
      if (!dryRun) {
        const { error } = await client
          .from('countries')
          .update({ road_limits_run_started_at: runStartedAt })
          .eq('code', country)
        if (error) throw new Error(`could not stamp the run start: ${error.message}`)
      }
    }

    const deadline = startedAt + budgetMs

    const report = await syncRoadLimits(client as unknown as DatabaseClient, country, iso, {
      dryRun,
      completedTiles,
      maxTiles,
      runStartedAt,
      // This call finalises for itself, below, and only when the country is
      // genuinely covered.
      finalize: false,
      shouldStop: () => Date.now() >= deadline,
      onTileComplete: async (key) => {
        if (dryRun) return
        const { error } = await client
          .from('road_limit_harvest')
          .upsert([{ country_code: country, tile_key: key }], {
            onConflict: 'country_code,tile_key'
          })
          .select('tile_key')
        // Losing a tile record is not worth failing the chunk over: the tile
        // was fetched and written, and the worst case is the next call
        // refetching it. Saying so out loud beats silently redoing work.
        if (error) console.warn(`[${country}] could not record tile ${key}: ${error.message}`)
      },
      log: (message) => console.log(message)
    })

    const tilesDone = report.tilesFetched + report.tilesSkipped

    if (report.complete && !dryRun) {
      const { data, error } = await client.rpc('finish_road_limit_sync', {
        p_country_code: country,
        p_run_started_at: runStartedAt,
        p_complete: true,
        p_error: null
      })
      if (error) throw new Error(`finish_road_limit_sync failed: ${error.message}`)

      // Clear the resume point only after the run is closed out. In the other
      // order a failure in between would leave no tiles recorded and a country
      // that looks unharvested, and the whole thing would be redone.
      await client.from('road_limit_harvest').delete().eq('country_code', country)
      await client
        .from('countries')
        .update({ road_limits_run_started_at: null })
        .eq('code', country)

      return json(
        {
          country,
          done: true,
          dryRun,
          tilesTotal: report.tilesTotal,
          tilesDone,
          waysThisCall: report.ways,
          version: typeof data === 'number' ? data : null,
          durationMs: Date.now() - startedAt,
          warnings: report.warnings
        },
        200
      )
    }

    return json(
      {
        country,
        done: report.complete,
        dryRun,
        tilesTotal: report.tilesTotal,
        tilesDone,
        tilesRemaining: report.tilesTotal - tilesDone,
        tilesFailedThisCall: report.tilesFailed,
        waysThisCall: report.ways,
        durationMs: Date.now() - startedAt,
        // The caller's instruction, rather than a status they have to infer
        // from the numbers.
        next: report.complete
          ? null
          : `call again with {"country":"${country}"} to continue`,
        warnings: report.warnings
      },
      200
    )
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : String(caught)
    console.error(`[${country}] failed: ${message}`)

    // Recorded against the country so a harvest that keeps dying is visible
    // rather than just absent. The tiles already done are left alone: they are
    // still valid and the next call should resume from them.
    if (!dryRun) {
      await recordRoadLimitFailure(client as unknown as DatabaseClient, country, caught)
    }

    return json({ country, error: message, durationMs: Date.now() - startedAt }, 500)
  }
})

/**
 * Every tile already finished for this country.
 *
 * Paged because PostgREST caps a response at 1000 rows by default and a large
 * country runs to more tiles than that. Reading only the first page would
 * silently refetch everything past it, which looks like the harvest making no
 * progress.
 */
async function loadCompletedTiles(
  client: ReturnType<typeof createClient>,
  country: string
): Promise<Set<string>> {
  const tiles = new Set<string>()
  const pageSize = 1000

  for (let offset = 0; ; offset += pageSize) {
    const { data, error } = await client
      .from('road_limit_harvest')
      .select('tile_key')
      .eq('country_code', country)
      .range(offset, offset + pageSize - 1)

    if (error) throw new Error(`could not read harvest progress: ${error.message}`)

    const page = (data ?? []) as { tile_key: string }[]
    for (const entry of page) tiles.add(entry.tile_key)
    if (page.length < pageSize) break
  }

  return tiles
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : fallback
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  })
}
