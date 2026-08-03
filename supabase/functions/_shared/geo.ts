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

interface WayJoin {
  index: number
  /** True when it is the way's first point that touches the anchor. */
  touchesStart: boolean
  distance: number
}

/** The remaining way with an endpoint closest to `anchor`, within tolerance. */
function nearestJoin(ways: LatLon[][], anchor: LatLon, tolerance: number): WayJoin | null {
  let best: WayJoin | null = null

  for (let index = 0; index < ways.length; index++) {
    const way = ways[index]
    const candidates: WayJoin[] = [
      { index, touchesStart: true, distance: distanceMeters(anchor, way[0]) },
      { index, touchesStart: false, distance: distanceMeters(anchor, way[way.length - 1]) }
    ]
    for (const candidate of candidates) {
      if (candidate.distance <= tolerance && (best === null || candidate.distance < best.distance)) {
        best = candidate
      }
    }
  }

  return best
}

/**
 * Joins OSM way geometries end to end.
 *
 * Relation members arrive in document order but not necessarily in travel
 * order, and any given way may be digitised against the direction of travel.
 *
 * The chain grows from **both** ends, which matters more than it sounds. Members
 * are listed in whatever order the mapper added them, so the first one is often
 * somewhere in the middle of the section: growing only forwards stops at the
 * first gap and returns a fragment of the road, silently, and a fragment is
 * indistinguishable from a short section. A real Lithuanian relation had its two
 * ways listed second-then-first and measured 500 m instead of 3 km because of it.
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
    const atTail = nearestJoin(remaining, chain[chain.length - 1], toleranceMeters)
    if (atTail) {
      const [way] = remaining.splice(atTail.index, 1)
      // Orient it to start where the chain currently ends, then drop the shared
      // junction node so it is not repeated.
      const oriented = atTail.touchesStart ? way : [...way].reverse()
      chain.push(...oriented.slice(1))
      continue
    }

    const atHead = nearestJoin(remaining, chain[0], toleranceMeters)
    if (atHead) {
      const [way] = remaining.splice(atHead.index, 1)
      // Orient it to end where the chain currently starts.
      const oriented = atHead.touchesStart ? [...way].reverse() : way
      chain.unshift(...oriented.slice(0, -1))
      continue
    }

    // Nothing left touches either end: the rest is a disconnected fragment.
    break
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

/**
 * Ramer-Douglas-Peucker, in metres.
 *
 * Road-limit geometry is the one dataset here big enough for its own size to be
 * a design constraint: every drivable way in a country with a maxspeed tag runs
 * to hundreds of thousands of ways. OSM digitises road centrelines at a fidelity
 * that exists for rendering, and the phone only ever asks one question of this
 * geometry - "am I on this road?" - which it answers with a 30 m corridor. Points
 * that move the line by less than a few metres cannot change that answer, so
 * carrying them costs download size and SQLite pages for nothing.
 *
 * The tolerance is deliberately well below the matching corridor. Simplifying at
 * anything close to it would let a bend drift far enough to hand the driver the
 * limit from the road they are not on.
 */
export function simplifyPolyline(points: LatLon[], toleranceMeters = 8): LatLon[] {
  if (points.length <= 2) return [...points]

  const keep = new Array<boolean>(points.length).fill(false)
  keep[0] = true
  keep[points.length - 1] = true

  // Iterative rather than recursive: a long motorway way can run to tens of
  // thousands of points, and the naive recursion blows the stack on the
  // degenerate case of an almost-straight road.
  const stack: [number, number][] = [[0, points.length - 1]]

  while (stack.length > 0) {
    const [first, last] = stack.pop() as [number, number]
    if (last <= first + 1) continue

    let worstIndex = -1
    let worstDistance = 0

    for (let i = first + 1; i < last; i++) {
      const distance = perpendicularDistance(points[i], points[first], points[last])
      if (distance > worstDistance) {
        worstDistance = distance
        worstIndex = i
      }
    }

    if (worstIndex >= 0 && worstDistance > toleranceMeters) {
      keep[worstIndex] = true
      stack.push([first, worstIndex], [worstIndex, last])
    }
  }

  return points.filter((_, index) => keep[index])
}

/** Distance in metres from `point` to the segment `start`-`end`. */
function perpendicularDistance(point: LatLon, start: LatLon, end: LatLon): number {
  // Local flat frame anchored at the segment start, scaled so a degree of
  // longitude and a degree of latitude are the same length on the ground.
  const scale = Math.cos(toRad(start.lat))
  const ex = (end.lon - start.lon) * scale
  const ey = end.lat - start.lat
  const px = (point.lon - start.lon) * scale
  const py = point.lat - start.lat

  const lengthSquared = ex * ex + ey * ey
  if (lengthSquared === 0) return distanceMeters(point, start)

  const t = Math.max(0, Math.min(1, (px * ex + py * ey) / lengthSquared))
  const nearest = {
    lat: start.lat + ey * t,
    lon: start.lon + (end.lon - start.lon) * t
  }
  return distanceMeters(point, nearest)
}

export interface BoundingBox {
  minLat: number
  minLon: number
  maxLat: number
  maxLon: number
}

/**
 * Splits a bounding box into tiles no larger than `stepDegrees` on a side.
 *
 * Overpass cannot return a whole country's worth of way geometry in one answer:
 * the response runs to hundreds of megabytes and the query times out long before
 * it finishes assembling. Tiling turns one impossible request into a few hundred
 * ordinary ones, each of which can be retried on its own.
 *
 * Row-major from the south-west corner, so a run that stops half way and resumes
 * covers a contiguous area rather than a scatter, which makes a partial dataset
 * obviously partial on a map instead of subtly moth-eaten.
 */
export function boundingBoxTiles(box: BoundingBox, stepDegrees = 0.25): BoundingBox[] {
  const tiles: BoundingBox[] = []
  const step = Math.max(stepDegrees, 0.01)

  // Walk on integer counts rather than accumulating `lat += step`. Repeated
  // float addition drifts, and over the ~40 steps a large country needs the
  // drift is enough to leave a sliver of the north edge uncovered.
  const rows = Math.ceil((box.maxLat - box.minLat) / step)
  const columns = Math.ceil((box.maxLon - box.minLon) / step)

  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      tiles.push({
        minLat: box.minLat + row * step,
        minLon: box.minLon + column * step,
        maxLat: Math.min(box.minLat + (row + 1) * step, box.maxLat),
        maxLon: Math.min(box.minLon + (column + 1) * step, box.maxLon)
      })
    }
  }

  return tiles
}

/** A stable name for a tile, used as a resume checkpoint key. */
export function tileKey(tile: BoundingBox): string {
  return [tile.minLat, tile.minLon, tile.maxLat, tile.maxLon]
    .map((value) => value.toFixed(4))
    .join(',')
}
