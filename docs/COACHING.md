# The coaching engine

Everything here lives in `ios/Packages/GlidePathCore` and is covered by
`swift test`. If you change a number in this document, change it in
`SafetyPolicy` and in the tests too.

## The equation

A zone is a distance and a limit. The fastest you may legally cover it is:

```
minLegalTime = zoneDistance / limit
```

At any moment inside the zone:

```
remainingBudget = minLegalTime - timeSpent
distanceLeft    = zoneDistance - distanceCovered
maxRemainingAvg = distanceLeft / remainingBudget
```

`maxRemainingAvg` is the highest average you may hold from here and still exit
legal. `timeSpent` runs from the interpolated entry crossing, and
`distanceCovered` is measured along the road by projecting each fix onto the
zone polyline.

### Why the allowance behaves backwards

The relationship is a ratio, so it moves in the direction people do not expect.

A **large** remaining budget over a **small** remaining distance gives a **low**
allowance. That is not a bug: it is the driver who sped early. They have used up
very little of the clock and have almost no road left to use it up on, so they
must dawdle.

Worked example. A 10 km zone at 100 km/h, so `minLegalTime` is 360 seconds.
Cover 9 km at 150 km/h and that took 216 seconds:

```
remainingBudget = 360 - 216 = 144 s
distanceLeft    = 1000 m
maxRemainingAvg = 1000 / 144 = 6.94 m/s = 25 km/h
```

The last kilometre has to be driven at 25 km/h. Which is why the third tier
exists.

### When the budget goes negative

`remainingBudget <= 0` means the driver has already spent longer in the zone
than the minimum legal time. The exit camera cannot catch them whatever they do
next, because time only moves forwards. The allowance becomes unconstrained and
the app coaches the posted limit — never anything faster.

## The tiers

Let `floor` be the safety floor for the zone (below).

| Condition | Tier | Target |
| --- | --- | --- |
| Budget spent, or no distance left | Normal | the limit |
| `maxRemainingAvg >= limit - tolerance` | Normal | the limit |
| `floor <= maxRemainingAvg < limit - tolerance` | Tight | `maxRemainingAvg`, rounded **down** to 5 km/h |
| `maxRemainingAvg < floor` | Impossible | `floor`, plus a recovery |

### Why the normal tier has a tolerance

Hold exactly the posted limit and the allowance works out to exactly the limit
at every point in the zone. `distanceLeft / remainingBudget` stays pinned to the
limit the whole way, so comparing the two without slack sits on a knife edge and
the tier flips on floating-point noise. Real GPS noise makes that worse, not
better.

Without the tolerance the app told a driver doing a perfectly legal 100 to slow
to 95, then to hold 100, then to slow to 95 again, for the length of the zone.
Half a km/h of slack is below anything a driver can hold and far below the
enforcement margin on any real camera, and it costs a fraction of a second of
margin across a whole section.

Rounding is always down. Rounding 82.4 up to 85 would coach the driver into the
fine the app exists to prevent; rounding down to 80 costs a few seconds.

## The safety floor

**This is a hard rule and it is not user-adjustable.**

```
floor = min(
  max(30, limit * 0.5, postedMinimum ?? 0),
  limit
)
```

- An absolute floor of 30 km/h, on any road, ever.
- Never below half the posted limit. On a 110 km/h road that is 55.
- Never below a posted legal minimum where one exists.
- Capped at the limit itself, so a 20 km/h zone does not end up with a "floor"
  above its own limit.

The reason it exists: a naive implementation of this product will tell someone
to do 18 km/h in the outside lane of a motorway, because the arithmetic said so.
That is more dangerous than the fine. `CoachingTierTests` sweeps the entire
input space asserting no advice ever falls below it or rises above the limit.

## The impossible tier

Driving cannot save the section, so the only remaining lever is stopping the
clock. The pause needed is:

```
pause = remainingBudget - (distanceLeft / limit)
```

which is the time you must add on top of driving the rest at the limit. It is
guaranteed strictly positive whenever the tier is reached.

The engine then looks for a rest stop inside the zone that is more than 150
metres ahead of the driver — closer than that and the sentence would not finish
before they passed it. If it finds one, it offers the stop and the duration. If
it does not, it says the zone is lost and tells the driver to carry on normally,
because coasting around looking for somewhere to pull in is its own hazard.

The pause figure assumes the driver resumes at the posted limit, which is what
people actually do. Crawling afterwards would need slightly less, so the number
errs generous.

## Traffic

Below 10 km/h (smoothed) coaching is suppressed. A target speed is noise to
someone who cannot move, and stopped time is handing the allowance back anyway:
`timeSpent` grows while `distanceCovered` does not, so `maxRemainingAvg` rises.

The announcer forgets what it last said while suppressed, so when the traffic
clears the driver gets a fresh instruction rather than silence because the tier
happens to match something announced ten minutes earlier.

An unknown speed is **not** treated as stationary. A receiver that withholds
speed would otherwise silence the app for the whole drive.

## When to actually speak

`CoachingAnnouncer`, in priority order:

1. Silence in a jam.
2. Never talk over yourself: a 6 second minimum gap between utterances.
3. Always speak a tier change. "You are fine" to "you need to slow down" is the
   single most important thing the app ever says.
4. Speak a target that has moved by 5 km/h or more.
5. Otherwise repeat on a timer: 45 s when tight, 60 s when impossible, 120 s
   when normal.

## Detecting the boundaries

**Entry and exit crossings are interpolated**, never taken from the geofence
wake-up:

```
fraction = -distanceBefore / (distanceAfter - distanceBefore)
crossing = timeBefore + fraction * (timeAfter - timeBefore)
```

Using the wake-up time would start the clock early, which inflates elapsed time,
which inflates the allowance, which coaches the driver faster than they can
safely go. The error runs in exactly the wrong direction.

If the first fix is already past the line — the app was launched mid-zone — the
fix time is used. That is late rather than early, which tightens the allowance
rather than loosening it, and is therefore the safe way to be wrong.

**Deviation** needs 60 metres of cross-track distance sustained for 5 continuous
seconds. One fix back on the path resets the clock completely. A single stray
fix happens under every bridge and in every car park, and cancelling a session on
one would make the app infuriating on the roads it is built for.

## Parameters in one place

All of these are `SafetyPolicy`:

| | Default |
| --- | --- |
| Absolute floor | 30 km/h |
| Fraction of limit floor | 0.5 |
| Jam suppression | below 10 km/h |
| Deviation distance | 60 m |
| Deviation confirmation | 5 s |
| Speed smoothing window | 4 s |
| Limit tolerance | 0.5 km/h |
| Worst usable fix accuracy | 50 m |
| Zone entry geofence radius | 750 m |
