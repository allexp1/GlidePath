/**
 * Turning OpenStreetMap tags into GlidePath rows.
 *
 * OSM tagging is a convention, not a schema. The same camera can be a
 * `highway=speed_camera` node, a `man_made=surveillance` node, a `device`
 * member of an enforcement relation, or all three. This module is where every
 * one of those shapes becomes the same handful of columns, and where the
 * judgement calls are written down.
 *
 * The bias throughout is towards keeping a row rather than dropping it, and
 * towards warning rather than staying silent. A driver warned about a camera
 * that has been removed is mildly annoyed. A driver not warned about one that
 * exists gets a fine.
 */

import { bearingDegrees, distanceAlong, polylineLength, stitchWays } from './geo.ts'
import type { LatLon } from './geo.ts'
import type { OverpassElement, OverpassMember } from './overpass.ts'

export type CameraType =
  | 'fixed'
  | 'red_light'
  | 'combined'
  | 'seatbelt_phone'
  | 'bus_lane'
  | 'mobile_hotspot'
  | 'zone_entry'
  | 'zone_exit'

export interface CameraRow {
  osm_id: string
  country_code: string
  latitude: number
  longitude: number
  type: CameraType
  direction_degrees: number | null
  speed_limit_kph: number | null
}

export interface ZoneRow {
  osm_id: string
  country_code: string
  name: string | null
  road_ref: string | null
  entry: LatLon
  exit: LatLon
  distance_meters: number
  speed_limit_kph: number
  minimum_speed_kph: number | null
  direction_degrees: number | null
  path: LatLon[]
  /** False when the geometry had to be guessed rather than measured. */
  measured: boolean
}

export interface RestStopRow {
  osm_id: string
  country_code: string
  name: string | null
  latitude: number
  longitude: number
  kind: 'rest_area' | 'fuel_station' | 'services' | 'parking' | 'viewpoint'
}

// ---------------------------------------------------------------------------
// Tag parsing
// ---------------------------------------------------------------------------

/**
 * `maxspeed` is free text. Most of it is a bare number in km/h, some carries an
 * explicit unit, and a fair amount is a country default like "IL:urban" that
 * carries no number at all.
 *
 * Anything not confidently a number comes back null, which means the camera is
 * stored without a limit. The app then warns about the camera without claiming
 * to know what it enforces, which is honest.
 */
export function parseMaxspeed(raw?: string): number | null {
  if (!raw) return null

  const trimmed = raw.trim().toLowerCase()
  const mph = trimmed.match(/^(\d+(?:\.\d+)?)\s*mph$/)
  if (mph) {
    const value = Number.parseFloat(mph[1]) * 1.609344
    return sanityCheckSpeed(Math.round(value))
  }

  const kph = trimmed.match(/^(\d+(?:\.\d+)?)(?:\s*km\/?h)?$/)
  if (kph) return sanityCheckSpeed(Number.parseFloat(kph[1]))

  return null
}

function sanityCheckSpeed(value: number): number | null {
  if (!Number.isFinite(value) || value <= 0 || value > 200) return null
  return value
}

const CARDINALS: Record<string, number> = {
  n: 0, north: 0,
  ne: 45, northeast: 45,
  e: 90, east: 90,
  se: 135, southeast: 135,
  s: 180, south: 180,
  sw: 225, southwest: 225,
  w: 270, west: 270,
  nw: 315, northwest: 315
}

/**
 * `direction` is either degrees or a cardinal abbreviation. Values like
 * "forward" and "backward" are relative to a way that is not in scope here, so
 * they come back null and the camera is treated as bidirectional.
 */
export function parseDirection(raw?: string): number | null {
  if (!raw) return null

  const trimmed = raw.trim().toLowerCase()
  const numeric = Number.parseFloat(trimmed)
  if (Number.isFinite(numeric)) {
    const normalised = ((numeric % 360) + 360) % 360
    return normalised
  }

  return CARDINALS[trimmed] ?? null
}

/**
 * What this camera enforces.
 *
 * `enforcement` may be a semicolon-separated list, which is how a gantry doing
 * speed and red light at once is tagged. Speed plus signals is its own type
 * because the app treats it as both.
 */
export function cameraTypeFromTags(tags: Record<string, string>): CameraType | null {
  const enforcement = (tags.enforcement ?? '').toLowerCase().split(';').map((v) => v.trim())
  const has = (value: string) => enforcement.includes(value)

  // A camera the police park rather than bolt down. Mapped several ways.
  if (
    tags['speed_camera'] === 'mobile' ||
    tags['speed_trap'] === 'yes' ||
    has('mobile_speed') ||
    tags['highway'] === 'speed_trap'
  ) {
    return 'mobile_hotspot'
  }

  if (has('seatbelt') || has('mobile_phone') || has('handheld') || has('distracted_driving')) {
    return 'seatbelt_phone'
  }

  if (has('bus_lane') || has('psv') || tags['enforcement'] === 'lane') {
    return 'bus_lane'
  }

  const catchesSpeed = has('maxspeed') || tags['highway'] === 'speed_camera'
  const catchesSignals = has('traffic_signals') || has('red_light')

  if (catchesSpeed && catchesSignals) return 'combined'
  if (catchesSignals) return 'red_light'
  if (catchesSpeed) return 'fixed'

  // A surveillance node in a traffic zone with no enforcement tag at all. It is
  // probably a traffic-monitoring camera rather than an enforcement one, but
  // the cost of a false warning is low and the cost of silence is a fine.
  if (tags['man_made'] === 'surveillance' && tags['surveillance:zone'] === 'traffic') {
    return 'fixed'
  }

  return null
}

// ---------------------------------------------------------------------------
// Point cameras
// ---------------------------------------------------------------------------

export function translatePointCamera(
  element: OverpassElement,
  countryCode: string
): CameraRow | null {
  if (element.type !== 'node') return null
  if (element.lat === undefined || element.lon === undefined) return null

  const tags = element.tags ?? {}
  const type = cameraTypeFromTags(tags)
  if (!type) return null

  return {
    osm_id: `node/${element.id}`,
    country_code: countryCode,
    latitude: element.lat,
    longitude: element.lon,
    type,
    direction_degrees: parseDirection(tags.direction ?? tags['camera:direction']),
    speed_limit_kph: parseMaxspeed(tags.maxspeed ?? tags['maxspeed:forward'])
  }
}

// ---------------------------------------------------------------------------
// Average-speed zones
// ---------------------------------------------------------------------------

function memberPoint(member: OverpassMember): LatLon | null {
  if (member.lat !== undefined && member.lon !== undefined) {
    return { lat: member.lat, lon: member.lon }
  }
  if (member.geometry && member.geometry.length > 0) {
    return member.geometry[0]
  }
  return null
}

/**
 * Builds a zone from a `type=enforcement, enforcement=average_speed` relation.
 *
 * The relation carries the road as unrolled member ways, the two cameras as
 * `device` members, and the section boundaries as `from` and `to`. The road
 * ways are what matter: their combined length is the distance the allowance
 * math divides by, and a straight line between the cameras would understate it
 * badly on anything but a motorway.
 *
 * Returns null when the relation cannot be made into something driveable.
 * Storing a zone with a guessed length would be worse than not storing it: the
 * app would confidently coach a speed computed from a wrong distance.
 */
export function translateAverageSpeedZone(
  relation: OverpassElement,
  countryCode: string
): ZoneRow | null {
  if (relation.type !== 'relation' || !relation.members) return null

  const tags = relation.tags ?? {}
  const limit = parseMaxspeed(tags.maxspeed)
  if (!limit) return null // without a limit there is nothing to enforce against

  const roadWays = relation.members
    .filter((m) => m.type === 'way' && (m.role === '' || m.role === 'road') && m.geometry)
    .map((m) => m.geometry as LatLon[])

  const path = stitchWays(roadWays)

  const devices = relation.members
    .filter((m) => m.role === 'device')
    .map(memberPoint)
    .filter((p): p is LatLon => p !== null)

  let entry: LatLon | null = null
  let exit: LatLon | null = null
  let distance = 0
  let measured = false

  if (path.length >= 2) {
    distance = polylineLength(path)
    measured = true

    if (devices.length >= 2) {
      // Order the cameras by how far along the road they sit, so entry really
      // is the one you meet first.
      const ordered = devices
        .map((device) => ({ device, along: distanceAlong(path, device) ?? 0 }))
        .sort((a, b) => a.along - b.along)

      entry = ordered[0].device
      exit = ordered[ordered.length - 1].device
      distance = ordered[ordered.length - 1].along - ordered[0].along
    } else {
      entry = path[0]
      exit = path[path.length - 1]
    }
  } else if (devices.length >= 2) {
    // No usable road geometry. Refuse rather than guess: see the doc comment.
    return null
  }

  if (!entry || !exit || !(distance > 0)) return null

  // A section under a kilometre is almost always a mis-tagged relation rather
  // than real average-speed enforcement, and the coaching maths gets twitchy
  // over very short distances.
  if (distance < 500) return null

  return {
    osm_id: `relation/${relation.id}`,
    country_code: countryCode,
    name: tags.name ?? null,
    road_ref: tags.ref ?? null,
    entry,
    exit,
    distance_meters: Math.round(distance),
    speed_limit_kph: limit,
    minimum_speed_kph: parseMaxspeed(tags.minspeed),
    direction_degrees: path.length >= 2 ? bearingDegrees(entry, exit) : null,
    path,
    measured
  }
}

// ---------------------------------------------------------------------------
// Rest stops
// ---------------------------------------------------------------------------

export function translateRestStop(
  element: OverpassElement,
  countryCode: string
): RestStopRow | null {
  const tags = element.tags ?? {}

  // `out center` puts a way's centroid in a `center` object.
  const centre = (element as unknown as { center?: LatLon }).center
  const lat = element.lat ?? centre?.lat
  const lon = element.lon ?? centre?.lon
  if (lat === undefined || lon === undefined) return null

  let kind: RestStopRow['kind'] | null = null
  if (tags.highway === 'rest_area') kind = 'rest_area'
  else if (tags.highway === 'services') kind = 'services'
  else if (tags.amenity === 'fuel') kind = 'fuel_station'
  else if (tags.amenity === 'parking') kind = 'parking'
  else if (tags.tourism === 'viewpoint') kind = 'viewpoint'

  if (!kind) return null

  return {
    osm_id: `${element.type}/${element.id}`,
    country_code: countryCode,
    name: tags.name ?? null,
    latitude: lat,
    longitude: lon,
    kind
  }
}
