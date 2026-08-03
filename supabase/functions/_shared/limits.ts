/**
 * Harvesting posted speed limits for one country.
 *
 * Separate from `sync.ts` because it is a different kind of job, not because it
 * is a different kind of data. The camera sync is three Overpass queries and
 * finishes in a couple of minutes. This is a few hundred tiled queries against
 * the road network of an entire country, and on anything the size of Poland it
 * runs for the better part of an hour.
 *
 * That length is why this does not run on the nightly schedule. A Supabase Edge
 * Function is killed long before a national harvest finishes, so a scheduled
 * road-limit job would fail every night in exactly the way that looks like it
 * is working - partial data, no error, a country quietly half covered. It is a
 * seed-CLI job instead, run on demand from a machine with no wall clock on it,
 * which is the same pattern `make seed-country` already uses for loading a
 * country nobody has surveyed yet.
 *
 * Resumability is the other consequence. The caller supplies the set of tiles
 * already done and is told after each one, so a run interrupted at tile 214
 * restarts at tile 215 rather than at the border.
 */

import { boundingBoxTiles, lineStringWKT, tileKey } from './geo.ts'
import type { BoundingBox } from './geo.ts'
import { countryBoundsQuery, roadLimitQuery, runOverpassQuery } from './overpass.ts'
import type { OverpassOptions } from './overpass.ts'
import { translateRoadLimit } from './translate.ts'
import type { RoadLimitRow } from './translate.ts'
import type { DatabaseClient } from './sync.ts'

export interface RoadLimitSyncOptions {
  /** Fetch and translate, write nothing. */
  dryRun?: boolean
  overpass?: OverpassOptions
  log?: (message: string) => void

  /**
   * Tile size in degrees. A quarter degree is roughly 28 km north-south, which
   * on a densely mapped country is a few thousand ways - large enough that the
   * per-query overhead does not dominate, small enough that Overpass answers
   * before its timeout.
   */
  tileDegrees?: number

  /** Douglas-Peucker tolerance applied to every way, in metres. */
  toleranceMeters?: number

  /** Tile keys finished by an earlier run, which are skipped. */
  completedTiles?: Set<string>

  /** Called after each tile so the caller can persist a resume point. */
  onTileComplete?: (key: string, done: number, total: number) => Promise<void> | void

  /** Stop after this many tiles in this invocation. Unlimited when unset. */
  maxTiles?: number
}

export interface RoadLimitSyncReport {
  countryCode: string
  tilesTotal: number
  tilesFetched: number
  tilesSkipped: number
  tilesFailed: number
  /** Distinct ways written. */
  ways: number
  /** Total polyline points after simplification, which is what size tracks. */
  points: number
  /** True only when every tile in the country was fetched without error. */
  complete: boolean
  version: number | null
  warnings: string[]
}

/**
 * The country's bounding box, from the same admin relation the area filters use.
 *
 * Doubles as the probe that the ISO code resolves at all. Overpass answers 200
 * with an empty element list when an area lookup fails, so without this the
 * first sign of a bad code would be four hundred tiles all returning nothing and
 * a report cheerfully claiming the country has no speed limits.
 */
export async function fetchCountryBounds(
  isoCode: string,
  options: OverpassOptions = {}
): Promise<BoundingBox> {
  const response = await runOverpassQuery(countryBoundsQuery(isoCode), options)

  let box: BoundingBox | null = null
  for (const element of response.elements) {
    const bounds = element.bounds
    if (!bounds) continue
    box = box === null
      ? {
        minLat: bounds.minlat,
        minLon: bounds.minlon,
        maxLat: bounds.maxlat,
        maxLon: bounds.maxlon
      }
      : {
        // A country mapped as several admin relations, which happens where a
        // territory is listed separately. Union rather than first-wins.
        minLat: Math.min(box.minLat, bounds.minlat),
        minLon: Math.min(box.minLon, bounds.minlon),
        maxLat: Math.max(box.maxLat, bounds.maxlat),
        maxLon: Math.max(box.maxLon, bounds.maxlon)
      }
  }

  if (box === null) {
    throw new Error(
      `Overpass returned no boundary for ISO code "${isoCode}". Either the code is ` +
        'wrong or the area lookup failed; either way, harvesting tiles against it ' +
        'would produce an empty dataset that looks like a real one.'
    )
  }

  return box
}

export async function syncRoadLimits(
  client: DatabaseClient,
  countryCode: string,
  isoCode: string,
  options: RoadLimitSyncOptions = {}
): Promise<RoadLimitSyncReport> {
  const log = options.log ?? (() => {})
  const warnings: string[] = []
  const runStartedAt = new Date().toISOString()
  const completed = options.completedTiles ?? new Set<string>()

  log(`[${countryCode}] resolving the country boundary`)
  const bounds = await fetchCountryBounds(isoCode, options.overpass)
  const tiles = boundingBoxTiles(bounds, options.tileDegrees ?? 0.25)

  log(
    `[${countryCode}] ${tiles.length} tiles to cover ` +
      `${bounds.minLat.toFixed(2)},${bounds.minLon.toFixed(2)} to ` +
      `${bounds.maxLat.toFixed(2)},${bounds.maxLon.toFixed(2)}` +
      (completed.size > 0 ? `, ${completed.size} already done` : '')
  )

  // Ways cross tile boundaries and Overpass returns the whole way for any tile
  // it touches, so the same motorway comes back in a dozen tiles with identical
  // geometry. Upserting on osm_id makes that harmless but not free; skipping
  // the repeats is a large share of the writes on a motorway-heavy country.
  const seen = new Set<string>()

  let fetched = 0
  let skipped = 0
  let failed = 0
  let ways = 0
  let points = 0
  let stoppedEarly = false

  for (let index = 0; index < tiles.length; index++) {
    const tile = tiles[index]
    const key = tileKey(tile)

    if (completed.has(key)) {
      skipped++
      continue
    }

    if (options.maxTiles !== undefined && fetched >= options.maxTiles) {
      stoppedEarly = true
      break
    }

    let rows: RoadLimitRow[]
    try {
      const response = await runOverpassQuery(
        roadLimitQuery(isoCode, tile, 180),
        options.overpass
      )

      rows = []
      for (const element of response.elements) {
        const row = translateRoadLimit(element, countryCode, options.toleranceMeters ?? 8)
        if (!row) continue
        if (seen.has(row.osm_id)) continue
        seen.add(row.osm_id)
        rows.push(row)
      }
    } catch (error) {
      // One tile failing is a fact about Overpass on the day, not a reason to
      // throw away the other 399. It does mean the run is not complete, which
      // is what stops the missing ways being retired.
      failed++
      warnings.push(`tile ${key} failed: ${message(error)}`)
      log(`[${countryCode}] tile ${index + 1}/${tiles.length} failed: ${message(error)}`)
      continue
    }

    ways += rows.length
    points += rows.reduce((total, row) => total + row.path.length, 0)

    if (!options.dryRun && rows.length > 0) {
      await upsertRoadLimits(client, rows, runStartedAt)
    }

    fetched++
    if (rows.length > 0 || (index + 1) % 25 === 0) {
      log(
        `[${countryCode}] tile ${index + 1}/${tiles.length}: ` +
          `${rows.length} new ways (${ways} so far)`
      )
    }

    await options.onTileComplete?.(key, fetched + skipped, tiles.length)
  }

  const complete = !stoppedEarly && failed === 0 && fetched + skipped === tiles.length

  if (options.dryRun) {
    return {
      countryCode,
      tilesTotal: tiles.length,
      tilesFetched: fetched,
      tilesSkipped: skipped,
      tilesFailed: failed,
      ways,
      points,
      complete,
      version: null,
      warnings
    }
  }

  const { data, error } = await client.rpc('finish_road_limit_sync', {
    p_country_code: countryCode,
    p_run_started_at: runStartedAt,
    p_complete: complete,
    p_error: null
  })
  if (error) throw new Error(`finish_road_limit_sync failed: ${error.message}`)

  if (!complete) {
    warnings.push(
      `harvest incomplete (${fetched + skipped}/${tiles.length} tiles, ${failed} failed); ` +
        'ways that were not seen have been left alone rather than retired'
    )
  }

  return {
    countryCode,
    tilesTotal: tiles.length,
    tilesFetched: fetched,
    tilesSkipped: skipped,
    tilesFailed: failed,
    ways,
    points,
    complete,
    version: typeof data === 'number' ? data : null,
    warnings
  }
}

async function upsertRoadLimits(
  client: DatabaseClient,
  rows: RoadLimitRow[],
  seenAt: string
): Promise<void> {
  const payload = rows
    .map((row) => {
      const wkt = lineStringWKT(row.path)
      // translateRoadLimit already rejects anything under two points, so this
      // cannot fire; keeping it means a future change to that rule degrades to
      // a dropped row rather than a constraint violation mid-batch.
      if (!wkt) return null
      return {
        country_code: row.country_code,
        name: row.name,
        road_ref: row.road_ref,
        highway: row.highway,
        polyline: wkt,
        limit_kph: row.limit_kph,
        forward_limit_kph: row.forward_limit_kph,
        backward_limit_kph: row.backward_limit_kph,
        osm_id: row.osm_id,
        source: 'osm',
        verified: true,
        last_seen_at: seenAt
      }
    })
    .filter((row) => row !== null)

  // Smaller batches than the camera sync uses. A camera row is a point and a
  // handful of columns; one of these carries a whole polyline, and 500 of them
  // is a request large enough to be refused.
  for (let index = 0; index < payload.length; index += 200) {
    const batch = payload.slice(index, index + 200)
    const { error } = await client
      .from('road_limits')
      .upsert(batch, { onConflict: 'osm_id' })
      .select('id')
    if (error) throw new Error(`road limit upsert failed: ${error.message}`)
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export async function recordRoadLimitFailure(
  client: DatabaseClient,
  countryCode: string,
  error: unknown
): Promise<void> {
  await client.rpc('finish_road_limit_sync', {
    p_country_code: countryCode,
    p_run_started_at: new Date().toISOString(),
    p_complete: false,
    p_error: message(error).slice(0, 500)
  })
}
