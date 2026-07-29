/**
 * Why did a country load nothing?
 *
 *     deno run --allow-net --allow-read inspect.ts LT
 *
 * Runs exactly the queries the seeder runs and puts every element through
 * exactly the same translation functions, then reports what was rejected and
 * why. Read-only: it needs no credentials and writes nothing.
 *
 * This exists because "translated 0 cameras, 0 zones" plus a wall of identical
 * warnings tells you something is wrong and nothing about what. OpenStreetMap
 * tagging is a convention rather than a schema, so the interesting question is
 * always "what shape is the data actually in", and that has to be answered from
 * the real data rather than from the wiki.
 */

import { stitchWays } from '../functions/_shared/geo.ts'
import type { LatLon } from '../functions/_shared/geo.ts'
import {
  averageSpeedZoneQuery,
  pointCameraQuery,
  runOverpassQuery
} from '../functions/_shared/overpass.ts'
import type { OverpassElement } from '../functions/_shared/overpass.ts'
import {
  parseMaxspeed,
  translateAverageSpeedZone,
  translatePointCamera
} from '../functions/_shared/translate.ts'

const SAMPLE_RELATIONS = 2
const MEMBERS_PER_SAMPLE = 14
const TOP_N = 12

async function main(): Promise<number> {
  const requested = Deno.args.find((arg) => !arg.startsWith('--'))
  if (!requested || !/^[A-Za-z]{2}$/.test(requested)) {
    console.error('Usage: inspect.ts <ISO 3166-1 alpha-2 code>')
    console.error('  e.g. deno run --allow-net --allow-read inspect.ts LT')
    return 2
  }
  const iso = requested.toUpperCase()

  console.log(`Inspecting ${iso}. Overpass queries can take a couple of minutes.`)

  await inspectPointCameras(iso)
  await inspectZones(iso)

  return 0
}

// ---------------------------------------------------------------------------
// Point cameras
// ---------------------------------------------------------------------------

async function inspectPointCameras(iso: string): Promise<void> {
  heading(`${iso} point cameras`)

  let elements: OverpassElement[]
  try {
    elements = (await runOverpassQuery(pointCameraQuery(iso))).elements
  } catch (error) {
    console.log(`  query failed: ${error instanceof Error ? error.message : String(error)}`)
    return
  }

  const nodes = elements.filter((element) => element.type === 'node')
  const accepted: OverpassElement[] = []
  const rejected: OverpassElement[] = []
  const acceptedTypes = new Map<string, number>()

  for (const node of nodes) {
    const row = translatePointCamera(node, iso)
    if (row) {
      accepted.push(node)
      bump(acceptedTypes, row.type)
    } else {
      rejected.push(node)
    }
  }

  stat('elements returned', elements.length)
  stat('nodes', nodes.length)
  stat('accepted', accepted.length)
  stat('rejected', rejected.length)

  if (acceptedTypes.size > 0) {
    console.log('')
    console.log('  accepted by type:')
    for (const [type, count] of sorted(acceptedTypes)) console.log(`    ${count.toString().padStart(6)}  ${type}`)
  }

  // The interesting case: nodes the area query matched but the translator threw
  // away. Whatever tags dominate here are the tags the translator should learn.
  if (rejected.length > 0) {
    console.log('')
    console.log('  tags on rejected nodes:')
    tally(rejected, ['highway', 'man_made', 'enforcement', 'surveillance', 'surveillance:type', 'surveillance:zone'])
  }

  if (nodes.length === 0) {
    console.log('')
    console.log('  Nothing came back at all. Either the area filter found no country')
    console.log(`  boundary tagged ISO3166-1=${iso} with admin_level=2, or this country`)
    console.log('  genuinely has no camera nodes mapped. The relation count below')
    console.log('  distinguishes the two: relations use the same area filter.')
  }
}

// ---------------------------------------------------------------------------
// Average-speed sections
// ---------------------------------------------------------------------------

/** Mirrors the rejection order inside translateAverageSpeedZone. */
function rejectionReason(relation: OverpassElement): string | null {
  if (relation.type !== 'relation' || !relation.members) return 'not a relation with members'

  const tags = relation.tags ?? {}
  if (!tags.maxspeed) return 'no maxspeed tag'
  if (!parseMaxspeed(tags.maxspeed)) return `maxspeed unparseable (${tags.maxspeed})`

  const roadWays = relation.members
    .filter((m) => m.type === 'way' && (m.role === '' || m.role === 'road') && m.geometry)
    .map((m) => m.geometry as LatLon[])
  const path = stitchWays(roadWays)
  const devices = relation.members.filter((m) => m.role === 'device').length

  if (path.length < 2) {
    const waysWithGeometry = relation.members.filter((m) => m.type === 'way' && m.geometry).length
    if (roadWays.length === 0 && waysWithGeometry > 0) {
      return `no way has role "" or "road" (${waysWithGeometry} ways carry geometry under other roles)`
    }
    if (waysWithGeometry === 0) return 'no member way came back with geometry'
    return `road ways would not stitch into one path (${roadWays.length} ways)`
  }

  if (devices < 2) return `only ${devices} device member(s)`
  return null
}

async function inspectZones(iso: string): Promise<void> {
  heading(`${iso} average-speed relations`)

  let elements: OverpassElement[]
  try {
    elements = (await runOverpassQuery(averageSpeedZoneQuery(iso))).elements
  } catch (error) {
    console.log(`  query failed: ${error instanceof Error ? error.message : String(error)}`)
    return
  }

  const relations = elements.filter((element) => element.type === 'relation')
  const rejects = relations.filter((relation) => translateAverageSpeedZone(relation, iso) === null)

  stat('relations returned', relations.length)
  stat('accepted', relations.length - rejects.length)
  stat('rejected', rejects.length)

  const reasons = new Map<string, number>()
  const roles = new Map<string, number>()
  const maxspeeds = new Map<string, number>()

  for (const relation of rejects) {
    const reason = rejectionReason(relation)
    // A null reason here means the two functions disagree, which is a bug in
    // this file rather than in the data. Say so rather than hiding it.
    bump(reasons, reason ?? 'no reason found - rejectionReason is out of sync with the translator')

    bump(maxspeeds, relation.tags?.maxspeed ?? '(absent)')
    for (const member of relation.members ?? []) {
      const position = member.geometry ? 'geom' : member.lat !== undefined ? 'lat/lon' : 'no position'
      bump(roles, `${member.role === '' ? '(empty)' : member.role} / ${member.type} / ${position}`)
    }
  }

  if (reasons.size > 0) {
    console.log('')
    console.log('  rejected because:')
    for (const [reason, count] of sorted(reasons)) console.log(`    ${count.toString().padStart(6)}  ${reason}`)

    console.log('')
    console.log('  member roles across rejected relations:')
    for (const [role, count] of sorted(roles).slice(0, TOP_N)) console.log(`    ${count.toString().padStart(6)}  ${role}`)

    console.log('')
    console.log('  maxspeed values on rejected relations:')
    for (const [value, count] of sorted(maxspeeds).slice(0, TOP_N)) console.log(`    ${count.toString().padStart(6)}  ${value}`)
  }

  // A trimmed sample, because a role histogram cannot show whether the ways are
  // actually contiguous and the tags cannot show how long the section is.
  for (const relation of rejects.slice(0, SAMPLE_RELATIONS)) {
    console.log('')
    console.log(`  sample relation/${relation.id}`)
    console.log(`    tags: ${JSON.stringify(relation.tags ?? {})}`)

    const members = relation.members ?? []
    for (const member of members.slice(0, MEMBERS_PER_SAMPLE)) {
      const points = member.geometry?.length ?? 0
      const first = member.geometry?.[0]
      const last = member.geometry?.[points - 1]
      let where = ''
      if (first && last) {
        where = ` ${fmt(first)} -> ${fmt(last)}`
      } else if (member.lat !== undefined && member.lon !== undefined) {
        where = ` ${fmt({ lat: member.lat, lon: member.lon })}`
      }
      console.log(`    ${member.type}/${member.ref} role="${member.role}" points=${points}${where}`)
    }

    const hidden = members.length - MEMBERS_PER_SAMPLE
    if (hidden > 0) console.log(`    ... and ${hidden} more members`)
  }
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function heading(title: string): void {
  console.log('')
  console.log(`== ${title} ==`)
}

function stat(label: string, value: number): void {
  console.log(`  ${label.padEnd(26)} ${value.toString().padStart(6)}`)
}

function bump(counter: Map<string, number>, key: string): void {
  counter.set(key, (counter.get(key) ?? 0) + 1)
}

function sorted(counter: Map<string, number>): [string, number][] {
  return [...counter.entries()].sort((a, b) => b[1] - a[1])
}

function fmt(point: LatLon): string {
  return `${point.lat.toFixed(4)},${point.lon.toFixed(4)}`
}

/**
 * Which tag combinations dominate a set of nodes. Only the keys that matter for
 * classification, so the output stays readable: names and operator refs would
 * bury the signal.
 */
function tally(nodes: OverpassElement[], keys: string[]): void {
  const combinations = new Map<string, number>()
  for (const node of nodes) {
    const tags = node.tags ?? {}
    const present = keys
      .filter((key) => tags[key] !== undefined)
      .map((key) => `${key}=${tags[key]}`)
    bump(combinations, present.length > 0 ? present.join(' ') : '(none of the classifying tags)')
  }
  for (const [combination, count] of sorted(combinations).slice(0, TOP_N)) {
    console.log(`    ${count.toString().padStart(6)}  ${combination}`)
  }
}

Deno.exit(await main())
