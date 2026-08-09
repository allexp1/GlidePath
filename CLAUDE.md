# Zonexplo — working notes

Context for anyone (human or agent) picking this up cold. The docs under `docs/`
explain how the product works and why; this file is about the state of the thing
and the traps that are not visible from the code.

---

## What it is

An iOS speed-camera co-pilot. It runs behind a navigation app and speaks up
about cameras; inside an average-speed zone it works out continuously what speed
to hold to leave under the limit. Launch countries are Israel, Moldova and
Lithuania.

Swift 6, iOS 26, strict concurrency. Supabase (Postgres + PostGIS) for the
camera catalogue, Deno Edge Functions for the harvesting jobs.

---

## Layout and the one rule that matters

```
ios/project.yml              XcodeGen manifest — the real build config
ios/App/                     the app target
ios/Packages/ZonexploCore/  the engine, as an SPM package: pure, testable, no UI
supabase/migrations/         schema
supabase/functions/          Edge Functions (Deno)
supabase/seed/               the seed CLI (Deno)
scripts/generate-app-icon.py the placeholder icon generator
```

**`ios/Zonexplo.xcodeproj` is generated and gitignored.** Anything you change
through Xcode's build-settings UI is destroyed by the next `make project`. Edit
`ios/project.yml` instead. This is the single most common way to lose an hour
here.

`Config.xcconfig` is also gitignored — Supabase keys plus Apple Team ID, copied
from `Config.example.xcconfig`. `SUPABASE_URL` must have **no scheme**: xcconfig
treats `//` as a comment, so `https://x.supabase.co` silently truncates.

---

## Before debugging a build, run `make doctor`

It checks the things that break a build while reporting something else
entirely. Every one of these has cost someone real time:

| Symptom | Actual cause |
| --- | --- |
| 15× `unable to resolve module dependency` | Terminal running under Rosetta: app builds x86_64, packages build arm64 |
| `module file is incompatible with this Swift compiler` | stale DerivedData |
| `failed to unlink '.../ä'` cloning GRDB | `git config --global core.precomposeunicode true` not set |
| `Missing package product 'ZonexploCore'` | packages not resolved yet, or an iCloud-evicted `Package.swift` |
| `RPC failed; curl 56` cloning GRDB | large repo over a flaky link — `git config --global http.version HTTP/1.1`, or clone it once by hand with `--filter=blob:none` and point `project.yml` at the local path |

None of those name their cause in the error text, which is why `doctor` exists.

---

## Backend state

Supabase project **Zonexplo**, ref `mesvkrfvbqrboouwwzlt`, eu-central-1.

Data as of the last session:

| Country | Cameras | Zones | Road limits |
| --- | --- | --- | --- |
| Lithuania | 768 | 95 | 0 |
| Israel | 185 | 0 | 0 |
| Moldova | 108 | 0 | **6883** (version 1) |

### Open problem: the Vault is empty, so the nightly sync cannot run

`sync-cameras` fires nightly via pg_cron and pg_net, and reads its credentials
from Supabase Vault. **Those secrets were never created**, so it has been
failing silently since the project was set up. Camera data for all three
countries is going stale. Fix, once, in the SQL editor:

```sql
select vault.create_secret('<project url>', 'project_url');
select vault.create_secret('<service role key>', 'service_role_key');
```

Related, and already fixed but worth knowing: the **pg_net background worker was
dead** — requests queued forever and no response ever arrived. `select
net.worker_restart();` revives it. If anything scheduled appears to do nothing,
check `net.http_request_queue` against `net._http_response` before suspecting
your own code.

### After adding a column, reload PostgREST

```sql
notify pgrst, 'reload schema';
```

PostgREST caches the schema. A new column is invisible to supabase-js until it
reloads, and writes to it fail with an unknown-column error. This silently broke
the road-limit bounds cache and turned a one-off cost into a permanent one — the
harvest ran for half an hour making zero progress and reporting success.

---

## Harvesting road limits

Two front ends onto the same `syncRoadLimits`:

- `make seed-limits CODE=XX` — the seed CLI, one long local process, needs Deno.
- `sync-limits` Edge Function — the same work in chunks, for when you cannot run
  the CLI. Call it repeatedly until the reply says `done: true`.

Facts that are not obvious and cost a day to learn:

- **An Overpass query costs about two minutes whatever it returns.** A
  half-degree tile with no roads in it took 115 seconds. The cost is resolving
  `area["ISO3166-1"=...]`, not the data. A country is roughly `tiles × 2 min`.
- **Edge Functions are killed at 150 s.** A tile that cannot finish inside that
  is never recorded, so the next call retries it and dies identically —
  a livelock at zero progress, reporting `done: false` forever. Moldova at 1°
  does this on Chișinău; 0.5° works. `tileDegrees` should err small.
- **Every chunk must pass the first chunk's `runStartedAt`.** Retirement is
  "last seen before the run began", so per-chunk clocks make each chunk retire
  what the previous one wrote. Tested in `limits_test.ts`.
- **Only the chunk that completes the country may finalise**, because
  `finish_road_limit_sync` bumps the version phones watch.
- Driving it from pg_cron works, but **unschedule the job when it finishes** —
  completion clears the checkpoint, so the next firing starts a whole new
  harvest.

Israel and Lithuania have not been harvested. Roughly four hours each.

### The deployed `sync-limits` differs from the repo

The deploy path used from a sandbox uploads a single file, so the live build
pins its `_shared` imports to a GitHub commit instead of importing relatively.
Same code. Running `supabase functions deploy sync-limits` from a checkout
replaces it with the relative-import version and removes the divergence.

---

## Releasing

CI builds Debug and Release on every push, runs every suite, and **archives the
app and asserts the checks App Store Connect makes**. That last job is the one
that catches upload blockers, and it has earned its keep:

- `UIRequiredDeviceCapabilities: armv7` — 32-bit ARM on an arm64-only app.
- A declared app icon with no image behind it.
- **`CFBundleIconName` missing.** Xcode normally injects it by merging the
  partial plist `actool` emits, and that merge does not reach a target using an
  explicit `INFOPLIST_FILE` — which is exactly what XcodeGen generates. The icon
  compiles, renders, and shows on the home screen; only the upload notices. It
  is declared by hand in `project.yml` and must stay there.

TestFlight needs nine repository secrets and the one-time Apple setup in
`docs/TESTFLIGHT.md`. `make archive` / `make testflight` do the same thing
locally.

**The app icon is real artwork** — the Gateway Arc mark, a 1024×1024 opaque
sRGB PNG in the asset catalogue. `scripts/generate-app-icon.py` still draws the
old placeholder, so `make icon` now refuses without `FORCE=1`; running it by
reflex would replace the artwork with a coloured square and nothing would
complain until the upload.

Bumping the build number means editing `CURRENT_PROJECT_VERSION` in
`ios/project.yml` and re-running `make project`. App Store Connect rejects a
repeated build number.

---

## Conventions

- Comments explain **why**, especially where the obvious thing is wrong. Match
  that density; it is deliberate.
- A silent wrong answer is the worst outcome in this codebase. Prefer refusing
  to a plausible guess — a limit nobody sourced, a zone measured from the wrong
  end, a harvest that reports success on partial data.
- Tests exist for the invariants whose violation looks like working software.
- `make build` uses `pipefail` and no `|| true`. Keep it that way; it used to
  exit 0 on a failed build.
