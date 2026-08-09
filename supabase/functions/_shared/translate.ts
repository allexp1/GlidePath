/**
 * Turning OpenStreetMap tags into Zonexplo rows.
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

import {
  bearingDegrees,
  distanceAlong,
  distanceMeters,
  polylineLength,
  simplifyPolyline,
  stitchWays
} from './geo.ts'
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

/** A stretch of road with a posted limit on it. */
export interface RoadLimitRow {
  osm_id: string
  country_code: string
  name: string | null
  road_ref: string | null
  highway: string
  /** The limit to use when the direction of travel cannot be established. */
  limit_kph: number
  /** Limit for travel along the stored geometry, when the two differ. */
  forward_limit_kph: number | null
  /** Limit for travel against the stored geometry, when the two differ. */
  backward_limit_kph: number | null
  path: LatLon[]
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

  // A plate reader is not an enforcement camera and must not be warned about.
  //
  // An ALPR photographs every plate that passes so the number can be looked up
  // later. It does not measure speed and cannot issue a speeding ticket, so a
  // warning at one teaches the driver that this app's warnings do not mean
  // anything.
  //
  // This is excluded explicitly because the fallback below would otherwise
  // swallow it, and the numbers make that fatal rather than untidy: New York
  // has 111 nodes tagged highway=speed_camera and 3,788 tagged as ALPR
  // surveillance, largely from an organised mapping campaign of Flock Safety
  // units. Without this the app would fire ~3,800 false warnings across the
  // state, be muted inside a day, and take its real warnings down with it.
  //
  // Ordered after the enforcement checks on purpose. A camera tagged both ALPR
  // and enforcement=maxspeed has been asserted by a mapper to enforce speed,
  // and that assertion is worth more than this inference.
  if ((tags['surveillance:type'] ?? '').toUpperCase().includes('ALPR')) {
    return null
  }

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

/** Roles under which mappers put the road itself. `section` is the common one. */
const ROAD_ROLES = new Set(['', 'road', 'section'])

/** The members that make up the road, in relation order. */
export function roadWayMembers(members: OverpassMember[]): OverpassMember[] {
  return members.filter((m) => m.type === 'way' && ROAD_ROLES.has(m.role))
}

/**
 * The limit a section enforces, when the relation itself does not say.
 *
 * Most enforcement relations carry no `maxspeed` of their own, because the limit
 * being enforced is simply the posted limit of the road. That lives on the member
 * ways, so this reads it from there. Not a guess: the same fact, read from where
 * OpenStreetMap actually keeps it.
 *
 * Every road way must carry a limit and they must all agree. A section whose ways
 * disagree either genuinely changes limit part way along or has a slip road
 * included by mistake, and there is no honest single number for either case.
 * Taking the lowest would be safe against a fine but would put a number on screen
 * that contradicts the signs for most of the drive; taking the highest could earn
 * one. Refusing is the only option that never states something untrue.
 */
function limitFromRoadWays(
  members: OverpassMember[],
  wayTags: Map<number, Record<string, string>>
): number | null {
  const roadWays = roadWayMembers(members)
  if (roadWays.length === 0) return null

  const limits = new Set<number>()
  for (const way of roadWays) {
    const limit = parseMaxspeed(wayTags.get(way.ref)?.maxspeed)
    if (!limit) return null
    limits.add(limit)
  }

  return limits.size === 1 ? [...limits][0] : null
}

/**
 * Puts a stitched path into the direction of travel.
 *
 * The `from` and `to` members are the only statement of direction in the
 * relation, and the ways come back in whatever order they were added, so the
 * stitched path points either way with equal likelihood. Getting this wrong
 * swaps entry and exit, which means the app coaches towards the camera the
 * driver has already passed - a zone driven backwards.
 */
function orientToTravel(path: LatLon[], members: OverpassMember[]): LatLon[] {
  if (path.length < 2) return path

  const from = members.find((m) => m.role === 'from')
  const to = members.find((m) => m.role === 'to')
  const start = from ? memberPoint(from) : null
  const end = to ? memberPoint(to) : null
  if (!start && !end) return path

  const head = path[0]
  const tail = path[path.length - 1]

  // Sum both ends when both are known, so one mis-mapped marker cannot flip it.
  const asIs = (start ? distanceMeters(start, head) : 0) + (end ? distanceMeters(end, tail) : 0)
  const flipped = (start ? distanceMeters(start, tail) : 0) + (end ? distanceMeters(end, head) : 0)

  return flipped < asIs ? [...path].reverse() : path
}

/**
 * Builds a zone from a `type=enforcement, enforcement=average_speed` relation.
 *
 * The relation carries the road as member ways under the `section` role, the two
 * cameras as `device` members, and the direction of travel as `from` and `to`.
 * The road ways are what matter: their combined length is the distance the
 * allowance math divides by, and a straight line between the cameras would
 * understate it badly on anything but a motorway.
 *
 * `wayTags` carries the member ways' tags so the limit can be read off the road
 * when the relation has none. It defaults to empty, so a caller holding only
 * geometry still works.
 *
 * Returns null when the relation cannot be made into something driveable.
 * Storing a zone with a guessed length would be worse than not storing it: the
 * app would confidently coach a speed computed from a wrong distance.
 */
export function translateAverageSpeedZone(
  relation: OverpassElement,
  countryCode: string,
  wayTags: Map<number, Record<string, string>> = new Map()
): ZoneRow | null {
  if (relation.type !== 'relation' || !relation.members) return null

  const tags = relation.tags ?? {}
  // The relation wins when it has a limit: a mapper who put one there meant it.
  const limit = parseMaxspeed(tags.maxspeed) ?? limitFromRoadWays(relation.members, wayTags)
  if (!limit) return null // without a limit there is nothing to enforce against

  const roadWays = relation.members
    .filter((m) => m.type === 'way' && ROAD_ROLES.has(m.role) && m.geometry)
    .map((m) => m.geometry as LatLon[])

  const path = orientToTravel(stitchWays(roadWays), relation.members)

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

/**
 * Why `translateAverageSpeedZone` refused a relation, in a sentence.
 *
 * Exists because the alternative is a single catch-all warning, and a wall of
 * two hundred identical "no usable geometry or limit" lines says that something
 * is wrong while saying nothing about what. Working out which half was at fault
 * cost a round trip to a real dataset once; it should not cost another.
 *
 * Reported most-fundamental first rather than in the order the translator checks
 * them: a relation with no road at all is a different conversation from one whose
 * limit is missing, and it is the more useful thing to be told.
 *
 * Returns null when the relation is in fact usable.
 */
export function zoneRejectionReason(
  relation: OverpassElement,
  wayTags: Map<number, Record<string, string>> = new Map()
): string | null {
  if (relation.type !== 'relation' || !relation.members) return 'not a relation with members'
  if (translateAverageSpeedZone(relation, 'XX', wayTags)) return null

  const members = relation.members
  const tags = relation.tags ?? {}
  const roadWays = roadWayMembers(members)

  // ---- The road ----------------------------------------------------------

  if (roadWays.length === 0) {
    const roles = [...new Set(members.filter((m) => m.type === 'way').map((m) => m.role || '(empty)'))]
    return roles.length > 0
      ? `no member way has a road role (found: ${roles.join(', ')})`
      : 'no member ways at all'
  }

  // ---- The limit ---------------------------------------------------------

  if (tags.maxspeed && !parseMaxspeed(tags.maxspeed)) {
    return `maxspeed "${tags.maxspeed}" is not a number this understands`
  }

  if (!parseMaxspeed(tags.maxspeed) && !limitFromRoadWays(members, wayTags)) {
    const limits = roadWays.map((way) => parseMaxspeed(wayTags.get(way.ref)?.maxspeed))
    const missing = limits.filter((limit) => limit === null).length
    if (missing > 0) {
      return `no maxspeed on the relation, and ${missing} of its ${roadWays.length} ` +
        'road ways have none either'
    }
    const distinct = [...new Set(limits)].sort((a, b) => (a ?? 0) - (b ?? 0))
    return `no maxspeed on the relation, and its road ways disagree (${distinct.join(', ')})`
  }

  // ---- The geometry ------------------------------------------------------

  const withGeometry = roadWays.filter((m) => m.geometry)
  if (withGeometry.length === 0) {
    return `none of the ${roadWays.length} road ways came back with geometry`
  }

  const path = stitchWays(withGeometry.map((m) => m.geometry as LatLon[]))
  if (path.length < 2) {
    return `${withGeometry.length} road ways would not stitch into a single path`
  }

  const length = Math.round(polylineLength(path))
  if (length < 500) return `section measures ${length} m, under the 500 m floor`

  const devices = members.filter((m) => m.role === 'device').length
  return `${devices} device member(s) and a ${length} m path, but no usable entry and exit`
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

// ---------------------------------------------------------------------------
// Road speed limits
// ---------------------------------------------------------------------------

/**
 * Shorter than this and there is nothing to match against.
 *
 * A 12 m stub between two junctions cannot be told apart from the roads either
 * side of it by a receiver with 5 m of error, and matching onto one would hand
 * the driver a limit that belongs to a few car lengths of tarmac.
 */
export const MINIMUM_ROAD_LIMIT_LENGTH_METERS = 25

/**
 * One drivable way with a posted limit.
 *
 * The rule this follows is the same one the rest of the file follows for
 * cameras, pointed the other way: **never state a limit that was not read off
 * the data.** `maxspeed` is free text and a large slice of it - "LT:urban",
 * "none", "walk", "signals" - carries no number. Those ways are dropped rather
 * than resolved against a table of national defaults, because a limit spoken
 * aloud is a claim about a sign the driver can see, and being confidently wrong
 * about it is worse than saying nothing. The app is silent on a road it has no
 * limit for, which is the honest answer.
 */
export function translateRoadLimit(
  element: OverpassElement,
  countryCode: string,
  toleranceMeters = 8
): RoadLimitRow | null {
  if (element.type !== 'way') return null

  const geometry = element.geometry
  if (!Array.isArray(geometry) || geometry.length < 2) return null

  const tags = element.tags ?? {}
  const highway = tags.highway
  if (!highway) return null

  const base = parseMaxspeed(tags.maxspeed)
  const forward = parseMaxspeed(tags['maxspeed:forward'])
  const backward = parseMaxspeed(tags['maxspeed:backward'])

  // A one-way road has no "against the geometry" direction, so a
  // maxspeed:backward on one is either leftover tagging or refers to something
  // other than motor traffic. Dropping it stops the matcher offering a limit
  // for a direction nobody can legally drive.
  const oneway = (tags.oneway ?? '').toLowerCase()
  const isOneway = oneway === 'yes' || oneway === '1' || oneway === '-1'

  // The fallback when the direction of travel is unknown. The *higher* of the
  // two, deliberately: an unnecessary silence is a smaller failure than a
  // warning that is wrong, and the app only ever falls back here when it could
  // not work out which way the driver is going.
  const fallback = base ?? maxOf(forward, isOneway ? null : backward)
  if (fallback === null) return null

  const path = simplifyPolyline(geometry, toleranceMeters)
  if (path.length < 2) return null
  if (polylineLength(path) < MINIMUM_ROAD_LIMIT_LENGTH_METERS) return null

  return {
    osm_id: `way/${element.id}`,
    country_code: countryCode,
    name: tags.name ?? null,
    road_ref: tags.ref ?? null,
    highway,
    limit_kph: fallback,
    // Only stored when they actually say something the base tag does not.
    forward_limit_kph: forward !== null && forward !== fallback ? forward : null,
    backward_limit_kph:
      !isOneway && backward !== null && backward !== fallback ? backward : null,
    path
  }
}

function maxOf(a: number | null, b: number | null): number | null {
  if (a === null) return b
  if (b === null) return a
  return Math.max(a, b)
}
