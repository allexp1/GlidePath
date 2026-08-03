import { assert, assertAlmostEquals, assertEquals } from 'jsr:@std/assert@^1'
import { boundingBoxTiles, polylineLength, simplifyPolyline, tileKey } from './geo.ts'
import type { BoundingBox, LatLon } from './geo.ts'
import { DRIVABLE_HIGHWAY_VALUES, roadLimitQuery } from './overpass.ts'
import type { OverpassElement } from './overpass.ts'
import { translateRoadLimit } from './translate.ts'

// Lithuania, where this was tested.
const LAT = 54.5
const point = (lon: number, lat = LAT): LatLon => ({ lat, lon })

/** Roughly 1.3 km of road at this latitude, which clears the 25 m floor. */
const geometry = [point(24.0), point(24.02)]

function way(tags: Record<string, string>, geom: LatLon[] = geometry): OverpassElement {
  return { type: 'way', id: 1, tags, geometry: geom }
}

// ---------------------------------------------------------------------------
// Reading the limit off the tags
// ---------------------------------------------------------------------------

Deno.test('translateRoadLimit reads a plain maxspeed', () => {
  const row = translateRoadLimit(way({ highway: 'primary', maxspeed: '90' }), 'LT')

  assert(row)
  assertEquals(row.limit_kph, 90)
  assertEquals(row.forward_limit_kph, null)
  assertEquals(row.backward_limit_kph, null)
  assertEquals(row.osm_id, 'way/1')
})

Deno.test('translateRoadLimit converts mph', () => {
  const row = translateRoadLimit(way({ highway: 'primary', maxspeed: '50 mph' }), 'LT')
  assertEquals(row?.limit_kph, 80)
})

// The rule the whole feature rests on. A limit is a claim about a sign the
// driver can see, so it is only ever stored when it was read off the data.
// Resolving "LT:urban" against a table of national defaults would put a number
// on screen that nobody sourced, and being confidently wrong about a limit is
// worse than saying nothing.
Deno.test('translateRoadLimit drops implicit and non-numeric limits', () => {
  for (const maxspeed of ['LT:urban', 'DE:rural', 'none', 'walk', 'signals', 'variable', '']) {
    assertEquals(
      translateRoadLimit(way({ highway: 'primary', maxspeed }), 'LT'),
      null,
      `"${maxspeed}" carries no number and must not become a limit`
    )
  }
})

Deno.test('translateRoadLimit rejects an implausible limit', () => {
  assertEquals(translateRoadLimit(way({ highway: 'primary', maxspeed: '300' }), 'LT'), null)
  assertEquals(translateRoadLimit(way({ highway: 'primary', maxspeed: '0' }), 'LT'), null)
})

Deno.test('translateRoadLimit keeps directional limits that differ from the base', () => {
  const row = translateRoadLimit(
    way({ highway: 'primary', maxspeed: '90', 'maxspeed:forward': '110' }),
    'LT'
  )

  assertEquals(row?.limit_kph, 90)
  assertEquals(row?.forward_limit_kph, 110)
  assertEquals(row?.backward_limit_kph, null)
})

// The higher of the two on purpose. The fallback is only reached when the app
// could not work out which way the driver is going, and an unnecessary silence
// is a smaller failure than telling someone they are over a limit that applies
// to the other carriageway.
Deno.test('translateRoadLimit falls back to the higher direction when there is no base', () => {
  const row = translateRoadLimit(
    way({ highway: 'primary', 'maxspeed:forward': '90', 'maxspeed:backward': '70' }),
    'LT'
  )

  assertEquals(row?.limit_kph, 90)
  assertEquals(row?.backward_limit_kph, 70)
})

Deno.test('translateRoadLimit discards a backward limit on a one-way road', () => {
  const row = translateRoadLimit(
    way({ highway: 'motorway_link', maxspeed: '90', 'maxspeed:backward': '70', oneway: 'yes' }),
    'LT'
  )

  assertEquals(row?.limit_kph, 90)
  assertEquals(row?.backward_limit_kph, null, 'nobody can legally drive that direction')
})

// ---------------------------------------------------------------------------
// What counts as a road
// ---------------------------------------------------------------------------

Deno.test('translateRoadLimit needs a highway tag and real geometry', () => {
  assertEquals(translateRoadLimit(way({ maxspeed: '90' }), 'LT'), null)
  assertEquals(
    translateRoadLimit({ type: 'node', id: 1, tags: { highway: 'primary', maxspeed: '90' } }, 'LT'),
    null
  )
  assertEquals(
    translateRoadLimit(way({ highway: 'primary', maxspeed: '90' }, [point(24.0)]), 'LT'),
    null
  )
})

// A stub between two junctions cannot be told apart from the roads either side
// of it by a receiver with 5 m of error.
Deno.test('translateRoadLimit drops a way too short to match against', () => {
  const tenMetres = [point(24.0), point(24.0, LAT + 0.00009)]
  assertEquals(translateRoadLimit(way({ highway: 'residential', maxspeed: '30' }, tenMetres), 'LT'), null)
})

// Driveways and parking aisles are routinely tagged maxspeed=10, and a car
// crossing a supermarket car park at 30 is not speeding. Being told so would
// teach the driver that limit alerts are noise.
Deno.test('the query asks only for highway values a car can be ticketed on', () => {
  for (const excluded of ['service', 'track', 'footway', 'cycleway', 'path', 'pedestrian']) {
    assert(
      !DRIVABLE_HIGHWAY_VALUES.includes(excluded),
      `${excluded} is not a road a speed limit alert should fire on`
    )
  }
  for (const included of ['motorway', 'trunk', 'primary', 'residential', 'living_street']) {
    assert(DRIVABLE_HIGHWAY_VALUES.includes(included), `${included} is missing`)
  }
})

// Both filters, which sounds redundant and is not: the bbox keeps one answer
// small enough to arrive at all, the area filter stops a border tile filing the
// neighbouring country's roads under the wrong dataset.
Deno.test('the tile query constrains by both country area and bounding box', () => {
  const query = roadLimitQuery('LT', { minLat: 54, minLon: 24, maxLat: 54.25, maxLon: 24.25 })

  assert(query.includes('"ISO3166-1"="LT"'))
  assert(query.includes('(area.country)'))
  assert(query.includes('54,24,54.25,24.25'))
  assert(query.includes('out geom'))
})

// ---------------------------------------------------------------------------
// Simplification
// ---------------------------------------------------------------------------

Deno.test('simplifyPolyline collapses a straight road to its endpoints', () => {
  const straight = Array.from({ length: 50 }, (_, i) => point(24 + i * 0.001))
  assertEquals(simplifyPolyline(straight, 8).length, 2)
})

Deno.test('simplifyPolyline keeps a corner', () => {
  const corner = [point(24.0), point(24.01), point(24.01, LAT + 0.01)]
  assertEquals(simplifyPolyline(corner, 8).length, 3)
})

// The tolerance is what decides how far the stored road may sit from the real
// one, and it has to stay well under the 30 m corridor the phone matches with.
// Simplifying anywhere near the corridor would let a bend drift far enough to
// hand the driver the limit from the road they are not on.
//
// A hundredth of a degree of latitude is about 1.1 km, so 0.00005 is roughly
// 5.5 m of deviation and 0.0002 is roughly 22 m.
Deno.test('simplifyPolyline drops a wobble under the tolerance and keeps a real bend', () => {
  const wobble = [point(24.0), point(24.005, LAT + 0.00005), point(24.01)]
  assertEquals(simplifyPolyline(wobble, 8).length, 2, '5.5 m cannot change which road you are on')

  const bend = [point(24.0), point(24.005, LAT + 0.0002), point(24.01)]
  assertEquals(simplifyPolyline(bend, 8).length, 3, '22 m is most of the matching corridor')
})

Deno.test('simplifyPolyline does not shortcut across a bend', () => {
  const bend = [point(24.0), point(24.005, LAT + 0.0002), point(24.01)]
  const before = polylineLength(bend)
  const after = polylineLength(simplifyPolyline(bend, 8))

  // A shortened road is a different road: distances along it stop lining up
  // with the ground, and the far end drifts out of its own corridor.
  assert(before - after < 1, `simplification lost ${before - after} m`)
})

Deno.test('simplifyPolyline leaves short inputs alone', () => {
  assertEquals(simplifyPolyline([point(24.0), point(24.01)], 8).length, 2)
  assertEquals(simplifyPolyline([point(24.0)], 8).length, 1)
  assertEquals(simplifyPolyline([], 8).length, 0)
})

// ---------------------------------------------------------------------------
// Tiling
// ---------------------------------------------------------------------------

const lithuania: BoundingBox = { minLat: 53.9, minLon: 20.9, maxLat: 56.45, maxLon: 26.85 }

// The regression this guards. Accumulating `lat += step` drifts over the forty
// or so steps a country needs, and the drift is enough to leave a sliver of the
// north or east edge uncovered - a stripe of the country with no speed limits
// and nothing to say so.
Deno.test('boundingBoxTiles reaches every edge of the box', () => {
  const tiles = boundingBoxTiles(lithuania, 0.25)

  assertAlmostEquals(Math.min(...tiles.map((t) => t.minLat)), lithuania.minLat, 1e-9)
  assertAlmostEquals(Math.min(...tiles.map((t) => t.minLon)), lithuania.minLon, 1e-9)
  assertAlmostEquals(Math.max(...tiles.map((t) => t.maxLat)), lithuania.maxLat, 1e-9)
  assertAlmostEquals(Math.max(...tiles.map((t) => t.maxLon)), lithuania.maxLon, 1e-9)
})

Deno.test('boundingBoxTiles leaves no gap between tiles', () => {
  const tiles = boundingBoxTiles({ minLat: 54, minLon: 24, maxLat: 54.5, maxLon: 24.5 }, 0.25)

  assertEquals(tiles.length, 4)
  // Each tile's far edge is the next one's near edge, so nothing falls between.
  const latEdges = [...new Set(tiles.flatMap((t) => [t.minLat, t.maxLat]))].sort((a, b) => a - b)
  assertEquals(latEdges, [54, 54.25, 54.5])
})

// The resume checkpoint is keyed on this. Two different tiles sharing a key
// would silently skip one of them on a resumed run, which is the one failure
// mode that produces a dataset with holes and no sign of them.
Deno.test('tileKey is unique per tile', () => {
  const tiles = boundingBoxTiles(lithuania, 0.25)
  assertEquals(new Set(tiles.map(tileKey)).size, tiles.length)
})
