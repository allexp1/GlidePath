#!/usr/bin/env node
//
// Regenerates the GPX fixture used by GPXDriveTests.
//
//     node scripts/generate-test-gpx.mjs
//
// The track is a straight eastbound run through a 6 km test zone at 32.0/34.8,
// driven at 120 km/h for the first half and 70 km/h for the second. With a
// 90 km/h limit that is an early overspeed the driver recovers from, which
// exercises the normal -> tight -> normal path and finishes under the average.
//
// The spherical offset here mirrors Coordinate.offset(meters:bearingDegrees:)
// in the Swift package, so fixture positions and engine geometry agree.

import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const EARTH_RADIUS_M = 6371008.8
const toRad = (deg) => (deg * Math.PI) / 180
const toDeg = (rad) => (rad * 180) / Math.PI

function offset(lat, lon, meters, bearingDeg) {
  const angular = meters / EARTH_RADIUS_M
  const bearing = toRad(bearingDeg)
  const lat1 = toRad(lat)
  const lon1 = toRad(lon)

  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(angular) + Math.cos(lat1) * Math.sin(angular) * Math.cos(bearing)
  )
  const lon2 =
    lon1 +
    Math.atan2(
      Math.sin(bearing) * Math.sin(angular) * Math.cos(lat1),
      Math.cos(angular) - Math.sin(lat1) * Math.sin(lat2)
    )

  return [toDeg(lat2), toDeg(lon2)]
}

const ORIGIN_LAT = 32.0
const ORIGIN_LON = 34.8
const START_EPOCH = 1780000000 // matches TestFixtures.referenceDate
const SAMPLE_INTERVAL_S = 1

// distance is measured from the zone entry line, so the lead-in is negative.
const legs = [
  { speedKph: 120, distanceM: 300 }, // approach, before the entry camera
  { speedKph: 120, distanceM: 3000 }, // first half of the zone, over the limit
  { speedKph: 70, distanceM: 3000 }, // second half, obeying the coaching
  { speedKph: 70, distanceM: 200 } // run-out, past the exit camera
]

const points = []
let distance = -legs[0].distanceM
let time = START_EPOCH

for (const leg of legs) {
  const speedMps = leg.speedKph / 3.6
  const step = speedMps * SAMPLE_INTERVAL_S
  let covered = 0

  while (covered < leg.distanceM) {
    points.push({ distance, time, speedMps })
    const advance = Math.min(step, leg.distanceM - covered)
    distance += advance
    covered += advance
    time += advance / speedMps
  }
}

const trkpts = points
  .map(({ distance: d, time: t, speedMps }) => {
    const [lat, lon] = offset(ORIGIN_LAT, ORIGIN_LON, d, 90)
    const stamp = new Date(t * 1000).toISOString().replace(/\.\d{3}Z$/, (m) => m)
    return [
      `    <trkpt lat="${lat.toFixed(8)}" lon="${lon.toFixed(8)}">`,
      `      <time>${stamp}</time>`,
      `      <speed>${speedMps.toFixed(4)}</speed>`,
      '    </trkpt>'
    ].join('\n')
  })
  .join('\n')

const gpx = `<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="Zonexplo scripts/generate-test-gpx.mjs" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <name>Zonexplo test zone drive</name>
    <desc>6 km eastbound section, 90 km/h limit. 3 km at 120 then 3 km at 70.</desc>
  </metadata>
  <trk>
    <name>test-zone-drive</name>
    <trkseg>
${trkpts}
    </trkseg>
  </trk>
</gpx>
`

const here = dirname(fileURLToPath(import.meta.url))
const target = join(
  here,
  '..',
  'ios',
  'Packages',
  'ZonexploCore',
  'Tests',
  'ZonexploCoreTests',
  'Fixtures',
  'test_zone_drive.gpx'
)

mkdirSync(dirname(target), { recursive: true })
writeFileSync(target, gpx)

console.log(`Wrote ${points.length} track points to ${target}`)
