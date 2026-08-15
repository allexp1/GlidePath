#!/usr/bin/env bash
#
# Runs the outstanding road-limit harvests one after another.
#
# Sequential on purpose. Overpass answers one query at a time per client and
# the cost of a tile is the area filter rather than the data, so running two
# countries at once buys nothing and risks being throttled into failures that
# look like empty tiles.
#
# Every harvest is checkpointed per tile, so killing this at any point loses at
# most the tile in flight. Re-running the same command resumes.
#
#   ./scripts/harvest-queue.sh          # the whole queue
#   tail -f supabase/seed/harvest.log   # watch it
#
set -uo pipefail

cd "$(dirname "$0")/../supabase/seed" || exit 1
LOG="$(pwd)/harvest.log"

# Finland's checkpoint was written at half a degree. The tile key is derived
# from the tile size, so resuming at any other size would skip the 410 tiles
# already banked and then report a country that was never covered.
run() {
  local code="$1" tile="$2" note="$3"
  {
    echo ""
    echo "==============================================================="
    echo "$(date '+%F %T')  $code  ($note)"
    echo "==============================================================="
  } >> "$LOG"

  if [ -n "$tile" ]; then
    deno run --allow-net --allow-env --allow-read --allow-write \
      seed_limits.ts "$code" "--tile=$tile" >> "$LOG" 2>&1
  else
    deno run --allow-net --allow-env --allow-read --allow-write \
      seed_limits.ts "$code" >> "$LOG" 2>&1
  fi

  # Captured before anything else runs. Writing `status $?` inside a line that
  # also expands $(date) reports the status of date, which is always 0 - so the
  # first version of this logged "US-NY finished with status 0" for a harvest
  # that had crashed on its first query and written nothing.
  local status=$?
  echo "$(date '+%F %T')  $code finished with status $status" >> "$LOG"
}

# Finland first: 114,361 rows are already harvested and sitting in the table
# unusable, because the run was interrupted before it could finalise and the
# country's counter still reads zero. Roughly 162 tiles left of 572.
run FI 0.5 "resume, 410/572 tiles already banked"

# Then a launch country. Lithuania has 95 average-speed zones and 768 cameras
# and is the only launch country with no limits at all.
run LT "" "launch country, never started"

run US-NY "" "never started"
run US-MA "" "never started"

# Sweden last. Its bounding box is 14 degrees of latitude, most of it forest,
# so it is far the longest job here and the least urgent.
run SE 0.5 "never started, the long one"

echo "$(date '+%F %T')  queue finished" >> "$LOG"
