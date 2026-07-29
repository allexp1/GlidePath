/**
 * Geometry helpers. Deliberately duplicated from the Swift package rather than
 * shared: this side runs once a night on a server, that side runs at 1 Hz in a
 * car, and tying them together would mean a build step neither one needs.
 */

export interface LatLon {
  lat: number
  lon: number
}

const EARTH_RADIUS_M = 6371008.8
const toRad = (deg: number) => (deg * Math.PI) / 180

/** Great-circle distance in metres. */
export function distanceMeters(a: LatLon, b: LatLon): number {
  const dLat = toRad(b.lat - a.lat)
  const dLon = toRad(b.lon - a.lon)
  const lat1 = toRad(a.lat)
  const lat2 = toRad(b.lat)

  const h =
    Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2
  return 2 * EARTH_RADIUS_M * Math.atan2(Math.sqrt(h), Math.sqrt(Math.max(0, 1 - h)))
}

/** Length of a polyline in metres. */
export function polylineLength(points: LatLon[]): number {
  let total = 0
  for (let i = 1; i < points.length; i++) {
    total += distanceMeters(points[i - 1], points[i])
  }
  return total
}

/** Initial bearing in degrees clockwise from true north. */
export function bearingDegrees(from: LatLon, to: LatLon): number {
  const lat1 = toRad(from.lat)
  const lat2 = toRad(to.lat)
  const dLon = toRad(to.lon - from.lon)

  const y = Math.sin(dLon) * Math.cos(lat2)
  const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon)
  const deg = (Math.atan2(y, x) * 180) / Math.PI
  return deg < 0 ? deg + 360 : deg
}

/** WKT for a PostGIS point, in lon/lat order as the standard requires. */
export function pointWKT(point: LatLon): string {
  return `SRID=4326;POINT(${point.lon} ${point.lat})`
}

/** WKT for a PostGIS linestring. Returns null for anything too short to be one. */
export function lineStringWKT(points: LatLon[]): string | null {
  if (points.length < 2) return null
  const coords = points.map((p) => `${p.lon} ${p.lat}`).join(',')
  return `SRID=4326;LINESTRING(${coords})`
}

/**
 * Joins OSM way geometries end to end.
 *
 * Relation members arrive in document order but not necessarily in travel
 * order, and any given way may be digitised against the direction of travel.
 * At each step this picks whichever remaining way has an endpoint nearest the
 * current end of the chain and flips it if needed.
 *
 * `toleranceMeters` is what counts as "joined". OSM nodes are shared between
 * ways so the true gap is zero, but rounding in Overpass output and the
 * occasional genuinely disconnected member mean a small tolerance is kinder
 * than an exact match.
 */
export function stitchWays(ways: LatLon[][], toleranceMeters = 25): LatLon[] {
  const usable = ways.filter((way) => way.length >= 2)
  if (usable.length === 0) return []

  const remaining = [...usable]
  const chain = [...(remaining.shift() as LatLon[])]

  while (remaining.length > 0) {
    const tail = chain[chain.length - 1]

    let bestIndex = -1
    let bestDistance = Infinity
    let bestReversed = false

    remaining.forEach((way, index) => {
      const toStart = distanceMeters(tail, way[0])
      const toEnd = distanceMeters(tail, way[way.length - 1])

      if (toStart < bestDistance) {
        bestDistance = toStart
        bestIndex = index
        bestReversed = false
      }
      if (toEnd < bestDistance) {
        bestDistance = toEnd
        bestIndex = index
        bestReversed = true
      }
    })

    if (bestIndex < 0 || bestDistance > toleranceMeters) break

    const [next] = remaining.splice(bestIndex, 1)
    const ordered = bestReversed ? [...next].reverse() : next
    // Drop the shared junction node so it is not repeated.
    chain.push(...ordered.slice(1))
  }

  return chain
}

export interface LineProjection {
  /** Distance from the start of the line to the nearest point, in metres. */
  along: number
  /** Perpendicular distance from the line, in metres. */
  offset: number
}

/**
 * Projects a point onto a polyline.
 *
 * `along` places rest stops and works out which end of a section a camera
 * guards. `offset` is how the seed decides whether a rest stop is actually
 * beside this road or merely near it as the crow flies.
 */
export function projectOntoLine(line: LatLon[], target: LatLon): LineProjection | null {
  if (line.length < 2) return null

  let best = Infinity
  let bestAlong = 0
  let travelled = 0

  for (let i = 1; i < line.length; i++) {
    const segStart = line[i - 1]
    const segEnd = line[i]
    const segLength = distanceMeters(segStart, segEnd)
    if (segLength === 0) continue

    // Local flat frame anchored at the segment start.
    const scale = Math.cos(toRad(segStart.lat))
    const ex = (segEnd.lon - segStart.lon) * scale
    const ey = segEnd.lat - segStart.lat
    const px = (target.lon - segStart.lon) * scale
    const py = target.lat - segStart.lat

    const lengthSquared = ex * ex + ey * ey
    const t = lengthSquared > 0 ? Math.max(0, Math.min(1, (px * ex + py * ey) / lengthSquared)) : 0

    const nearest = {
      lat: segStart.lat + ey * t,
      lon: segStart.lon + (segEnd.lon - segStart.lon) * t
    }
    const offset = distanceMeters(target, nearest)

    if (offset < best) {
      best = offset
      bestAlong = travelled + t * segLength
    }
    travelled += segLength
  }

  return { along: bestAlong, offset: best }
}

/** Convenience wrapper for callers that only care where along the line a point sits. */
export function distanceAlong(line: LatLon[], target: LatLon): number | null {
  return projectOntoLine(line, target)?.along ?? null
}
