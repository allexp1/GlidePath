/**
 * One country's worth of syncing, from Overpass to the database.
 *
 * Shared verbatim between the nightly Edge Function and the local seed CLI, so
 * a developer running `make seed` and the scheduled job at 03:17 do exactly the
 * same thing. The only difference is who calls it.
 */

import { lineStringWKT, pointWKT, polylineLength, projectOntoLine } from './geo.ts'
import type { LatLon } from './geo.ts'
import {
  averageSpeedZoneQuery,
  pointCameraQuery,
  restStopQuery,
  runOverpassQuery
} from './overpass.ts'
import type { OverpassOptions } from './overpass.ts'
import {
  translateAverageSpeedZone,
  translatePointCamera,
  translateRestStop,
  zoneRejectionReason
} from './translate.ts'
import type { CameraRow, RestStopRow, ZoneRow } from './translate.ts'

interface QueryError {
  message: string
}

/**
 * The slice of supabase-js this module needs, so a test can pass a fake.
 *
 * PromiseLike rather than Promise: supabase-js query builders are thenable but
 * are not Promise instances, and typing them as Promise would reject the real
 * client.
 */
export interface DatabaseClient {
  from(table: string): {
    upsert(rows: unknown[], options?: { onConflict?: string }): {
      select(columns?: string): PromiseLike<{ data: unknown[] | null; error: QueryError | null }>
    }
    delete(): { in(column: string, values: unknown[]): PromiseLike<{ error: QueryError | null }> }
    insert(rows: unknown[]): PromiseLike<{ error: QueryError | null }>
  }
  rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: unknown; error: QueryError | null }>
}

export interface SyncOptions {
  /** Log without writing anything. */
  dryRun?: boolean
  /** Extra zones from a hand-maintained file, e.g. Israel's new sections. */
  manualZones?: ManualZone[]
  overpass?: OverpassOptions
  log?: (message: string) => void
}

/**
 * A section entered by hand because OpenStreetMap does not have it yet.
 * See docs/ISRAEL_ZONES.md for the file format.
 */
export interface ManualZone {
  id: string
  name?: string
  road_ref?: string
  speed_limit_kph: number
  minimum_speed_kph?: number | null
  direction_degrees?: number | null
  /** Road-geometry distance in metres. Omit to have it measured from `path`. */
  distance_meters?: number
  path: [number, number][]
}

export interface SyncReport {
  countryCode: string
  cameras: number
  zones: number
  restStops: number
  manualZones: number
  /**
   * Entry and exit rows generated from the zones, two per zone.
   *
   * Reported separately because they are cameras as far as the app is concerned
   * and `cameras` counts only the standalone nodes Overpass returned. Somewhere
   * like Lithuania, where enforcement is almost entirely section control and the
   * cameras exist only as relation members, `cameras` is 0 while this is in the
   * hundreds - and a summary claiming zero cameras there is simply false.
   */
  zoneMarkers: number
  datasetVersion: number | null
  warnings: string[]
}

/** How far off a road a rest stop may be and still count as being on it. */
const REST_STOP_CORRIDOR_METERS = 250

export async function syncCountry(
  client: DatabaseClient,
  countryCode: string,
  isoCode: string,
  options: SyncOptions = {}
): Promise<SyncReport> {
  const log = options.log ?? (() => {})
  const warnings: string[] = []
  const runStartedAt = new Date().toISOString()

  // ---- Fetch -------------------------------------------------------------

  log(`[${countryCode}] querying Overpass for point cameras`)
  const cameraResponse = await runOverpassQuery(pointCameraQuery(isoCode), options.overpass)

  log(`[${countryCode}] querying Overpass for average-speed sections`)
  let zoneResponse = await runOverpassQuery(averageSpeedZoneQuery(isoCode), options.overpass)

  // Ask twice before believing a country has no average-speed sections.
  //
  // The camera query above proves the area resolved. If it came back with
  // thousands of nodes and this one came back with literally nothing, the two
  // statements are hard to hold together: the section query is not more
  // fragile, it is just larger, and a loaded Overpass answers a large query
  // with an empty 200 rather than an error.
  //
  // Belgium is why this exists. It has 158 sections mapped as
  // `Trajectcontrole`, and a sweep harvested it as zero zones with no rejection
  // reasons at all - the signature of an empty response rather than of
  // relations that failed validation. Minutes later the same query returned all
  // 158.
  //
  // Countries with genuinely no sections - Finland, Sweden - pay one extra
  // query for this and still report zero, which is the correct answer for them.
  if (zoneResponse.elements.length === 0 && cameraResponse.elements.length > 50) {
    log(`[${countryCode}] no sections came back; asking again before believing it`)
    await new Promise((resolve) => setTimeout(resolve, 5000))
    zoneResponse = await runOverpassQuery(averageSpeedZoneQuery(isoCode), options.overpass)

    if (zoneResponse.elements.length > 0) {
      warnings.push(
        'the first section query returned nothing and the second returned ' +
          `${zoneResponse.elements.length} elements; Overpass was answering empty rather ` +
          'than this country having no average-speed sections'
      )
    }
  }

  // Two queries, one area filter. The section query finding the country proves
  // the area resolved, so a completely empty camera response is suspect: Overpass
  // answers 200 with no elements when an area lookup fails, and Lithuania gave 0
  // then 578 camera nodes minutes apart for the same query.
  //
  // Suspect, not fatal. A country really can have no standalone camera nodes -
  // that was the working theory for Lithuania until the 578 turned up - and
  // failing the country outright would be its own kind of wrong. The damage an
  // empty harvest could do is blocked in finish_country_sync instead, which can
  // see how much of the country it is about to write off. This is here so the run
  // says out loud that it does not trust what it got.
  if (cameraResponse.elements.length === 0 && zoneResponse.elements.length > 0) {
    warnings.push(
      `the camera query returned nothing while the section query returned ` +
        `${zoneResponse.elements.length} elements for the same area, which usually means ` +
        'the camera query failed rather than that this country has no cameras'
    )
  }

  // ---- Translate ---------------------------------------------------------

  const cameras: CameraRow[] = []
  const seenCameraIds = new Set<string>()
  for (const element of cameraResponse.elements) {
    const row = translatePointCamera(element, countryCode)
    if (!row) continue
    // The three sub-queries overlap, so the same node can arrive twice.
    if (seenCameraIds.has(row.osm_id)) continue
    seenCameraIds.add(row.osm_id)
    cameras.push(row)
  }

  // The query returns the relations with geometry and their member ways with
  // tags. The ways are only here for their maxspeed, which is where the limit
  // lives when the relation does not carry one of its own.
  const wayTags = new Map<number, Record<string, string>>()
  for (const element of zoneResponse.elements) {
    if (element.type === 'way' && element.tags) wayTags.set(element.id, element.tags)
  }

  const zones: ZoneRow[] = []
  for (const element of zoneResponse.elements) {
    if (element.type !== 'relation') continue

    const row = translateAverageSpeedZone(element, countryCode, wayTags)
    if (row) {
      zones.push(row)
    } else {
      // Say which of the two it is. "no usable geometry or limit" covers both
      // and so points at neither, which cost a round trip to a real dataset to
      // work out once already.
      warnings.push(
        `relation/${element.id} skipped: ${zoneRejectionReason(element, wayTags) ?? 'unknown'}`
      )
    }
  }

  const manual = options.manualZones ?? []
  const manualRows = manual.map((zone) => manualToZoneRow(zone, countryCode))

  // Rest stops are only worth fetching where there is a zone to put them in.
  let restStops: RestStopRow[] = []
  if (zones.length + manualRows.length > 0) {
    log(`[${countryCode}] querying Overpass for rest stops`)
    try {
      const stopResponse = await runOverpassQuery(restStopQuery(isoCode), options.overpass)
      const seenStops = new Set<string>()
      for (const element of stopResponse.elements) {
        const row = translateRestStop(element, countryCode)
        if (!row || seenStops.has(row.osm_id)) continue
        seenStops.add(row.osm_id)
        restStops.push(row)
      }
    } catch (error) {
      // Rest stops are a nicety. Losing them costs the impossible tier its
      // "pull in here" advice; losing the cameras would cost the whole product.
      warnings.push(`rest stops unavailable: ${message(error)}`)
      restStops = []
    }
  }

  log(
    `[${countryCode}] translated ${cameras.length} cameras, ${zones.length} zones ` +
      `(+${manualRows.length} manual), ${restStops.length} rest stops`
  )

  if (options.dryRun) {
    return {
      countryCode,
      cameras: cameras.length,
      zones: zones.length,
      restStops: restStops.length,
      manualZones: manualRows.length,
      // Two per zone, which is what the write step would create.
      zoneMarkers: (zones.length + manualRows.length) * 2,
      datasetVersion: null,
      warnings
    }
  }

  // ---- Write -------------------------------------------------------------

  await upsertCameras(client, cameras, runStartedAt)

  const allZones = [...zones, ...manualRows]
  const zoneIdsByOsmId = await upsertZones(client, allZones, runStartedAt)
  await writeZoneGeometry(client, allZones, zoneIdsByOsmId)
  const zoneMarkers = await writeZoneMarkerCameras(client, allZones, zoneIdsByOsmId, runStartedAt)
  await assignRestStops(client, allZones, zoneIdsByOsmId, restStops, runStartedAt)

  const { data, error } = await client.rpc('finish_country_sync', {
    p_country_code: countryCode,
    p_run_started_at: runStartedAt,
    p_error: null
  })
  if (error) throw new Error(`finish_country_sync failed: ${error.message}`)

  return {
    countryCode,
    cameras: cameras.length,
    zones: zones.length,
    restStops: restStops.length,
    manualZones: manualRows.length,
    zoneMarkers,
    datasetVersion: typeof data === 'number' ? data : null,
    warnings
  }
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

async function upsertCameras(
  client: DatabaseClient,
  cameras: CameraRow[],
  seenAt: string
): Promise<void> {
  if (cameras.length === 0) return

  const payload = cameras.map((camera) => ({
    country_code: camera.country_code,
    location: pointWKT({ lat: camera.latitude, lon: camera.longitude }),
    type: camera.type,
    direction_degrees: camera.direction_degrees,
    speed_limit_kph: camera.speed_limit_kph,
    osm_id: camera.osm_id,
    source: 'osm',
    verified: true,
    last_seen_at: seenAt
  }))

  await chunked(payload, 500, async (batch) => {
    const { error } = await client.from('cameras').upsert(batch, { onConflict: 'osm_id' }).select('id')
    if (error) throw new Error(`camera upsert failed: ${error.message}`)
  })
}

async function upsertZones(
  client: DatabaseClient,
  zones: ZoneRow[],
  seenAt: string
): Promise<Map<string, string>> {
  const ids = new Map<string, string>()
  if (zones.length === 0) return ids

  const payload = zones.map((zone) => ({
    country_code: zone.country_code,
    name: zone.name,
    road_ref: zone.road_ref,
    entry_point: pointWKT(zone.entry),
    exit_point: pointWKT(zone.exit),
    distance_meters: zone.distance_meters,
    speed_limit_kph: zone.speed_limit_kph,
    minimum_speed_kph: zone.minimum_speed_kph,
    direction_degrees: zone.direction_degrees,
    osm_id: zone.osm_id,
    source: zone.osm_id.startsWith('manual/') ? 'manual' : 'osm',
    // Measured geometry is trusted; a zone assembled from partial data is not,
    // and the app treats unverified zones as advisory only.
    verified: zone.measured,
    last_seen_at: seenAt
  }))

  await chunked(payload, 200, async (batch) => {
    const { data, error } = await client
      .from('zones')
      .upsert(batch, { onConflict: 'osm_id' })
      .select('id, osm_id')
    if (error) throw new Error(`zone upsert failed: ${error.message}`)

    for (const row of (data ?? []) as { id: string; osm_id: string }[]) {
      ids.set(row.osm_id, row.id)
    }
  })

  return ids
}

async function writeZoneGeometry(
  client: DatabaseClient,
  zones: ZoneRow[],
  ids: Map<string, string>
): Promise<void> {
  const withPaths = zones.filter((zone) => zone.path.length >= 2 && ids.has(zone.osm_id))
  if (withPaths.length === 0) return

  const zoneIds = withPaths.map((zone) => ids.get(zone.osm_id) as string)

  // Replace rather than merge. A re-traced road changes its node count, so
  // there is no sensible way to update segments in place.
  const { error: deleteError } = await client.from('road_segments').delete().in('zone_id', zoneIds)
  if (deleteError) throw new Error(`road segment cleanup failed: ${deleteError.message}`)

  const rows = withPaths
    .map((zone) => {
      const wkt = lineStringWKT(zone.path)
      if (!wkt) return null
      return { zone_id: ids.get(zone.osm_id), sequence: 0, polyline: wkt }
    })
    .filter((row): row is { zone_id: string; sequence: number; polyline: string } => row !== null)

  await chunked(rows, 100, async (batch) => {
    const { error } = await client.from('road_segments').insert(batch)
    if (error) throw new Error(`road segment insert failed: ${error.message}`)
  })
}

/**
 * Every zone gets an entry and an exit camera row.
 *
 * They exist so the map screen can draw the section boundaries and so the
 * geofence manager has something to attach a region to. The synthetic osm_id
 * keeps them idempotent across runs.
 */
async function writeZoneMarkerCameras(
  client: DatabaseClient,
  zones: ZoneRow[],
  ids: Map<string, string>,
  seenAt: string
): Promise<number> {
  const rows = zones.flatMap((zone) => {
    const zoneId = ids.get(zone.osm_id)
    if (!zoneId) return []

    const base = {
      country_code: zone.country_code,
      speed_limit_kph: zone.speed_limit_kph,
      direction_degrees: zone.direction_degrees,
      zone_id: zoneId,
      source: zone.osm_id.startsWith('manual/') ? 'manual' : 'osm',
      verified: true,
      last_seen_at: seenAt
    }

    return [
      { ...base, osm_id: `${zone.osm_id}#entry`, type: 'zone_entry', location: pointWKT(zone.entry) },
      { ...base, osm_id: `${zone.osm_id}#exit`, type: 'zone_exit', location: pointWKT(zone.exit) }
    ]
  })

  await chunked(rows, 500, async (batch) => {
    const { error } = await client.from('cameras').upsert(batch, { onConflict: 'osm_id' }).select('id')
    if (error) throw new Error(`zone marker upsert failed: ${error.message}`)
  })

  return rows.length
}

/**
 * Ties rest stops to the zones they sit inside.
 *
 * A stop counts as being in a zone when it is within a corridor of the road and
 * between the two cameras. Distance along the road is computed here rather than
 * on the phone, which would otherwise have to project every stop against every
 * zone on every fix.
 */
async function assignRestStops(
  client: DatabaseClient,
  zones: ZoneRow[],
  ids: Map<string, string>,
  stops: RestStopRow[],
  seenAt: string
): Promise<void> {
  if (stops.length === 0) return

  interface Assignment {
    zoneId: string
    along: number
    offset: number
  }

  const assignments = new Map<string, Assignment>()

  for (const zone of zones) {
    const zoneId = ids.get(zone.osm_id)
    if (!zoneId || zone.path.length < 2) continue

    for (const stop of stops) {
      const projection = projectOntoLine(zone.path, { lat: stop.latitude, lon: stop.longitude })
      if (!projection) continue
      if (projection.offset > REST_STOP_CORRIDOR_METERS) continue
      // Right at either camera is no use as somewhere to wait.
      if (projection.along < 100 || projection.along > zone.distance_meters - 100) continue

      // Zones can overlap where carriageways run alongside each other. The
      // closest road wins, which is the one the stop actually serves.
      const existing = assignments.get(stop.osm_id)
      if (existing && existing.offset <= projection.offset) continue
      assignments.set(stop.osm_id, { zoneId, along: projection.along, offset: projection.offset })
    }
  }

  const payload = stops.map((stop) => {
    const assignment = assignments.get(stop.osm_id)
    return {
      country_code: stop.country_code,
      name: stop.name,
      location: pointWKT({ lat: stop.latitude, lon: stop.longitude }),
      kind: stop.kind,
      zone_id: assignment?.zoneId ?? null,
      distance_along_meters: assignment?.along ?? null,
      osm_id: stop.osm_id,
      source: 'osm',
      last_seen_at: seenAt
    }
  })

  await chunked(payload, 500, async (batch) => {
    const { error } = await client.from('rest_stops').upsert(batch, { onConflict: 'osm_id' }).select('id')
    if (error) throw new Error(`rest stop upsert failed: ${error.message}`)
  })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Validates a hand-entered section and turns it into the same shape an OSM
 * relation produces.
 *
 * Throws rather than skipping. The manual file is the only source for Israel's
 * new sections, it is small enough to read, and a silently dropped zone would
 * mean the app quietly failing to coach on a road that is actually enforced.
 */
function manualToZoneRow(zone: ManualZone, countryCode: string): ZoneRow {
  if (!Array.isArray(zone.path) || zone.path.length < 2) {
    throw new Error(`manual zone "${zone.id}" needs a path of at least two points`)
  }
  if (!(zone.speed_limit_kph > 0)) {
    throw new Error(`manual zone "${zone.id}" has no usable speed_limit_kph`)
  }

  const path: LatLon[] = zone.path.map(([lat, lon]) => ({ lat, lon }))
  const measuredLength = polylineLength(path)
  const distance = zone.distance_meters ?? measuredLength

  if (!(distance > 0)) {
    throw new Error(`manual zone "${zone.id}" has no usable distance`)
  }

  // A declared distance wildly different from the traced one usually means the
  // path was copied from the wrong carriageway.
  if (zone.distance_meters && measuredLength > 0) {
    const drift = Math.abs(zone.distance_meters - measuredLength) / measuredLength
    if (drift > 0.25) {
      throw new Error(
        `manual zone "${zone.id}" declares ${zone.distance_meters} m but its path measures ` +
          `${Math.round(measuredLength)} m`
      )
    }
  }

  return {
    osm_id: `manual/${zone.id}`,
    country_code: countryCode,
    name: zone.name ?? null,
    road_ref: zone.road_ref ?? null,
    entry: path[0],
    exit: path[path.length - 1],
    distance_meters: Math.round(distance),
    speed_limit_kph: zone.speed_limit_kph,
    minimum_speed_kph: zone.minimum_speed_kph ?? null,
    direction_degrees: zone.direction_degrees ?? null,
    path,
    // Hand-entered sections are only as good as the file. Marking them measured
    // when a path was supplied lets the app treat them as real; without two
    // points there is no geometry to trust.
    measured: path.length >= 2
  }
}

async function chunked<T>(
  rows: T[],
  size: number,
  handler: (batch: T[]) => Promise<void>
): Promise<void> {
  for (let index = 0; index < rows.length; index += size) {
    await handler(rows.slice(index, index + size))
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export async function recordSyncFailure(
  client: DatabaseClient,
  countryCode: string,
  error: unknown
): Promise<void> {
  await client.rpc('finish_country_sync', {
    p_country_code: countryCode,
    p_run_started_at: new Date().toISOString(),
    p_error: message(error).slice(0, 500)
  })
}
