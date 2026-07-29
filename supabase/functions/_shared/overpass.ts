/**
 * Talking to Overpass.
 *
 * Overpass is a free service run by volunteers. It rate limits, it times out
 * under load, and individual mirrors go down. Everything here is built around
 * that: several endpoints, exponential backoff, and a nightly schedule that
 * runs at an odd minute rather than on the hour.
 */

import type { LatLon } from './geo.ts'

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
area["ISO3166-1"="${isoCode}"][admin_level=2]->.country;
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
 */
export function averageSpeedZoneQuery(isoCode: string, timeoutSeconds = 300): string {
  return `[out:json][timeout:${timeoutSeconds}];
area["ISO3166-1"="${isoCode}"][admin_level=2]->.country;
relation["type"="enforcement"]["enforcement"="average_speed"](area.country);
out geom;`
}

/**
 * Places to stop inside a zone. Only fetched for countries that actually have
 * average-speed sections, because it is a large query and useless without one.
 */
export function restStopQuery(isoCode: string, timeoutSeconds = 180): string {
  return `[out:json][timeout:${timeoutSeconds}];
area["ISO3166-1"="${isoCode}"][admin_level=2]->.country;
(
  node["highway"="rest_area"](area.country);
  node["highway"="services"](area.country);
  node["amenity"="fuel"](area.country);
  way["highway"="rest_area"](area.country);
  way["highway"="services"](area.country);
);
out center qt;`
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
            'User-Agent': 'GlidePath/1.0 (+https://github.com/allexp1/glidepath)'
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
