# Adding Israeli average-speed sections by hand

Israel is switching on roughly 250 average-speed cameras across about 125
sections, with enforcement starting Q3 2026. OpenStreetMap will not carry them
for months after they go live, and the nightly Overpass sync therefore finds
nothing. Until mappers catch up, `supabase/seed/israel_zones.json` is the only
source of Israeli sections, and it is maintained by hand.

The file ships empty. That is deliberate: every entry becomes a live instruction
telling a driver what speed to hold, so nothing goes in it that has not been
read off an official announcement or driven and checked. A plausible-looking
guess produces an app that coaches confidently about a section that is not
there, which is worse than an app that says nothing.

## The format

```jsonc
{
  "zones": [
    {
      "id": "route6-hadera-north",   // required, stable, unique, your own naming
      "name": "Route 6, Hadera to Iron",
      "road_ref": "6",
      "speed_limit_kph": 110,        // required
      "minimum_speed_kph": 50,       // optional, posted legal minimum
      "direction_degrees": 12,       // optional, direction of travel
      "distance_meters": 8400,       // optional, see below
      "path": [                      // required, [latitude, longitude]
        [32.28110, 34.94420],
        [32.29050, 34.94690]
      ]
    }
  ]
}
```

`supabase/seed/israel_zones.example.json` has a filled-in entry. Its coordinates
are fictional and its id says so; copy the shape, not the numbers.

### Fields

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | Becomes `manual/<id>` in the database. Changing it creates a second zone rather than editing the first, so pick something stable. |
| `speed_limit_kph` | yes | The posted limit for the section. |
| `path` | yes | At least two `[lat, lon]` pairs, in the direction of travel: the first point is the entry camera, the last is the exit camera. |
| `distance_meters` | no | The official section length, when one is published. Omit it and the length is measured from `path`. |
| `minimum_speed_kph` | no | The coaching engine will never advise below this. |
| `direction_degrees` | no | Degrees clockwise from north. A dual carriageway is two entries, one per direction. |
| `name`, `road_ref` | no | Shown in the app. |

### About `distance_meters`

This is the number the whole allowance calculation divides by, so it matters
more than anything else in the entry. If the police publish a section length,
use it. If they do not, leave the field out and let the traced path speak.

The seed rejects any entry whose declared distance differs from its traced path
by more than 25 percent. That check exists to catch the most common mistake:
tracing the wrong carriageway, or tracing a straight line down a road that
actually curves.

### Tracing a path

Ten to thirty points is plenty. The path is used for two things, and neither
needs great precision:

- **Progress along the road.** A fix is projected onto the polyline, so the
  points need to follow the carriageway closely enough that the projection lands
  in the right place. Bends need points; straights do not.
- **Deviation detection.** A driver more than 60 metres off the path for five
  continuous seconds ends the session. Too coarse a trace around a curve will
  cancel sessions on drivers who are still on the road.

The easiest way to produce one is to draw the route in any map tool that exports
GeoJSON, then reorder each pair to `[lat, lon]`. Note that GeoJSON is `[lon,
lat]` and this file is the other way round, which is the mistake to check for
first if a new section behaves strangely.

## Loading it

```sh
make seed-israel                 # fetch OSM, merge the file, write to Supabase
make seed-dry-run                # translate and report, write nothing
```

The seed is idempotent. Entries are matched on `manual/<id>`, so re-running
updates in place rather than duplicating. Manual zones carry `source = 'manual'`
in the database, which is what stops the nightly OpenStreetMap job from marking
them unverified when it inevitably fails to find them.

## When OpenStreetMap catches up

Once a section is properly mapped as a `type=enforcement`,
`enforcement=average_speed` relation, the nightly sync will start bringing it in
on its own, and it will exist twice: once as `manual/...` and once as
`relation/...`. Delete the manual entry from the JSON and re-run the seed. The
old row stays in the database with `source = 'manual'`, so remove it explicitly:

```sql
delete from public.zones where osm_id = 'manual/route6-hadera-north';
```
