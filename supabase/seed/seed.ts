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

// Bare specifiers, mapped in deno.json. The Edge Function keeps its explicit
// npm:/jsr: prefixes because Supabase's runtime resolves those directly and
// never sees this config.
import { createClient } from '@supabase/supabase-js'
import { load } from '@std/dotenv'
import { syncCountry } from '../functions/_shared/sync.ts'
import type { DatabaseClient, ManualZone } from '../functions/_shared/sync.ts'

interface Target {
  code: string
  iso: string
  name: string
  /** Hand-maintained sections, relative to this file. */
  manualZonesFile?: string
}

/// Friendly names for the countries that need something beyond their ISO code -
/// currently just a manual zones file. Everything else is reachable by code.
const ALIASES: Record<string, Target> = {
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
  },
  lithuania: {
    code: 'LT',
    iso: 'LT',
    name: 'Lithuania'
    // No manual file: Lithuania's average-speed sections have been in place
    // long enough to be mapped as proper enforcement relations, so Overpass
    // should supply both the cameras and the zones.
  }
}

async function main(): Promise<number> {
  const args = [...Deno.args]
  const dryRun = args.includes('--dry-run')
  const requested = args.find((arg) => !arg.startsWith('--'))

  if (!requested) {
    console.error('Usage: seed.ts <country> [--dry-run]')
    console.error('')
    console.error(`  <country> is an ISO 3166-1 alpha-2 code (LT, FR, PL) or one of:`)
    console.error(`  ${Object.keys(ALIASES).join(', ')}`)
    return 2
  }

  // The Makefile runs this from supabase/seed, so ../.env is supabase/.env.
  await load({ envPath: '../.env', export: true })

  const credentials = readCredentials()
  if (!credentials) return 1
  const { url, key } = credentials

  const client = createClient(url, key, { auth: { persistSession: false } })

  const target = await resolveTarget(client, requested)
  if (!target) return 2

  let manualZones: ManualZone[] = []
  if (target.manualZonesFile) {
    manualZones = await readManualZones(target.manualZonesFile)
    console.log(`Loaded ${manualZones.length} hand-maintained ${target.name} sections`)
  }

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

  if (!dryRun) {
    console.log('')
    console.log(`  ${target.name} is now downloadable in the app.`)
    console.log('  To also keep it refreshed by the nightly job, run once:')
    console.log(`    update public.countries set sync_enabled = true where code = '${target.code}';`)
  }

  return 0
}

/**
 * Turns whatever was on the command line into a country to sync.
 *
 * An alias wins if there is one, because aliases carry the extra configuration
 * a bare code cannot. Otherwise a two-letter code is looked up in the countries
 * table, which is the authoritative catalogue: that way adding a country is a
 * migration, not a code change.
 */
async function resolveTarget(
  // deno-lint-ignore no-explicit-any
  client: any,
  requested: string
): Promise<Target | null> {
  const alias = ALIASES[requested.toLowerCase()]
  if (alias) return alias

  if (!/^[A-Za-z]{2}$/.test(requested)) {
    console.error(`"${requested}" is neither an ISO 3166-1 alpha-2 code nor a known alias.`)
    console.error(`Known aliases: ${Object.keys(ALIASES).join(', ')}`)
    return null
  }

  const code = requested.toUpperCase()
  const { data, error } = await client
    .from('countries')
    .select('code, name, overpass_iso_code')
    .eq('code', code)
    .maybeSingle()

  if (error) {
    console.error(`Could not look up ${code}: ${error.message}`)
    return null
  }
  if (!data) {
    console.error(`${code} is not in the countries table.`)
    console.error('Has the all-countries migration been applied? Try: supabase db push')
    return null
  }

  return {
    code: data.code,
    iso: data.overpass_iso_code ?? data.code,
    name: data.name
  }
}

/**
 * Reads and sanity-checks the credentials from supabase/.env.
 *
 * Checking for placeholders matters as much as checking for absence. Copying
 * .env.example leaves SUPABASE_URL set to a syntactically valid URL pointing at
 * a host that does not exist, so a presence-only check passes, two minutes of
 * Overpass queries run, and the whole thing dies on a DNS error with a stack
 * trace pointing at the upsert.
 *
 * It is a particularly confusing failure because `supabase db push` in the same
 * command succeeds: the CLI uses the linked project from `supabase link` and
 * never reads this file. The migrations land correctly while the seed talks to
 * nowhere.
 */
function readCredentials(): { url: string; key: string } | null {
  const url = Deno.env.get('SUPABASE_URL')?.trim()
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')?.trim()

  const complain = (problem: string) => {
    console.error(`${problem}\n`)
    console.error('Fill in supabase/.env with the real values from your Supabase dashboard,')
    console.error('under Settings > API:')
    console.error('')
    console.error('  SUPABASE_URL=https://<your-project-ref>.supabase.co')
    console.error('  SUPABASE_SERVICE_ROLE_KEY=<the service_role key>')
    return null
  }

  if (!url || !key) {
    return complain('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are both required.')
  }

  const looksLikePlaceholder = (value: string) =>
    /your-project-ref|your-service-role|^YOUR-/i.test(value)

  if (looksLikePlaceholder(url)) {
    return complain(`SUPABASE_URL is still the example placeholder: ${url}`)
  }
  if (looksLikePlaceholder(key)) {
    return complain('SUPABASE_SERVICE_ROLE_KEY is still the example placeholder.')
  }

  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return complain(`SUPABASE_URL is not a valid URL: ${url}`)
  }
  if (parsed.protocol !== 'https:') {
    return complain(`SUPABASE_URL must be https, got ${parsed.protocol}`)
  }

  // The service role key is a JWT. The anon key is too, so this does not prove
  // you used the right one, but it does catch pasting something else entirely.
  if (key.split('.').length !== 3) {
    return complain('SUPABASE_SERVICE_ROLE_KEY does not look like a key (expected three dot-separated parts).')
  }

  return { url, key }
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
