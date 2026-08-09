# Posted speed limits

Everything else in Zonexplo answers "what is enforced *here*", at a camera or
across an average-speed section. This answers the ordinary question in between:
what does the sign on this road say, and am I over it.

It is a different kind of claim from the rest of the app, and that difference
drives every decision below.

A camera warning says *there is a thing here*. Being wrong costs a moment of
irritation. A limit says *the sign says 90*, which a driver may act on without
having seen the sign. So the rule is absolute:

> **A limit is only ever stated when it was read off an explicit `maxspeed`
> tag.** Nothing is inferred from a national default. A road nobody has tagged
> has no limit and the app is silent on it.

That is why "every road with a maxspeed tag" is the dataset rather than "every
road". Roughly half of any country's road network carries no explicit limit,
and the honest answer there is nothing at all.

---

## What the driver gets

Two things, separately switchable in Settings under **Road speed limit**:

| | |
| --- | --- |
| **Show the limit on screen** | A speed-limit roundel in the top left, with the current speed under it. Turning this off stops the matcher running at all. |
| **Say when I am over it** | The spoken alert. Turning this off leaves the roundel working. |

The spoken line is two sentences, one number each, limit first:

> "Limit 90. You are 12 over."

No mention of a camera and no threat. The app does not know whether anything is
enforcing this stretch, and inventing a consequence for a number it has no
evidence about is how a safety aid turns into nagging.

### Silence is the feature

A speed alert that fires on every overshoot is muted within a week, and a muted
alert warns nobody about anything. Four thresholds exist purely to buy silence,
all in `SpeedLimitMonitor.Thresholds`:

| | | why |
| --- | --- | --- |
| Tolerance | `max(7 km/h, 8% of the limit)` | Speedometers are required by regulation never to under-read and typically show around 5% high, so a driver whose dial says 95 is often doing 90. Alerting at the limit exactly fires at a speed they believe is legal. The proportional half stops a fixed margin being lenient on a 30 street and pedantic on a 130 motorway. |
| Sustained | 4 seconds | Overtaking, a downhill, the moment a limit drops. All cross the tolerance and come back on their own. |
| Repeat interval | 60 seconds | Somebody knowingly holding 100 in a 90 does not need telling every four seconds. They were told. |
| Minimum speed | 25 km/h | Below this GPS speed is unreliable enough that the exceedance may not be real, and a 10 km/h living-street limit would alert on a car park manoeuvre. |

Moving onto a road with a different limit clears the state, so coming off a
motorway into a town is announced promptly rather than waiting out the
motorway's cooldown.

**Inside an average-speed zone the limit alert goes silent entirely.** The
coaching engine already owns the voice there, telling the driver what speed to
hold, worked out from the same road and aimed at a camera that is actually
there. A second voice saying something adjacent about the same tarmac is noise
at the one moment the driver most needs to hear one clear number.

---

## Which road am I on

`RoadLimitMatcher`, in ZonexploCore.

The naive version — nearest polyline wins — is wrong in exactly the places a
driver notices. A motorway and its parallel service road are twenty metres
apart. A slip road hugs the carriageway it leaves for several hundred metres. At
a crossroads two roads pass through the same point. In all three the nearest
line flips between two answers with different limits, and the app spends the
junction announcing and retracting.

Three things stop that:

- **A corridor, not a nearest-match.** A road further than 30 m from the fix is
  not a candidate at all, however much nearer it is than everything else. That
  covers GPS error plus half a dual carriageway.
- **Heading agreement.** The cross street at a junction runs *across* the
  driver's course. Comparing bearings removes it outright, which distance alone
  never can. Agreement is checked in either direction, because a two-way road is
  the same road whichever way it is driven — direction decides which *limit*
  applies, not which road it is.
- **Hysteresis.** Taking a different road needs 2 consecutive fixes; losing the
  current one needs 4. The cost is about a second of staleness after a genuine
  turn. The benefit is that driving straight past a junction produces no change
  at all.

A fix with no course — stopped at a light, or a receiver that could not work one
out — agrees with everything. There is no information to filter on, and
discarding every candidate would blank the limit every time the car stopped.

### Directional limits

`maxspeed:forward` and `maxspeed:backward` are stored when they differ from the
base tag. Forward means along the stored geometry, which is OpenStreetMap's
digitisation order and carries no meaning beyond that; the matcher compares the
driver's course to the bearing of the segment they are on.

When the direction cannot be established the fallback is the **higher** of the
two, deliberately. An unnecessary silence is a smaller failure than telling a
driver they are over a limit that applies to the other carriageway.

---

## Getting the data

### The harvest

`make seed-limits CODE=LT`.

**This is not on the nightly schedule, and that is not an oversight.** A camera
sync is three Overpass queries and finishes in a couple of minutes. A limit
harvest is a few hundred tiled queries against the road network of an entire
country and runs for tens of minutes; on anything the size of France it is an
afternoon. A Supabase Edge Function is killed long before that, so a scheduled
road-limit job would fail every night in exactly the way that looks like it is
working — partial data, no error, a country quietly half covered.

So it is a seed-CLI job, run on demand from a machine with no wall clock on it.
Same pattern `make seed-country` already uses.

The shape of a run:

1. Resolve the country's bounding box from the same admin relation the area
   filters use. This doubles as the probe that the ISO code resolves at all:
   Overpass answers HTTP 200 with an empty element list when an area lookup
   fails, so without it the first sign of a bad code would be four hundred empty
   tiles and a report claiming the country has no speed limits.
2. Split the box into quarter-degree tiles — 264 of them for Lithuania.
3. Per tile, query `way[highway][maxspeed]` constrained by **both** the country
   area and the tile bbox. The bbox is what keeps one answer small enough to
   arrive; the area filter is what stops a border tile filing the neighbouring
   country's roads under the wrong dataset.
4. Translate, simplify, upsert.
5. Close the run with `finish_road_limit_sync`.

Every finished tile is written to a checkpoint file beside the script, so ctrl-C
and re-run resumes rather than starting again. The checkpoint is deleted once a
run covers the whole country. `--restart` ignores it.

#### The tile size has to change with the country

`--tile=DEGREES` overrides the quarter-degree default, and on anything large it
has to. A tile costs about the same whatever is in it, so the run time is the
tile count and nothing else:

| | tiles at 0.25° | tiles at 0.5° |
| --- | --- | --- |
| Israel | 112 | 30 |
| Finland | 2193 | 572 |
| Sweden | ~2970 | ~742 |

At the default, Finland is a day of querying. Halving the tile size divides the
count by four.

The limit on how large is the Overpass timeout: a tile too big to answer comes
back a failure, and a run with failed tiles is reported incomplete so that
nothing is retired on the strength of it. Err small on dense country and large
on empty country — Finland and Sweden are mostly forest, which is why half a
degree works there and would be risky over Israel.

**A checkpoint belongs to one tile size.** The keys are derived from it, so
resuming at a different size skips tiles that were never covered and calls the
country complete. Pass `--restart` when changing it; the CLI warns rather than
guessing.

### The same harvest without a laptop

`make seed-limits` needs Deno and a checkout. That is fine for whoever maintains
the datasets and useless to everyone else, so the same harvest is also available
as an Edge Function:

```sh
curl -X POST "$SUPABASE_URL/functions/v1/sync-limits" \
     -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
     -H "Content-Type: application/json" \
     -d '{"country":"MD"}'
```

**Keep calling it until the response says `done: true`.** One call is one chunk,
bounded by `budgetMs` (100 s by default) and `maxTiles`. The reply carries
`tilesDone`, `tilesRemaining` and a `next` line saying what to call.

This does not contradict the section above. The length is what rules out doing a
country in *one* invocation; it never ruled out doing it in fifty. `syncRoadLimits`
already accepted a set of finished tiles and reported each one as it landed,
because it was written to survive a ctrl-C — moving that resume point from a
local file into `road_limit_harvest` was the whole change.

Two things a chunked run must get right, both of which have tests:

- **Every chunk passes the first chunk's `runStartedAt`.** Retirement is "last
  seen before the run began". Per-chunk clocks would make each chunk retire what
  the one before it wrote, and the country would converge on holding only the
  final chunk's tiles, with nothing anywhere reporting a problem.
- **Only the chunk that covers the country calls `finish_road_limit_sync`.**
  That RPC bumps the version phones watch. Per-chunk finalisation would order
  every phone to re-check a national dataset once per chunk.

Still not on the nightly schedule, for a new reason: cron would fire it once, get
one chunk, and report success, leaving the country permanently part harvested.

`{"reset": true}` throws the resume point away and starts the country over, which
is what you want when the tile size or tolerance changed under a half-finished
run.

#### Expect it to be slow, and expect tile size to matter

A tile costs about two minutes whatever is in it. On Moldova a half-degree tile
containing no roads at all still took 115 seconds, so the cost is the Overpass
query itself — resolving `area["ISO3166-1"=...]` — and not the data coming back.
A country is therefore roughly `tiles × 2 minutes`, and at one tile per
invocation that is hours, not minutes. Moldova's 56 tiles is about four.

That argues for the largest tiles you can get away with, and there is a hard
limit on how large:

| Moldova at | Tiles | Outcome |
| --- | --- | --- |
| 0.25° | 195 | every tile finishes; ~7 hours of query overhead |
| 0.5° | 56 | every tile finishes; ~4 hours |
| 1.0° | 16 | **livelocks** — the Chișinău tile never returns inside 150 s |

The livelock is the failure worth knowing about. A tile that cannot finish
inside the invocation ceiling is killed mid-request, so it is never recorded,
so the next call picks the same tile and dies the same way. The harvest runs
forever at zero progress, and every call still reports a cheerful
`done: false`.

`tileDegrees` should therefore err small. The real fix is for a timed-out tile
to be subdivided rather than retried, which would let a run start coarse and
refine only where it has to; that is not built yet.

#### Driving it from pg_cron, and remembering to stop

Calling it by hand for four hours is nobody's idea of a good time, so schedule
it and let it run:

```sql
select cron.schedule('md-road-limits', '*/4 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-REF.supabase.co/functions/v1/sync-limits',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer YOUR-ANON-KEY'),
    body := '{"country":"MD","tileDegrees":0.5,"maxTiles":8,"budgetMs":60000}'::jsonb,
    timeout_milliseconds := 170000);
$job$);
```

Space the schedule wider than a call takes, or firings overlap and two chunks
harvest the same tile.

**Unschedule it when the country finishes.** Completing clears the checkpoint and
the run marker, so the next firing does not find a finished country — it finds a
clean slate and starts the whole harvest again.

```sql
select cron.unschedule('md-road-limits');
```

#### Harvested so far

| Country | Ways | Version |
| --- | --- | --- |
| Moldova | 6883 | 1 |
| Israel | — | not harvested |
| Lithuania | — | not harvested |

Moldova's distribution looks like a country rather than a scrape artifact: 3840
ways at 50, 1060 at 90, then a tail through 70/60/40/30. The 20s and 5s are car
parks and living streets, which is the tagging behaving as designed.

### Which roads count

`DRIVABLE_HIGHWAY_VALUES` in `overpass.ts`: motorway, trunk, primary, secondary,
tertiary and their `_link` variants, plus unclassified, residential,
living_street, busway and road.

Not `service` and not `track`. Driveways and supermarket parking aisles are
`service` and are routinely tagged `maxspeed=10`; a car crossing a car park at 30
is not speeding, and being told so would teach the driver that limit alerts are
noise. Footways and cycleways carry maxspeed for bicycles and are not roads.

Ways shorter than 25 m are dropped. A stub between two junctions cannot be told
apart from the roads either side of it by a receiver with 5 m of error.

### Geometry is simplified to 8 m

Ramer-Douglas-Peucker, before anything is stored. OSM digitises road centrelines
at a fidelity that exists for rendering; the phone only ever asks one question of
this geometry — am I on this road? — which it answers with a 30 m corridor.
Points that move the line by less than a few metres cannot change that answer.

The tolerance stays well under the corridor on purpose. Simplifying anywhere near
30 m would let a bend drift far enough to hand the driver the limit from the road
they are not on.

### A partial harvest must not retire anything

`finish_road_limit_sync` takes a `p_complete` flag that `finish_country_sync`
does not need, for a reason specific to tiling.

A camera harvest is one query: it worked or it did not. A limit harvest is a few
hundred, and stopping after 200 is an ordinary outcome — a rate limit, a timeout,
someone pressing ctrl-C. Every way in the 400 tiles that were never fetched looks
exactly like a way that has been deleted from OpenStreetMap.

So the caller has to say whether it covered the country. A partial run writes what
it found and touches nothing else. Only a complete run may conclude that an unseen
way is a gone way, and even then the same more-than-half guard as
`finish_country_sync` applies, because a complete run made entirely of empty
answers is still a failed harvest.

Unlike a camera, a retired limit is not shipped to the phone as a faded guess. A
camera that vanished from OSM may well still be bolted to its gantry; a limit is
a claim about a sign, and a claim nobody can source is one the app should stop
making.

---

## On the phone

### It is downloaded separately

Speed limits are their own opt-in per country, with their own version line, sat
under the country in the download list. Two reasons:

- **Size.** This is two orders of magnitude larger than the camera data. Rolling
  them together would mean a driver who wants camera warnings has to take
  hundreds of megabytes of road network to get them.
- **Churn.** A camera moving should not re-check a dataset three orders of
  magnitude larger, and a road being retagged should not re-check the cameras.

The download is written page by page as it arrives rather than collected and then
stored — a country's limits do not fit comfortably in memory — and the cursor
advances per page, so a download that dies at 80% resumes from 80%. Removing the
limits clears the cursor, which is the way back to a clean download.

### It is indexed by grid cell, not bounding box

Cameras get away with a bounding-box scan over indexed latitude and longitude
because a country holds a few thousand of them. Limits are three orders of
magnitude more numerous and the same query degenerates into reading every road in
a band of latitude stretching across the country.

So each stored row knows the 0.02° cell its midpoint falls in, and a lookup asks
only for the cells around the driver. Two things make that correct:

- **Rows are chunked to 400 m before storage**, so a row's extent from its
  midpoint is bounded. Without it one 30 km motorway way would sit in a single
  cell and be invisible from every other cell it runs through. Consecutive chunks
  share their boundary point, so a driver sitting exactly on a join projects onto
  both rather than neither.
- **The lookup asks for one cell of margin.** A chunk whose midpoint sits at a
  cell edge still reaches into the next one, and a cell is wider than a chunk is
  long.

The limit window is rebuilt every 500 m and covers 1.2 km. Much tighter than the
geofence window, and it has to be: matching projects every candidate on every
fix, so a wide window would load every side street within a kilometre for nothing.

---

## Parameters in one place

| what | where | value |
| --- | --- | --- |
| Matching corridor | `RoadLimitMatcher.Thresholds` | 30 m |
| Heading tolerance | `RoadLimitMatcher.Thresholds` | 55° |
| Fixes to change road | `RoadLimitMatcher.Thresholds` | 2 |
| Fixes to lose the road | `RoadLimitMatcher.Thresholds` | 4 |
| Alert tolerance | `SpeedLimitMonitor.Thresholds` | max(7 km/h, 8%) |
| Sustained before speaking | `SpeedLimitMonitor.Thresholds` | 4 s |
| Repeat interval | `SpeedLimitMonitor.Thresholds` | 60 s |
| Minimum speed to alert | `SpeedLimitMonitor.Thresholds` | 25 km/h |
| Simplification tolerance | `simplifyPolyline` | 8 m |
| Minimum way length | `translate.ts` | 25 m |
| Harvest tile size | `syncRoadLimits` | 0.25° |
| Storage chunk length | `RoadLimitGrid` | 400 m |
| Grid cell size | `RoadLimitGrid` | 0.02° |
| Limit window radius | `DriveMonitor` | 1.2 km |
