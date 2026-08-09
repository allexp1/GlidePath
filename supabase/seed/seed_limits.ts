#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read --allow-write
/**
 * Loads posted speed limits for one country into your Supabase project.
 *
 *   deno run -A seed_limits.ts LT
 *   deno run -A seed_limits.ts LT --dry-run
 *   deno run -A seed_limits.ts LT --restart      ignore the resume checkpoint
 *
 * Or from the repository root:
 *
 *   make seed-limits CODE=LT
 *
 * **This takes a long time.** It is a few hundred Overpass queries against the
 * road network of an entire country, and Overpass is a free service run by
 * volunteers that rate limits accordingly. Lithuania is on the order of half an
 * hour. Somewhere the size of France is an afternoon. Leave it running.
 *
 * It is interruptible. Every finished tile is written to a checkpoint file
 * beside this script, so ctrl-C and re-run picks up where it stopped rather
 * than starting again. The checkpoint is deleted once a run covers the whole
 * country.
 *
 * This is deliberately not part of `make seed` and deliberately not on the
 * nightly schedule. See the header of functions/_shared/limits.ts for why.
 */

import { createClient } from '@supabase/supabase-js'
import { load } from '@std/dotenv'
import { syncRoadLimits } from '../functions/_shared/limits.ts'
import type { DatabaseClient } from '../functions/_shared/sync.ts'

interface Checkpoint {
  countryCode: string
  tiles: string[]
}

async function main(): Promise<number> {
  const args = [...Deno.args]
  const dryRun = args.includes('--dry-run')
  const restart = args.includes('--restart')
  const requested = args.find((arg) => !arg.startsWith('--'))

  // Tile size, because the default does not scale to a large country.
  //
  // A tile costs roughly the same whatever is in it - the cost is Overpass
  // resolving the area filter, not the data coming back - so the run time is
  // essentially the tile count. At the 0.25 degree default Israel is 112 tiles
  // and finishes in an hour, while Finland is 2193 and would take a day. Half a
  // degree divides the count by four.
  //
  // It is not free: a tile too large to answer inside Overpass's timeout comes
  // back as a failure, and a run with failed tiles is reported incomplete so
  // that nothing is retired on the strength of it. Err small on dense country,
  // large on empty country.
  const tileArg = args.find((arg) => arg.startsWith('--tile='))
  const tileDegrees = tileArg ? Number(tileArg.slice('--tile='.length)) : undefined

  if (!requested || !/^[A-Za-z]{2}$/.test(requested)) {
    console.error(
      'Usage: seed_limits.ts <ISO 3166-1 alpha-2> [--tile=DEGREES] [--dry-run] [--restart]'
    )
    console.error('  e.g. seed_limits.ts LT')
    console.error('       seed_limits.ts FI --tile=0.5    (a quarter of the tiles)')
    return 2
  }

  if (tileArg && (!Number.isFinite(tileDegrees) || tileDegrees! <= 0)) {
    console.error(`--tile needs a positive number of degrees, got "${tileArg}"`)
    return 2
  }

  // The checkpoint records tile keys, which are derived from the tile size, so
  // resuming a run at a different size would skip tiles that were never
  // covered and report a country complete when it is not.
  if (tileArg && !restart && !dryRun) {
    console.log('Note: --tile changes the tile keys, so pass --restart if a')
    console.log('      checkpoint from a different tile size already exists.')
  }

  const code = requested.toUpperCase()

  await load({ envPath: '../.env', export: true })

  const url = Deno.env.get('SUPABASE_URL')?.trim()
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim()
  if (!url || !key) {
    console.error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required in supabase/.env.')
    return 1
  }

  const client = createClient(url, key, { auth: { persistSession: false } })

  const { data: country, error } = await client
    .from('countries')
    .select('code, name, overpass_iso_code')
    .eq('code', code)
    .maybeSingle()

  if (error) {
    console.error(`Could not look up ${code}: ${error.message}`)
    return 1
  }
  if (!country) {
    console.error(`${code} is not in the countries table. Try: supabase db push`)
    return 2
  }

  const iso = country.overpass_iso_code ?? country.code
  const checkpointPath = new URL(`./.limits-${code}.json`, import.meta.url)

  let completedTiles = new Set<string>()
  if (!restart && !dryRun) {
    completedTiles = await readCheckpoint(checkpointPath, code)
    if (completedTiles.size > 0) {
      console.log(`Resuming: ${completedTiles.size} tiles already done.`)
      console.log('Pass --restart to ignore the checkpoint and cover the country again.')
    }
  }

  console.log(`Harvesting speed limits for ${country.name} (${code})${dryRun ? ' - dry run' : ''}`)
  console.log('This runs for tens of minutes. Ctrl-C is safe; re-running resumes.')
  console.log('')

  const done = new Set(completedTiles)

  const report = await syncRoadLimits(client as unknown as DatabaseClient, code, iso, {
    dryRun,
    tileDegrees,
    completedTiles,
    log: (message) => console.log(`  ${message}`),
    onTileComplete: async (tile) => {
      if (dryRun) return
      done.add(tile)
      await writeCheckpoint(checkpointPath, { countryCode: code, tiles: [...done] })
    }
  })

  console.log('')
  console.log(`  tiles                ${report.tilesFetched} fetched, ` +
    `${report.tilesSkipped} skipped, ${report.tilesFailed} failed, of ${report.tilesTotal}`)
  console.log(`  road segments        ${report.ways}`)
  console.log(`  geometry points      ${report.points}`)
  console.log(`  approx download      ${estimateSize(report.points, report.ways)}`)
  console.log(`  limit version        ${report.version ?? '(unchanged, dry run)'}`)
  console.log(`  covered the country  ${report.complete ? 'yes' : 'no'}`)

  if (report.warnings.length > 0) {
    console.log('')
    console.log(`  ${report.warnings.length} warning(s):`)
    for (const warning of report.warnings.slice(0, 20)) {
      console.log(`    - ${warning}`)
    }
    if (report.warnings.length > 20) {
      console.log(`    ... and ${report.warnings.length - 20} more`)
    }
  }

  if (report.complete && !dryRun) {
    await Deno.remove(checkpointPath).catch(() => {})
    console.log('')
    console.log(`  Speed limits for ${country.name} are now downloadable in the app,`)
    console.log('  as a separate opt-in from the camera data.')
  } else if (!dryRun) {
    console.log('')
    console.log('  Run the same command again to carry on from where this stopped.')
  }

  return report.ways === 0 && !report.complete ? 1 : 0
}

/**
 * A rough download size for what was harvested.
 *
 * Honest rather than flattering: this dataset is the largest thing the app ever
 * asks a driver to download, and a figure that turns out to be three times
 * larger on the day is worse than no figure. Each point is two doubles rendered
 * as JSON text plus separators, which measures at around 24 bytes; each way
 * carries roughly 120 bytes of columns around its geometry.
 */
function estimateSize(points: number, ways: number): string {
  const bytes = points * 24 + ways * 120
  if (bytes < 1_000_000) return `${Math.round(bytes / 1000)} kB`
  return `${(bytes / 1_000_000).toFixed(1)} MB`
}

async function readCheckpoint(path: URL, code: string): Promise<Set<string>> {
  try {
    const parsed = JSON.parse(await Deno.readTextFile(path)) as Checkpoint
    // A checkpoint from a different country would silently skip tiles that were
    // never fetched, which is the one failure mode that produces a dataset with
    // holes in it and no sign of them.
    if (parsed.countryCode !== code || !Array.isArray(parsed.tiles)) return new Set()
    return new Set(parsed.tiles)
  } catch {
    return new Set()
  }
}

async function writeCheckpoint(path: URL, checkpoint: Checkpoint): Promise<void> {
  await Deno.writeTextFile(path, JSON.stringify(checkpoint))
}

Deno.exit(await main())
