#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read
/**
 * Loads camera data for one country into your Supabase project.
 *
 *   deno run --allow-net --allow-env --allow-read seed.ts israel
 *   deno run --allow-net --allow-env --allow-read seed.ts moldova --dry-run
 *
 * Or from the repository root, which is what the README tells people:
 *
 *   make seed              both countries
 *   make seed-israel
 *   make seed-moldova
 *   make seed-dry-run      fetch and translate, write nothing
 *
 * Reads SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from supabase/.env. It runs
 * exactly the same code as the nightly Edge Function, so what you see locally
 * is what the schedule will do.
 */

import { createClient } from 'npm:@supabase/supabase-js@2'
import { load } from 'jsr:@std/dotenv@0.225'
import { syncCountry } from '../functions/_shared/sync.ts'
import type { DatabaseClient, ManualZone } from '../functions/_shared/sync.ts'

interface Target {
  code: string
  iso: string
  name: string
  /** Hand-maintained sections, relative to this file. */
  manualZonesFile?: string
}

const TARGETS: Record<string, Target> = {
  israel: {
    code: 'IL',
    iso: 'IL',
    name: 'Israel',
    // 250 new average-speed cameras across 125 sections, enforcement from
    // Q3 2026. OpenStreetMap will not have these for a while, so they are
    // maintained by hand from police announcements.
    manualZonesFile: './israel_zones.json'
  },
  moldova: {
    code: 'MD',
    iso: 'MD',
    name: 'Moldova'
  }
}

async function main(): Promise<number> {
  const args = [...Deno.args]
  const dryRun = args.includes('--dry-run')
  const name = args.find((arg) => !arg.startsWith('--'))

  if (!name || !(name in TARGETS)) {
    console.error(`Usage: seed.ts <${Object.keys(TARGETS).join('|')}> [--dry-run]`)
    return 2
  }

  const target = TARGETS[name]

  // The Makefile runs this from supabase/seed, so ../.env is supabase/.env.
  await load({ envPath: '../.env', export: true })

  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!url || !key) {
    console.error(
      'SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.\n' +
        'Copy supabase/.env.example to supabase/.env and fill them in.'
    )
    return 1
  }

  let manualZones: ManualZone[] = []
  if (target.manualZonesFile) {
    manualZones = await readManualZones(target.manualZonesFile)
    console.log(`Loaded ${manualZones.length} hand-maintained ${target.name} sections`)
  }

  const client = createClient(url, key, { auth: { persistSession: false } })

  console.log(`Seeding ${target.name} (${target.code})${dryRun ? ' - dry run' : ''}`)
  console.log('Overpass queries can take a couple of minutes. This is normal.')

  const report = await syncCountry(client as unknown as DatabaseClient, target.code, target.iso, {
    dryRun,
    manualZones,
    log: (message) => console.log(`  ${message}`)
  })

  console.log('')
  console.log(`  point cameras     ${report.cameras}`)
  console.log(`  zones from OSM    ${report.zones}`)
  console.log(`  zones from file   ${report.manualZones}`)
  console.log(`  rest stops        ${report.restStops}`)
  console.log(`  dataset version   ${report.datasetVersion ?? '(unchanged, dry run)'}`)

  if (report.warnings.length > 0) {
    console.log('')
    console.log(`  ${report.warnings.length} warning(s):`)
    for (const warning of report.warnings.slice(0, 20)) {
      console.log(`    - ${warning}`)
    }
    if (report.warnings.length > 20) {
      console.log(`    ... and ${report.warnings.length - 20} more`)
    }
  }

  if (!dryRun && report.cameras === 0 && report.zones === 0 && report.manualZones === 0) {
    console.error('')
    console.error('Nothing was loaded. Check the Overpass output above before shipping this.')
    return 1
  }

  return 0
}

async function readManualZones(path: string): Promise<ManualZone[]> {
  try {
    const raw = await Deno.readTextFile(new URL(path, import.meta.url))
    const parsed = JSON.parse(raw)
    const zones = Array.isArray(parsed) ? parsed : parsed.zones

    if (!Array.isArray(zones)) {
      throw new Error('expected an array of zones, or an object with a "zones" array')
    }
    return zones as ManualZone[]
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) {
      console.log(`No ${path} yet, continuing with OpenStreetMap data only`)
      return []
    }
    throw new Error(`could not read ${path}: ${error instanceof Error ? error.message : error}`)
  }
}

Deno.exit(await main())
