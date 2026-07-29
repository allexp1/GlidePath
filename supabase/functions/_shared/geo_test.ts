import { assertAlmostEquals, assertEquals } from 'jsr:@std/assert@^1'
import { distanceMeters, stitchWays } from './geo.ts'
import type { LatLon } from './geo.ts'

// Lithuania, where the relations that prompted these tests live. At this
// latitude a hundredth of a degree of longitude is about 650 m, which is enough
// to clear the 500 m floor with two ways.
const LAT = 54.5

const point = (lon: number): LatLon => ({ lat: LAT, lon })

/** A two-point way from one longitude to another. */
const leg = (fromLon: number, toLon: number): LatLon[] => [point(fromLon), point(toLon)]

Deno.test('stitchWays joins ways that are already in order', () => {
  const path = stitchWays([leg(24.00, 24.01), leg(24.01, 24.02)])

  assertEquals(path.length, 3)
  assertAlmostEquals(path[0].lon, 24.00, 1e-9)
  assertAlmostEquals(path[2].lon, 24.02, 1e-9)
})

// The regression this file exists for. Relation members come back in whatever
// order the mapper added them, so the first way is often in the middle of the
// section. Growing the chain only forwards stopped at the gap behind it and
// returned a fragment - one real Lithuanian section measured 500 m of its 3 km.
Deno.test('stitchWays grows backwards when the first way is not the start', () => {
  const path = stitchWays([leg(24.01, 24.02), leg(24.00, 24.01)])

  assertEquals(path.length, 3)
  assertAlmostEquals(path[0].lon, 24.00, 1e-9)
  assertAlmostEquals(path[2].lon, 24.02, 1e-9)
})

Deno.test('stitchWays grows in both directions at once', () => {
  // Middle first, then the two ends, then one more at each end.
  const path = stitchWays([
    leg(24.02, 24.03),
    leg(24.04, 24.05),
    leg(24.00, 24.01),
    leg(24.03, 24.04),
    leg(24.01, 24.02)
  ])

  assertEquals(path.length, 6)
  assertAlmostEquals(path[0].lon, 24.00, 1e-9)
  assertAlmostEquals(path[5].lon, 24.05, 1e-9)
})

Deno.test('stitchWays flips a way digitised against the direction of travel', () => {
  // The second way runs backwards: its own start is the far end.
  const path = stitchWays([leg(24.00, 24.01), leg(24.02, 24.01)])

  assertEquals(path.length, 3)
  assertAlmostEquals(path[0].lon, 24.00, 1e-9)
  assertAlmostEquals(path[2].lon, 24.02, 1e-9)
})

Deno.test('stitchWays stops at a real gap rather than jumping it', () => {
  // A kilometre of nothing between the two. Bridging it would invent road.
  const path = stitchWays([leg(24.00, 24.01), leg(24.20, 24.21)])

  assertEquals(path.length, 2)
  assertAlmostEquals(path[1].lon, 24.01, 1e-9)
})

Deno.test('stitchWays measures the full length once the order is fixed', () => {
  const scrambled = stitchWays([leg(24.01, 24.02), leg(24.00, 24.01)])
  const straight = distanceMeters(point(24.00), point(24.02))

  // Within a metre of the straight-line distance, since the legs are collinear.
  assertAlmostEquals(
    scrambled.reduce(
      (total, current, index) => index === 0 ? 0 : total + distanceMeters(scrambled[index - 1], current),
      0
    ),
    straight,
    1
  )
})

Deno.test('stitchWays ignores ways too short to have a direction', () => {
  assertEquals(stitchWays([]).length, 0)
  assertEquals(stitchWays([[point(24.0)]]).length, 0)
})
