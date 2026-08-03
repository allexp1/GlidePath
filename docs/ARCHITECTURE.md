# Architecture

The one-line version: **the phone is the brain, the backend is a notebook.**

## Why there is no server

Every decision a driver experiences happens on the phone, from a local SQLite
copy of the camera data, with no network involved.

The reason is not architectural taste. Average-speed enforcement gets deployed
on inter-urban roads, which is exactly where mobile signal is worst. An app that
needs a round trip to decide what speed to coach is an app that goes silent in
the places it exists for. Moldova makes this vivid: rural coverage is patchy
enough that a network-dependent design would fail routinely.

Once the driving logic is on the phone, the backend has nothing interesting left
to do, and that is the point. It stores rows and stamps `updated_at`. If you
find yourself wanting to add logic to it, that is a signal the logic belongs on
the phone.

## The three pieces

```
                    nightly
   OpenStreetMap  ──────────▶  Supabase  ◀──── delta sync ────  iPhone
     (Overpass)               (Postgres)         on launch      (SQLite)
                                  ▲                                │
                                  │                                │
                          community reports              everything that
                          (promoted by a human)          happens while driving
```

### GlidePathCore

A pure Swift package. No UI, no dependencies, no CoreLocation, no Foundation
beyond value types and dates.

That constraint is load-bearing. It means the entire coaching engine runs under
`swift test` on any machine in milliseconds, so a test can replay a whole
simulated drive and assert on every line the app would have spoken. Nothing in
the engine is a class with mutable state either: `ZoneSession` is a struct and a
test drives it by folding fixes over it.

Contents:

| | |
| --- | --- |
| `Geo/` | Coordinates, polylines, projection |
| `Model/` | `Zone`, `Camera`, `RestStop`, `LocationFix` |
| `Engine/` | Allowance math, tiers, crossing and deviation detection, the session state machine |
| `Speech/` | Phrasing, and when to speak at all |
| `Simulation/` | GPX parsing and a scripted drive generator, for tests |

### The app

Everything the engine deliberately refuses to know about:

| | |
| --- | --- |
| `Location/` | CoreLocation, the twenty-region window, the orchestration loop |
| `Storage/` | GRDB, the offline copy |
| `Sync/` | A small PostgREST client and the delta sync |
| `Audio/` | AVSpeechSynthesizer and the audio session |
| `UI/` | SwiftUI in Liquid Glass |

`DriveMonitor` is the only place these meet. It owns the loop — watch cheaply,
wake into precise tracking near a zone, feed fixes to the engine, say what the
engine decides, drop back to cheap watching — and it contains no driving logic
of its own.

### Supabase

PostGIS tables, row level security, and one scheduled Edge Function.

The phone reads through `*_public` views rather than the tables. Two reasons:
PostgREST serialises geography columns as WKB hex, and putting a WKB parser on
the phone to decode a latitude would be absurd; and the views are the delta sync
contract, every one of them carrying `updated_at`.

The views are `security_invoker`, so RLS is evaluated as the caller. Without
that they would be a hole straight through the policies.

## Data flow while driving

0. **Not watching.** Nothing is monitored and nothing is running. Whether the
   driver had it watching is persisted, so a relaunch resumes rather than coming
   up idle.
1. **Watching: drive mode.** Continuous updates whose accuracy and distance
   filter scale with the distance to the nearest camera or zone — coarse beyond
   6 km, sharpening inside 1.5 km — plus up to 20 monitored regions and
   significant-location changes underneath, which are what relaunch a terminated
   app. Significant-location changes are *not* enough on their own: a camera
   warning is computed per fix against a window at most 900 m wide, and they
   cannot land inside one reliably. Point cameras are announced off the
   continuous stream, with the camera geofence wired up as a backstop for the
   warning it missed. The posted-limit matcher runs here too.
2. **A zone geofence fires**, several hundred metres before the entry camera.
   Precise tracking switches on so the receiver has time to lock and settle.
3. **The entry line is crossed.** The crossing time is interpolated between the
   last fix before and the first after, never taken from the wake-up.
4. **Coaching.** Each fix is projected onto the zone polyline for distance
   travelled; the allowance is recomputed; the tier is chosen; the announcer
   decides whether it is worth saying out loud. The posted-limit alert goes
   silent for the duration: the coaching engine owns the voice inside a zone.
5. **The exit line is crossed**, timestamped the same careful way. The outcome
   is spoken and written to local history.
6. **Back to drive mode.** Leaving a zone does not mean the driver has stopped
   driving, and the point cameras after it need the same fix stream the zone did.

If the driver diverges from the zone's road for five continuous seconds, the
session is cancelled instead. One bad fix under a bridge does nothing.

## Decisions worth knowing about

**Total distance over total time, never instantaneous speed.** The exit camera
measures elapsed time. Anchoring on that makes the whole calculation robust to
GPS noise for free.

**Projection, not hop-summing, for distance travelled.** Lateral jitter moves
cross-track distance and leaves along-track distance alone. Summing hops between
fixes would integrate the noise into the odometer, and the app would believe the
driver had travelled further than they had — which inflates the allowance in the
unsafe direction.

**Interpolated crossings.** Covered above. The failure mode of getting it wrong
is coaching too fast, which is the one failure this product cannot have.

**The safety floor is not configurable.** It is the difference between a useful
app and a dangerous one.

**Never hard-delete camera data.** A row that vanishes from OpenStreetMap is
marked unverified and still shipped to the phone, which shows it faded. Reverted
edits and re-tagging are routine, and a mapping accident must not be able to
silently disable a warning.

**A zone with unusable geometry is skipped, not approximated.** A straight line
between two cameras understates the distance on anything but a motorway, and an
understated distance makes the app coach a confidently wrong number. No zone is
better than a wrong one.

**Rounding is always down.** A target speed rounded up by 2 km/h is a fine.

## Things that would be reasonable to add

- Migrate region monitoring to `CLMonitor`.
- CarPlay. The live card is already the right shape for it.
- Live Activity on the Lock Screen during a zone.
- More countries: the only per-country work is an ISO code and, where the
  enforcement is too new for OpenStreetMap, a manual zones file.
