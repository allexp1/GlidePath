import { assert, assertEquals } from 'jsr:@std/assert@^1'
import type { LatLon } from './geo.ts'
import type { OverpassElement, OverpassMember } from './overpass.ts'
import { cameraTypeFromTags, translateAverageSpeedZone, zoneRejectionReason } from './translate.ts'

// Modelled on relation/11193030 and relation/12419066 in Lithuania, which is
// where every rule in here came from.
const LAT = 54.5
const point = (lon: number): LatLon => ({ lat: LAT, lon })

const sectionWay = (ref: number, fromLon: number, toLon: number): OverpassMember => ({
  type: 'way',
  ref,
  role: 'section',
  geometry: [point(fromLon), point(toLon)]
})

const node = (ref: number, role: string, lon: number): OverpassMember => ({
  type: 'node',
  ref,
  role,
  lat: LAT,
  lon
})

/**
 * A section from 24.00 to 24.02, roughly 1.3 km at this latitude, with cameras
 * just inside each end. `from`/`to` mark travel as west to east unless swapped.
 */
function relation(options: {
  tags?: Record<string, string>
  members?: OverpassMember[]
} = {}): OverpassElement {
  return {
    type: 'relation',
    id: 11193030,
    tags: { type: 'enforcement', enforcement: 'average_speed', ...(options.tags ?? {}) },
    members: options.members ?? [
      node(1, 'from', 24.000),
      node(2, 'device', 24.001),
      node(3, 'device', 24.019),
      node(4, 'to', 24.020),
      sectionWay(10, 24.00, 24.01),
      sectionWay(11, 24.01, 24.02)
    ]
  }
}

const tagged = (...pairs: [number, string][]): Map<number, Record<string, string>> =>
  new Map(pairs.map(([ref, maxspeed]) => [ref, { maxspeed }]))

// ---------------------------------------------------------------------------
// The role
// ---------------------------------------------------------------------------

// Every one of Lithuania's 182 sections puts its road ways under role
// "section", which the translator did not accept. 1100 ways carrying geometry
// were being ignored, so no section had any road to measure.
Deno.test('the section role carries the road', () => {
  const zone = translateAverageSpeedZone(relation({ tags: { maxspeed: '90' } }), 'LT')

  assert(zone !== null, 'a section-role relation should produce a zone')
  assertEquals(zone.speed_limit_kph, 90)
  assert(zone.measured, 'geometry was present, so the zone is measured')
  assert(zone.distance_meters > 500, `expected over 500 m, got ${zone.distance_meters}`)
})

// ---------------------------------------------------------------------------
// Where the limit comes from
// ---------------------------------------------------------------------------

Deno.test('the limit is read off the road when the relation has none', () => {
  const zone = translateAverageSpeedZone(relation(), 'LT', tagged([10, '90'], [11, '90']))

  assert(zone !== null, '164 of 182 Lithuanian sections depend on this path')
  assertEquals(zone.speed_limit_kph, 90)
})

Deno.test('the relation wins when it states a limit of its own', () => {
  const zone = translateAverageSpeedZone(
    relation({ tags: { maxspeed: '70' } }),
    'LT',
    tagged([10, '90'], [11, '90'])
  )

  assertEquals(zone?.speed_limit_kph, 70)
})

// Refusing rather than picking one. The lowest would be safe against a fine but
// would show a number contradicting the signs for most of the drive; the highest
// could earn one.
Deno.test('road ways that disagree produce no zone', () => {
  const wayTags = tagged([10, '90'], [11, '70'])

  assertEquals(translateAverageSpeedZone(relation(), 'LT', wayTags), null)

  const reason = zoneRejectionReason(relation(), wayTags)
  assert(reason?.includes('disagree'), `expected a disagreement, got: ${reason}`)
  assert(reason?.includes('70'), 'the reason should name the limits it saw')
})

Deno.test('a road way with no limit at all produces no zone', () => {
  const wayTags = tagged([10, '90'])

  assertEquals(translateAverageSpeedZone(relation(), 'LT', wayTags), null)

  const reason = zoneRejectionReason(relation(), wayTags)
  assert(reason?.includes('1 of its 2 road ways'), `expected a count, got: ${reason}`)
})

Deno.test('no limit anywhere produces no zone', () => {
  assertEquals(translateAverageSpeedZone(relation(), 'LT'), null)
})

// ---------------------------------------------------------------------------
// Which way round the section runs
// ---------------------------------------------------------------------------

// relation/11193030 lists its ways so that the stitched path runs against
// travel. Getting this wrong swaps entry and exit, and the app then coaches
// towards the camera the driver has already gone past.
Deno.test('entry and exit follow from and to, not the order of the ways', () => {
  const eastbound = translateAverageSpeedZone(relation({ tags: { maxspeed: '90' } }), 'LT')
  assert(eastbound !== null)
  assert(
    eastbound.entry.lon < eastbound.exit.lon,
    `from is west of to, so entry should be too: ${eastbound.entry.lon} vs ${eastbound.exit.lon}`
  )

  // The same road with the markers swapped is the other carriageway, and every
  // Lithuanian section is mapped as two relations for exactly that reason.
  const westbound = translateAverageSpeedZone(
    relation({
      tags: { maxspeed: '90' },
      members: [
        node(1, 'to', 24.000),
        node(2, 'device', 24.001),
        node(3, 'device', 24.019),
        node(4, 'from', 24.020),
        sectionWay(10, 24.00, 24.01),
        sectionWay(11, 24.01, 24.02)
      ]
    }),
    'LT'
  )
  assert(westbound !== null)
  assert(
    westbound.entry.lon > westbound.exit.lon,
    `from is east of to, so entry should be too: ${westbound.entry.lon} vs ${westbound.exit.lon}`
  )
})

Deno.test('the two directions of one section get opposite bearings', () => {
  const east = translateAverageSpeedZone(relation({ tags: { maxspeed: '90' } }), 'LT')
  const west = translateAverageSpeedZone(
    relation({
      tags: { maxspeed: '90' },
      members: [
        node(1, 'to', 24.000),
        node(2, 'device', 24.001),
        node(3, 'device', 24.019),
        node(4, 'from', 24.020),
        sectionWay(10, 24.00, 24.01),
        sectionWay(11, 24.01, 24.02)
      ]
    }),
    'LT'
  )

  const difference = Math.abs((east?.direction_degrees ?? 0) - (west?.direction_degrees ?? 0))
  assertEquals(Math.round(difference), 180)
})

// ---------------------------------------------------------------------------
// Reasons
// ---------------------------------------------------------------------------

Deno.test('a usable relation has no rejection reason', () => {
  assertEquals(zoneRejectionReason(relation({ tags: { maxspeed: '90' } })), null)
})

Deno.test('the reason names the roles it found when none of them is a road', () => {
  const reason = zoneRejectionReason(
    relation({
      tags: { maxspeed: '90' },
      members: [
        node(2, 'device', 24.001),
        node(3, 'device', 24.019),
        { type: 'way', ref: 10, role: 'unexpected', geometry: [point(24.0), point(24.01)] }
      ]
    })
  )

  assert(reason?.includes('unexpected'), `the role should be quoted back: ${reason}`)
})

Deno.test('a section under the floor says how long it actually was', () => {
  const reason = zoneRejectionReason(
    relation({
      tags: { maxspeed: '90' },
      members: [
        node(1, 'from', 24.0000),
        node(2, 'device', 24.0001),
        node(3, 'device', 24.0009),
        node(4, 'to', 24.0010),
        sectionWay(10, 24.0, 24.001)
      ]
    })
  )

  assert(reason?.includes('500 m floor'), `expected the floor to be named: ${reason}`)
})

// ---------------------------------------------------------------------------
// What counts as a camera worth warning about
// ---------------------------------------------------------------------------

// An automatic plate reader photographs every plate so the number can be looked
// up later. It measures no speed and issues no speeding ticket, so warning at
// one teaches the driver that these warnings mean nothing.
//
// The numbers are why this is a rule and not a nicety: New York has 111 nodes
// tagged highway=speed_camera and 3,788 tagged as ALPR surveillance. Letting the
// surveillance fallback swallow those would fire ~3,800 false warnings across
// one state.
Deno.test('a plate reader is not a speed camera', () => {
  assertEquals(
    cameraTypeFromTags({
      'man_made': 'surveillance',
      'surveillance:zone': 'traffic',
      'surveillance:type': 'ALPR',
      'manufacturer': 'Flock Safety'
    }),
    null
  )
})

// A mapper asserting enforcement=maxspeed outranks our inference from the
// hardware type. Cameras really do read plates in order to enforce speed.
Deno.test('a plate reader that a mapper says enforces speed is still a camera', () => {
  assertEquals(
    cameraTypeFromTags({
      'man_made': 'surveillance',
      'surveillance:zone': 'traffic',
      'surveillance:type': 'ALPR',
      'enforcement': 'maxspeed'
    }),
    'fixed'
  )
})

// The fallback still has to work for what it was written for: an ambiguous
// traffic-zone camera with no type given at all.
Deno.test('an untyped traffic surveillance camera is still treated as fixed', () => {
  assertEquals(
    cameraTypeFromTags({ 'man_made': 'surveillance', 'surveillance:zone': 'traffic' }),
    'fixed'
  )
})

Deno.test('an ordinary speed camera is unaffected', () => {
  assertEquals(cameraTypeFromTags({ 'highway': 'speed_camera' }), 'fixed')
})
