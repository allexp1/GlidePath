/**
 * Talking to Overpass.
 *
 * Overpass is a free service run by volunteers. It rate limits, it times out
 * under load, and individual mirrors go down. Everything here is built around
 * that: several endpoints, exponential backoff, and a nightly schedule that
 * runs at an odd minute rather than on the hour.
 */

import type { BoundingBox, LatLon } from './geo.ts'

export const OVERPASS_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass.osm.ch/api/interpreter'
]

export interface OverpassElement {
  type: 'node' | 'way' | 'relation'
  id: number
  lat?: number
  lon?: number
  tags?: Record<string, string>
  /** Present on ways when the query used `out geom`. */
  geometry?: LatLon[]
  members?: OverpassMember[]
  /** Present when the query used `out bb`. */
  bounds?: { minlat: number; minlon: number; maxlat: number; maxlon: number }
}

export interface OverpassMember {
  type: 'node' | 'way' | 'relation'
  ref: number
  role: string
  lat?: number
  lon?: number
  geometry?: LatLon[]
}

export interface OverpassResponse {
  elements: OverpassElement[]
}

/**
 * The tags that select one country, or one subdivision of one.
 *
 * Some places cannot be handled whole. The United States has millions of ways
 * carrying a maxspeed tag, so "download the USA" is not an offer any phone can
 * accept, and a harvest of it would run for weeks. The unit that works there is
 * the state.
 *
 * OpenStreetMap already draws that line: a country carries `ISO3166-1` at
 * `admin_level=2`, and its subdivisions carry `ISO3166-2` at `admin_level=4`.
 * A hyphen in the code is what distinguishes them - `LT` is Lithuania, `US-NY`
 * is New York - which is ISO 3166-2's own convention rather than anything
 * invented here.
 *
 * Everything downstream is unchanged: the catalogue is keyed on an opaque text
 * code, and `overpass_iso_code` already existed to let the two differ.
 */
export function areaSelector(isoCode: string): string {
  return isoCode.includes('-')
    ? `["ISO3166-2"="${isoCode}"][admin_level=4]`
    : `["ISO3166-1"="${isoCode}"][admin_level=2]`
}

/**
 * Point cameras.
 *
 * `highway=speed_camera` is the main tagging scheme. `man_made=surveillance`
 * with a traffic zone catches the installations mapped as generic surveillance
 * equipment, which is common where a single gantry does several jobs. The
 * standalone `enforcement=*` node query picks up seat belt and phone cameras,
 * which are newer and not consistently tagged as speed cameras.
 */
export function pointCameraQuery(isoCode: string, timeoutSeconds = 180): string {
  return `[out:json][timeout:${timeoutSeconds}];
area${areaSelector(isoCode)}->.country;
(
  node["highway"="speed_camera"](area.country);
  node["man_made"="surveillance"]["surveillance:zone"="traffic"](area.country);
  node["enforcement"](area.country);
);
out body qt;`
}

/**
 * Average-speed sections.
 *
 * These are relations, not nodes: `type=enforcement` with
 * `enforcement=average_speed`, holding the road ways between the cameras plus
 * `device` members for the cameras themselves. `out geom` is what makes the
 * member way geometry come back, which is the only way to get a road-distance
 * rather than a straight line between the endpoints.
 *
 * The second half fetches the member ways again, tags only, because most
 * relations do not carry a `maxspeed` of their own - 164 of Lithuania's 182 do
 * not - and the limit being enforced is simply the posted limit of the road the
 * section runs along. Reading it off the ways is not a guess; it is reading the
 * same fact from where OpenStreetMap actually keeps it. `out tags` rather than
 * `out geom` because the geometry already came back above and repeating it would
 * roughly double a response that is already the largest one here.
 */
export function averageSpeedZoneQuery(isoCode: string, timeoutSeconds = 300): string {
  return `[out:json][timeout:${timeoutSeconds}];
area${areaSelector(isoCode)}->.country;
relation["type"="enforcement"]["enforcement"="average_speed"](area.country)->.sections;
.sections out geom;
way(r.sections)->.roads;
.roads out tags;`
}

/**
 * Places to stop inside a zone. Only fetched for countries that actually have
 * average-speed sections, because it is a large query and useless without one.
 */
export function restStopQuery(isoCode: string, timeoutSeconds = 180): string {
  return `[out:json][timeout:${timeoutSeconds}];
area${areaSelector(isoCode)}->.country;
(
  node["highway"="rest_area"](area.country);
  node["highway"="services"](area.country);
  node["amenity"="fuel"](area.country);
  way["highway"="rest_area"](area.country);
  way["highway"="services"](area.country);
);
out center qt;`
}

/**
 * The `highway` values a car can be ticketed on.
 *
 * Not "every value with a maxspeed tag". Driveways and parking aisles are
 * `service` and are routinely tagged `maxspeed=10`; a car crossing a supermarket
 * car park at 30 is not speeding, and being told so would teach the driver that
 * the limit alerts are noise. `track` is the same argument for farm tracks.
 * Footways and cycleways carry maxspeed for bicycles and are not roads at all.
 */
export const DRIVABLE_HIGHWAY_VALUES = [
  'motorway',
  'motorway_link',
  'trunk',
  'trunk_link',
  'primary',
  'primary_link',
  'secondary',
  'secondary_link',
  'tertiary',
  'tertiary_link',
  'unclassified',
  'residential',
  'living_street',
  'busway',
  'road'
]

/**
 * Where a country actually is, so the tiler knows what to cover.
 *
 * `out bb` returns the bounding box and nothing else, which is a few hundred
 * bytes for a query that would otherwise be the entire national boundary
 * polygon.
 */
export function countryBoundsQuery(isoCode: string, timeoutSeconds = 90): string {
  return `[out:json][timeout:${timeoutSeconds}];
relation${areaSelector(isoCode)};
out bb;`
}

/**
 * Posted speed limits for one tile of one country.
 *
 * Both the area filter and the bounding box, which sounds redundant and is not.
 * The bbox is what keeps a single answer small enough to arrive at all; the area
 * filter is what stops a tile on the border returning the neighbouring country's
 * roads and filing them under the wrong dataset.
 *
 * The union's second half catches ways tagged only `maxspeed:forward`, which is
 * how an asymmetric limit is mapped when the two directions have no common
 * value. Rare, but a way tagged that way is a real road with a real limit and
 * the first half of the union will never see it.
 */
export function roadLimitQuery(
  isoCode: string,
  tile: BoundingBox,
  timeoutSeconds = 180
): string {
  const bbox = `${tile.minLat},${tile.minLon},${tile.maxLat},${tile.maxLon}`
  const highways = DRIVABLE_HIGHWAY_VALUES.join('|')

  return `[out:json][timeout:${timeoutSeconds}];
area${areaSelector(isoCode)}->.country;
(
  way["highway"~"^(${highways})$"]["maxspeed"](area.country)(${bbox});
  way["highway"~"^(${highways})$"]["maxspeed:forward"](area.country)(${bbox});
);
out geom qt;`
}

export interface OverpassOptions {
  /** How many times to try the whole endpoint list before giving up. */
  rounds?: number
  /** Base delay for the exponential backoff, in milliseconds. */
  backoffMs?: number
  fetchImpl?: typeof fetch
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * Runs a query, trying each endpoint in turn and backing off between rounds.
 *
 * Throws only when every endpoint has failed on every round, which the caller
 * records against the country as last_sync_error rather than treating as fatal:
 * one country failing must not stop the others syncing.
 */
export async function runOverpassQuery(
  query: string,
  options: OverpassOptions = {}
): Promise<OverpassResponse> {
  const { rounds = 3, backoffMs = 5000, fetchImpl = fetch } = options
  const failures: string[] = []

  for (let round = 0; round < rounds; round++) {
    for (const endpoint of OVERPASS_ENDPOINTS) {
      try {
        const response = await fetchImpl(endpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            // Overpass asks for a contactable user agent so an operator can
            // reach whoever is hammering them.
            'User-Agent': 'Zonexplo/1.0 (+https://github.com/allexp1/zonexplo)'
          },
          body: new URLSearchParams({ data: query })
        })

        if (!response.ok) {
          failures.push(`${endpoint}: HTTP ${response.status}`)
          continue
        }

        const payload = (await response.json()) as OverpassResponse
        if (!Array.isArray(payload.elements)) {
          failures.push(`${endpoint}: response had no elements array`)
          continue
        }
        return payload
      } catch (error) {
        failures.push(`${endpoint}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }

    if (round < rounds - 1) {
      await sleep(backoffMs * 2 ** round)
    }
  }

  throw new Error(`every Overpass endpoint failed: ${failures.join('; ')}`)
}
