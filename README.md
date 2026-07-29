# GlidePath

[![CI](https://github.com/allexp1/GlidePath/actions/workflows/ci.yml/badge.svg)](https://github.com/allexp1/GlidePath/actions/workflows/ci.yml)

A background co-pilot for speed cameras. Not a navigator.

You keep using Waze or Google Maps. GlidePath runs quietly behind them and
speaks up about cameras. Inside an average-speed enforcement zone it works out
continuously what speed you need to hold to come out under the limit at the exit
camera, and tells you: *"hold 80 for the next 4 kilometres."*

Launch countries are **Israel**, where roughly 250 average-speed cameras across
about 125 sections switch on from Q3 2026, **Moldova**, where the problem is
mobile traps, patchy rural coverage and no signal, and **Lithuania**, which has
run average-speed enforcement long enough for the sections to be properly mapped.

---

## Setting it up

Four commands and two keys.

```sh
git clone https://github.com/allexp1/glidepath.git
cd glidepath

cp Config.example.xcconfig Config.xcconfig   # paste SUPABASE_URL, SUPABASE_ANON_KEY, DEVELOPMENT_TEAM
cp supabase/.env.example supabase/.env       # paste SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

make bootstrap                               # xcodegen, swiftlint, supabase cli, deno
make link                                    # once, so migrations know where to go
make seed                                    # apply migrations, pull camera data
make project                                 # generate the Xcode project

open ios/GlidePath.xcodeproj
```

`make link` asks for your project ref, which is the last path component of your
Supabase dashboard URL: `https://supabase.com/dashboard/project/`**`this-bit`**.
Pass it directly with `make link PROJECT_REF=abcdefghijklmnop` if you prefer.

You need a Supabase project before any of this: create one at
[supabase.com/dashboard](https://supabase.com/dashboard), then take the project
URL and `anon` key from Settings > API for `Config.xcconfig`, and the
`service_role` key from the same page for `supabase/.env`.

Both config files are gitignored; only the `.example` versions are committed.
`make help` lists everything else.

`make test` runs the engine test suite with no simulator and no network, which
is the fastest way to check nothing is broken.

### What you need

| | |
| --- | --- |
| Xcode | 26 or later (the UI uses the iOS 26 Liquid Glass APIs) |
| A Supabase project | free tier is fine |
| An Apple Team ID | only to run on a physical device |
| Deno | for the seed scripts |

`make bootstrap` installs the four command-line tools, skipping any you already
have. If it reports a Homebrew tap conflict on `supabase`, you already have the
CLI and it will be skipped.

### One thing the setup does not do

The nightly sync needs its credentials in Supabase Vault, which cannot be done
from a migration without committing a service role key. Run this once in the SQL
editor:

```sql
select vault.create_secret('https://YOUR-REF.supabase.co', 'project_url');
select vault.create_secret('YOUR-SERVICE-ROLE-KEY',        'service_role_key');
```

Until you do, the schedule fires and fails harmlessly. Seeding by hand still
works, and `make seed` prints a reminder.

---

## How it works

### The phone is the brain

There is no server. Supabase is a shared notebook: it stores camera geometry and
stamps every row with `updated_at`. Every decision a driver experiences happens
on the phone, offline, from a local SQLite copy.

That is not an aesthetic preference. The roads where average-speed enforcement
is worst are the roads where signal is worst, and an app that needs a round trip
to tell you to slow down is an app that stays silent exactly when it matters.

### The allowance

The exit camera does not care how fast you were going. It cares how long you
took. So the engine works entirely from two measured quantities and one
constant:

```
minLegalTime      = zoneDistance / limit
remainingBudget   = minLegalTime - timeSpent
maxRemainingAvg   = distanceLeft / remainingBudget
```

Instantaneous speed appears nowhere in that. It is smoothed over a few seconds
for the display and for noticing you are in traffic, and it never touches the
target.

The shape of `maxRemainingAvg` is counterintuitive and worth sitting with: a
*large* remaining budget over a *small* remaining distance produces a *low*
allowance. That is the driver who sped early and must now let the clock catch
up. Do 9 km of a 10 km zone at 150 in a 100 limit and the last kilometre has to
be driven at 25.

Progress along the road comes from projecting each GPS fix onto the zone's
polyline, not from summing point-to-point hops. Lateral noise then moves the
cross-track distance and leaves the odometer alone. Summing hops would integrate
the jitter straight into the distance travelled, and the app would think you had
gone further than you had.

### Three tiers

| Tier | When | What it says |
| --- | --- | --- |
| **Normal** | The allowance is at or above the limit | "You are fine. Hold 90." |
| **Tight** | Below the limit but above the safety floor | "Hold 80 for the next 4 kilometres." |
| **Impossible** | Below the safety floor | "You cannot make this one by driving. There is a services in 1 kilometre. A stop of 2 minutes puts you back under." |

**The safety floor is a hard rule, not a setting.** GlidePath will never coach a
speed below the strictest of: an absolute 30 km/h floor, half the posted limit,
and any posted legal minimum. On a 110 km/h road that is 55. A naive
implementation of this product will cheerfully tell someone to do 18 km/h in the
outside lane of a motorway because the arithmetic said so, and that is more
dangerous than the fine.

When even the floor will not save the section, the app says so plainly rather
than inventing advice. If there is a rest stop ahead inside the zone it offers a
pause long enough to work; if there is not, it says the zone is lost and tells
you to drive normally.

Below 10 km/h coaching goes silent. A driver in a jam cannot act on a target
speed, and the stopped time is handing the allowance back anyway.

### Timing the entry

The entry geofence has to be wide, several hundred metres, so the receiver has
woken, locked and settled before the real entry line. That means the wake-up
happens at the wrong place at the wrong time.

Timestamping the wake-up would start the clock early, which inflates elapsed
time, which inflates the allowance, which coaches you faster than you can safely
go. The error is in exactly the wrong direction. So the crossing time is
interpolated between the last fix before the entry line and the first fix after
it, and the exit is timestamped the same way.

### Twenty regions

Core Location monitors at most 20 regions per app, and the 21st call fails
silently. The set is a window that moves with the driver, and zone entries are
seeded before point cameras: a missed point camera costs one fine, a missed zone
entry costs the whole feature.

---

## Layout

```
ios/
  project.yml                    XcodeGen manifest; the .xcodeproj is generated, never committed
  App/                           the SwiftUI app: location, storage, sync, audio, UI
  Packages/GlidePathCore/        the engine. No UI, no dependencies, no CoreLocation
supabase/
  migrations/                    PostGIS schema, RLS, sync functions, the nightly schedule
  functions/sync-cameras/        the nightly Overpass job
  functions/_shared/             translation code, shared verbatim with the seed CLI
  seed/                          the seed CLI and israel_zones.json
docs/
scripts/
```

`GlidePathCore` is deliberately UI-free, dependency-free and CoreLocation-free.
That is what lets the entire coaching engine run under `swift test` on any
machine with no simulator, no Xcode project and no network, and it is why the
test suite can replay a whole drive in milliseconds.

---

## Tests

```sh
make test          # the engine, no simulator needed
make test-app      # everything, through a simulator
make lint
```

The engine suite covers the scenarios the product lives or dies on:

- **Early speeder recovery.** Blow the budget in the first half, get coached
  down, come out legal. Also: obey the *first* number the app says and check
  that alone is enough to pass.
- **Traffic jam recovery.** Coaching goes silent, the stopped time restores the
  allowance, and the tier is back to normal by the exit.
- **Floor clamping.** Swept across every combination of limit, distance covered
  and time elapsed rather than spot-checked, asserting that no advice is ever
  below the floor or above the limit.
- **Impossible tier.** Triggers correctly, and the pause it offers is
  arithmetically sufficient to actually work.
- **GPS jitter.** The same drive with 25 m of lateral noise must reach the same
  verdict.
- **A GPX-replayed drive** through the three tiers, with every spoken line
  checked for being a well-formed sentence.

CI runs the engine tests, builds the app and its tests on a simulator, runs
SwiftLint, type-checks the Deno code, and applies every migration to a real
Postgres with PostGIS, asserting that no public table is left without row level
security.

---

## Data

Camera data comes from OpenStreetMap contributors via Overpass, plus published
enforcement announcements. A nightly Edge Function refetches it, merges by OSM
id, and bumps a per-country dataset version so phones can ask for a delta.

**Nothing is ever hard-deleted.** A row that vanishes upstream is marked
unverified. OSM edits get reverted and areas get re-tagged, and a mapping
accident must not be able to silently switch off warnings for a camera that is
really there.

Israel's new average-speed sections are entered by hand in
`supabase/seed/israel_zones.json`, because OpenStreetMap will not carry them for
months after enforcement starts. **That file ships empty on purpose** — see
[docs/ISRAEL_ZONES.md](docs/ISRAEL_ZONES.md) for the format and for why
inventing plausible coordinates would be worse than having none.

### Countries

Every country is in the catalogue — 243 of them, generated from the ICU data
bundled with Node rather than typed out, so the names are spelled the way the
world spells them. Regenerate with:

```bash
node scripts/generate-countries-migration.mjs
```

Withdrawn ISO codes are excluded, and not merely for tidiness: ICU resolves
several of them onto the name of whatever replaced them, so RH and ZW both come
back as "Zimbabwe". Two rows for one place, one of which can never have data,
reads as a bug in the app rather than as a quirk of a standard. The generator
refuses to write a file containing a duplicate name and CI asserts the same thing
against a real database. Territories with no public roads are dropped
(Antarctica, Bouvet Island, and Sark, where cars are banned). XK is kept although
ISO never assigned it, because that is what OpenStreetMap and Geofabrik call
Kosovo.

**Being listed is not the same as having data.** Two columns, deliberately:

| column | means |
| --- | --- |
| `enabled` | offer this country in the app's download list |
| `sync_enabled` | include it in the nightly Overpass job |

Every country has `enabled`; almost none have `sync_enabled`. Overpass is run by
volunteers and its usage policy rules out bulk extraction, so querying two
hundred countries a night would be an abuse of a free service. Load one on
demand instead:

```bash
make seed-country CODE=PL
```

The app distinguishes three states rather than lumping them together, because
somebody who searches for their country and finds nothing needs to know whether
the answer is "no cameras here" or "nobody has looked yet" — only one of those is
worth waiting for. A country with `last_synced_at` set and no cameras is shown as
mapped and empty; one with no `last_synced_at` is shown as not surveyed yet.

### Before switching a country on, check whether it is legal there

Not a formality. Germany's §23(1c) StVO prohibits operating a camera-warning
device while driving; Austria and Switzerland prohibit the devices outright;
France requires that such apps show broad "zones de danger" rather than exact
camera locations. The catalogue lists every country because the list is
geography, but shipping alerts into a jurisdiction needs a per-country policy and
legal advice this repository does not contain.

### Privacy

There is no account, no analytics and no telemetry. Location never leaves the
phone. Zone history is written to the local database and stays there. The only
network traffic the app makes is anonymous reads of public camera data.

---

## Known limitations

- **Region monitoring uses the classic `CLCircularRegion` API**, which is
  formally deprecated in favour of `CLMonitor`. It was chosen for the longest
  track record of relaunching a terminated app into the background, which is the
  behaviour the product depends on. Migrating is worth doing and is not urgent.
- **Zone geometry is only as good as OpenStreetMap.** A relation without usable
  road geometry is skipped rather than approximated with a straight line,
  because a wrong section length makes the app coach a confidently wrong speed.
  That means some real sections will be missing until someone maps them.
- **Mobile camera hotspots are guesses**, and are worded as guesses.
- **The rest-stop pause assumes you resume at the limit.** Crawling afterwards
  would need slightly less, so the figure errs generous.

---

## What this is not

GlidePath is a speed awareness aid. It is not a navigator, it is not a radar
detector, and it is not a substitute for reading the signs. The camera data will
sometimes be wrong. The limit on the sign is always the limit.

---

## Licence

MIT. See [LICENSE](LICENSE).
