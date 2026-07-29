# Where the camera data comes from

Two sources: OpenStreetMap via Overpass, and hand entry from published
enforcement announcements. Plus community reports, once a human has approved
them.

## OpenStreetMap

### Point cameras

Three overlapping queries, because the same physical camera gets mapped several
different ways and no single tag catches them all:

```overpassql
node["highway"="speed_camera"](area.country);
node["man_made"="surveillance"]["surveillance:zone"="traffic"](area.country);
node["enforcement"](area.country);
```

`highway=speed_camera` is the main scheme. `man_made=surveillance` catches
installations mapped as generic surveillance equipment, which is common where
one gantry does several jobs. The bare `enforcement` query picks up seat belt
and phone cameras, which are newer and inconsistently tagged.

### Mapping tags to types

`enforcement` may be a semicolon-separated list, which is how a gantry doing
speed and red light at once is tagged.

| GlidePath type | Recognised from |
| --- | --- |
| `mobile_hotspot` | `speed_camera=mobile`, `speed_trap=yes`, `enforcement=mobile_speed` |
| `seatbelt_phone` | `enforcement` containing `seatbelt`, `mobile_phone`, `handheld`, `distracted_driving` |
| `bus_lane` | `enforcement` containing `bus_lane` or `psv` |
| `combined` | speed **and** signals |
| `red_light` | `enforcement=traffic_signals` or `red_light` |
| `fixed` | `enforcement=maxspeed`, or `highway=speed_camera` with nothing more specific |

A surveillance node in a traffic zone with no `enforcement` tag at all is stored
as `fixed`. It is probably a traffic-monitoring camera rather than an
enforcement one, but the cost of an unnecessary warning is mild irritation and
the cost of silence is a fine. The bias throughout is towards keeping a row.

### Average-speed sections

These are relations, not nodes:

```overpassql
relation["type"="enforcement"]["enforcement"="average_speed"](area.country);
out geom;
```

`out geom` is what makes the member way geometry come back, and that geometry is
the whole point: the road distance between the two cameras is the number the
allowance divides by, and a straight line between them understates it badly on
anything except a motorway.

Member roles used:

| Role | Meaning |
| --- | --- |
| (empty) or `road` | the carriageway ways covered by the section |
| `device` | the cameras |
| `from`, `to` | the section boundaries |

The road ways are stitched end to end. They arrive in document order, which is
not travel order, and any individual way may be digitised against the direction
of travel, so each step picks whichever remaining way has an endpoint nearest the
current end of the chain and reverses it if needed. The tolerance for "joined" is
25 metres.

The two `device` nodes are then ordered by how far along the stitched line they
sit, so entry really is the camera you meet first, and the distance is measured
between them rather than across the full extent of the member ways.

**A relation without usable road geometry is skipped, not approximated.** So is
anything shorter than 500 metres, which is almost always a mis-tagged relation.
A zone stored with a guessed length is worse than no zone: the app would coach a
confident number derived from a wrong distance.

### Parsing values

`maxspeed` is free text. A bare number is km/h, `50 mph` is converted, and
anything else — country defaults like `IL:urban`, or prose — comes back null.
The camera is then stored without a limit and the app warns about it without
claiming to know what it enforces.

`direction` is degrees or a cardinal abbreviation. `forward` and `backward` are
relative to a way that is not in scope, so they come back null and the camera is
treated as bidirectional. Unknown direction always means "warn anyway".

### Rest stops

`highway=rest_area`, `highway=services`, `amenity=fuel`, as nodes and as ways
with `out center`. Only fetched for countries that actually have average-speed
sections, since they are useless without one.

A stop is tied to a zone when it projects within 250 metres of the zone's road
and sits more than 100 metres from either camera. Distance along the road is
computed at seed time so the phone never projects rest stops on the hot path.

## The nightly job

`supabase/functions/sync-cameras`, fired by `pg_cron` through `pg_net` at 03:17
UTC. An odd minute on purpose: Overpass is a free service run by volunteers and
the top of the hour is when everyone else's cron fires.

Each run, per country:

1. Query Overpass, trying three mirrors in turn with exponential backoff.
2. Translate, and merge by OSM id.
3. Anything not seen this run is marked **unverified**, never deleted.
4. Anything seen again after having been marked missing becomes verified again.
5. Bump the country's `dataset_version`.

Step 3 is the important one. OpenStreetMap edits get reverted, areas get
re-tagged, and a mapping accident must not be able to silently switch off
warnings for a camera that is really there. The phone still receives unverified
rows and shows them faded, so the driver can see the app is unsure rather than
seeing nothing.

Step 4 matters just as much: without it, one Overpass timeout would permanently
degrade the dataset.

Countries are synced sequentially, and one country failing records an error
against that country without stopping the others.

Rows with `source = 'manual'` or `source = 'report'` are never touched by the
OSM job. Israel's hand-seeded sections would otherwise be wiped on the first run.

## Hand-entered data

Israel's new sections live in `supabase/seed/israel_zones.json`. See
[ISRAEL_ZONES.md](ISRAEL_ZONES.md). The file ships empty, and the reasoning for
that is in there.

## Community reports

Drivers can file a report, which goes to `pending_reports` — a separate table,
writable by authenticated users, readable only by whoever filed it. Nothing
reaches another driver until a human calls `approve_report`, which promotes it
into `cameras` with `source = 'report'` and bumps the dataset version so the
correction ships on the next launch rather than the next night.

Unreviewed reports are kept private deliberately. Making them readable would
turn the table into a public feed of unverified camera locations with no quality
control at all.

## Adding a country

1. Insert a row into `public.countries` with the ISO 3166-1 alpha-2 code.
2. Add it to `TARGETS` in `supabase/seed/seed.ts`.
3. Run `make seed-dry-run` and read the warnings before writing anything.
4. If the enforcement is too new for OpenStreetMap, add a manual zones file the
   way Israel does.

## Attribution

OpenStreetMap data is © OpenStreetMap contributors, available under the Open
Database Licence. Any distributed build must credit them.
