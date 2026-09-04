# TowerFall movement reference

This document records the reference measurements and initial tuning targets for
the TowerFall-style movement controller. It is a calibration reference, not a
claim that the original game's source constants are known.

Measured on 2026-09-04 from:

- [TowerFall Ascension Gameplay (PC HD) [1080p60FPS]](https://www.youtube.com/watch?v=taMd8hnqqgs)
- [TowerFall Wiki: How to Play](https://towerfall.wiki.gg/wiki/How_to_Play)
- [TowerFall Ascension TAS notes](https://tasvideos.org/6104S)
- [Celeste and TowerFall Physics](https://www.mattmakesgames.com/articles/celeste_and_towerfall_physics/index.html)

## Measurement method

The downloaded gameplay was kept outside the repository in temporary storage.
The useful 720p sample contains 1,771 frames over 30.02 seconds, approximately
59 frames per second. Only 33 frames were detected as near-duplicates.

The TowerFall playfield is a 320 x 240 native image enlarged exactly three times
inside the 720p recording. Measurements were reduced to native pixels before
calculating velocity and acceleration. TowerFall tiles are 10 x 10 pixels.

The Tower Keep level maps one 10-pixel TowerFall tile to one engine world unit.
The codebase currently calls that world unit a metre. These are gameplay units,
not a claim that the movement follows real-world SI physics.

## Measured starting values

| Property | TowerFall units | Engine units | Confidence |
| --- | ---: | ---: | --- |
| Maximum running speed | about 1.5 px/frame | about 9 units/s | high |
| Time to maximum running speed | about 6-9 frames | 0.10-0.15 s | medium |
| Downward acceleration | about 0.30 px/frame^2 | about 108 units/s^2 | high |
| Normal terminal fall speed | about 3 px/frame | about 18 units/s | high |
| Initial jump speed | about 3.2-3.3 px/frame upward | about 19-20 units/s upward | medium |
| Ordinary jump rise | about 18-20 px | about 1.8-2.0 units | medium |
| Time to jump apex | about 10-12 frames | 0.17-0.20 s | medium |
| Same-height jump duration | about 21-24 frames | 0.35-0.40 s | medium |
| Ordinary dodge distance | about 29-32 px | about 2.9-3.2 units | medium |
| Ordinary dodge duration | 20 frames | 0.333 s | high; documented |

At 60 Hz, the rounded gravity target follows directly from the native value:

```text
0.30 px/frame^2 * 60^2 frames^2/s^2 / 10 px/unit = 108 units/s^2
```

This large number is intentional for a responsive arcade jump. With an upward
speed near 19.5 units/s it produces an apex in roughly 0.18 seconds and a jump
height near 1.8 units. This acceleration belongs to the TowerFall controller;
it must not replace level gravity for rubble, projectiles, giblets, or other
physical objects.

## Documented timing windows

The following values come from the TowerFall Wiki rather than video inference:

| Behaviour | Frames at 60 Hz | Time |
| --- | ---: | ---: |
| Jump input buffer | 6 | 0.100 s |
| Stored/coyote jump | 6 | 0.100 s |
| Stored jump after a dodge | 12 | 0.200 s |
| Wall-jump forced movement | 12 | 0.200 s |
| Ledge-slip delay | 4 | 0.067 s |
| Normal dodge | 20 | 0.333 s |
| Maximum held/stall dodge | 25 | 0.417 s |
| Dodge cooldown after the dodge | 25 | 0.417 s |
| Earliest dodge cancel | after 2 | 0.033 s |

A ledge slip is valid when the player is three native pixels or less onto the
ledge. With the Tower Keep mapping this corresponds to 0.3 world units.

## Behaviour confirmed by references

- Holding jump produces a higher jump than releasing it early.
- Holding down while airborne produces a fast fall.
- Holding toward a wall reduces downward speed and enables a wall jump.
- A wall jump forces movement up and away from the wall for 12 frames.
- A dodge starts fast and decelerates rapidly.
- Cancelling a dodge preserves the velocity at the cancellation point.
- Ground friction removes retained dodge speed faster than air resistance.
- A dodge-slide is faster than an ordinary dodge.
- Ledge cling, ledge slip, jump buffering, stored jumps, and dodge cancellation
  are intentional controller mechanics rather than consequences of rigid-body
  friction.

## Values still requiring calibration

The available footage has no input display, so it cannot identify the exact
button press and release frames. The following values must remain configurable
and should be calibrated through play testing:

- Ground acceleration and braking rates within the measured response window
- Air acceleration, braking, and retained-momentum behaviour
- Short-jump cutoff and held-jump duration
- Fast-fall acceleration and terminal speed
- Wall-slide terminal speed
- Wall-jump horizontal speed
- The per-frame dodge and dodge-slide speed curves
- Ledge-cling positioning and release behaviour

The implementation should start from the high-confidence values above. Medium-
confidence values are initial tuning targets, not compatibility requirements.
