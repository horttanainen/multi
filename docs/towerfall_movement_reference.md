# TowerFall movement reference

This document records the reference measurements and initial tuning targets for
the TowerFall-style movement controller. It is a calibration reference, not a
claim that the original game's source constants are known.

Measured on 2026-09-04 from:

- [TowerFall Ascension Gameplay (PC HD) [1080p60FPS]](https://www.youtube.com/watch?v=taMd8hnqqgs)
- [TowerFall Wiki: How to Play](https://towerfall.wiki.gg/wiki/How_to_Play)
- [TowerFall Ascension TAS notes](https://tasvideos.org/6104S)
- [Celeste and TowerFall Physics](https://www.mattmakesgames.com/articles/celeste_and_towerfall_physics/index.html)

Movement measurements were refined on 2026-09-05 using locally recorded native
gameplay captures of held and tap jumps, normal and accelerated falling, runs
from rest, stopping, and direct reversals.

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
| Ground acceleration from rest | about 0.15 px/frame^2 | about 55 units/s^2 | high |
| Ground reversal braking | about 0.25 px/frame^2 | about 90 units/s^2 | medium |
| Effective full reversal | about 0.19 px/frame^2 | about 69 units/s^2 | high |
| Ground stopping | about 0.25-0.27 px/frame^2 | about 90-97 units/s^2 | medium |
| Released-jump gravity | about 0.297 px/frame^2 | about 107 units/s^2 | high |
| Held-jump gravity | about 0.164 px/frame^2 | about 59 units/s^2 | high |
| Fast-fall acceleration | about 0.36 px/frame^2 | about 129 units/s^2 | high |
| Normal terminal fall speed | about 2.799 px/frame | about 16.8 units/s | high |
| Accelerated terminal fall speed | about 3.501 px/frame | about 21.0 units/s | high |
| Initial jump speed | about 3.3 px/frame upward | about 20 units/s upward | high |
| Tap-jump rise | about 19-21 px | about 1.9-2.1 units | high |
| Held-jump rise | about 34-36 px | about 3.4-3.6 units | high |
| Tap-jump duration | about 23 frames | about 0.38 s | high |
| Held-jump duration | about 42 frames | about 0.70 s | high |
| Ordinary dodge distance | about 29-32 px | about 2.9-3.2 units | medium |
| Ordinary dodge duration | 20 frames | 0.333 s | high; documented |

At 60 Hz, the rounded gravity target follows directly from the native value:

```text
0.30 px/frame^2 * 60^2 frames^2/s^2 / 10 px/unit = 108 units/s^2
```

This large number is intentional for a responsive arcade jump. The recordings
show that releasing Jump switches to this gravity rather than directly cutting
upward velocity. While Jump remains held, the jump uses approximately 59
units/s^2 during both ascent and descent. This acceleration belongs to the
TowerFall controller; it must not replace level gravity for rubble,
projectiles, giblets, or other physical objects.

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

- Air acceleration, braking, and retained-momentum behaviour
- Exact input-release frames within a tap jump
- Wall-slide terminal speed
- Wall-jump horizontal speed
- The per-frame dodge and dodge-slide speed curves
- Ledge-cling positioning and release behaviour

The implementation should start from the high-confidence values above. Medium-
confidence values are initial tuning targets, not compatibility requirements.

## Implementation roadmap

The controller is implemented in commit-sized phases. Each phase is reviewed
before it is committed and work begins on the next phase.

### TF-0: Reference measurements

Measure run acceleration, top speed, stopping, reversal, short and held jumps,
time to apex, normal and fast-fall terminal speed, wall sliding, wall jumping,
and every frame of dodge and dodge-slide displacement from 60 FPS reference
footage. Record the measurements without changing game behaviour.

### TF-1: Input foundation

Add mechanism-independent player input containing:

- Two-dimensional movement direction.
- Jump pressed, held, and released states.
- Dodge pressed, held, and released states.
- Distinct queued dodge presses so rapid cancellation is representable.
- Down input for crouching and fast-falling.

Queue input edges until a fixed physics step consumes them so short presses are
neither lost nor processed twice.

### TF-2: TowerFall body policy and basic movement

Add the TowerFall movement mechanism and its JSON profile. TowerFall players use
a dynamic, non-rotating Box2D body with zero player gravity scale and zero
physical contact friction. The controller accelerates toward its configured run
velocity, uses distinct ground and air control, applies explicit stopping and
reversal, and preserves externally gained speed above ordinary run speed rather
than clamping it immediately. Non-player objects continue using level gravity.

### TF-2.5: TowerFall controls and aiming

Match TowerFall's control arrangement while retaining the intentional Liero
control model:

- TowerFall movement and eight-direction aiming share the left stick or movement
  keys.
- Holding Shoot enters aiming and releasing Shoot fires exactly once.
- TowerFall shooting consumes the queued release edge during a fixed physics
  step.
- Liero retains separate movement and aim controls and hold-to-fire behaviour,
  but its firing is also processed during fixed physics steps.
- Replace gameplay crosshairs in both controllers with a player-coloured aim
  guide that begins at the weapon muzzle and fades over a configurable distance
  measured in world units.
- Keep the level-editor cursor independent from gameplay aiming.

Movement-state interactions caused by aiming remain part of TF-12.

### TF-3: Gravity and falling

Implement controller-owned vertical motion:

- Normal gravity.
- Maximum fall speed.
- Fast-fall while holding Down.
- A faster transition toward fast-fall speed.
- Grounding resets controlled vertical motion.
- External downward momentum recovers gradually instead of being erased
  abruptly.

Level gravity remains unchanged for rubble, giblets, projectiles, and other
physics objects.

### TF-4: Variable jump

Implement:

- Jump launch velocity.
- Lower gravity during both ascent and descent while Jump remains held.
- An immediate return to normal gravity when Jump is released.
- A six-frame/100 ms input buffer.
- A six-frame/100 ms stored or coyote jump.
- A twelve-frame/200 ms stored jump following a dodge.
- No ordinary air jumps.
- Press-edge handling in place of the old 500 ms repeat-prevention mechanism.

The twelve-frame stored jump is connected when the dodge and cancellation
states exist in TF-9 and TF-11. TF-4 does not add unused placeholder dodge
state merely to start that window early.

### TF-5: Wall slide

Use the existing wall contacts to enter a wall slide only while airborne and
holding toward a wall. Cap downward movement to the configured wall-slide speed
and exit immediately when input moves away or contact is lost. Merely touching
a wall must not grant a generic air jump.

### TF-6: Wall jump

Implement wall jumping independently from wall sliding:

- Jump upward and away from either wall.
- Force outward movement for exactly twelve frames.
- Restore air control after the commitment window.
- Support rapidly alternating wall jumps.
- Add only the small corner correction that Box2D contacts prove necessary.

### TF-7: Crouching

Implement grounded Down input, a reduced crouching collider, and safe standing
collider restoration only when there is headroom. Crouching is the prerequisite
for dodge-sliding, with appropriate transitions when leaving a platform.

### TF-8: Ledge interaction

Implement:

- Ledge detection using dedicated upper-body probes.
- Clinging while holding toward an exposed ledge.
- Indefinite holding without gravity.
- A straight-up jump when continuing toward the ledge.
- An away-facing wall jump when reversing input.
- Release when shooting.
- Down-to-slip within 0.3 world units of the edge.
- A four-frame slip delay.

### TF-9: Core dodge

Implement the eight-direction dodge state:

- Use movement direction, or facing direction while neutral.
- Apply high initial speed followed by the measured rapid decay.
- Disable ordinary steering and gravity during the active dodge.
- Use a normal duration of twenty frames.
- Let holding Dodge extend it to twenty-five frames and end at rest.
- Apply a twenty-five-frame cooldown after completion.
- Expose the state for later projectile-catching behaviour.

### TF-10: Dodge-slide

Implement Down plus horizontal Dodge as a separate crouched slide. It is faster
and travels farther than an ordinary dodge, uses the crouching collider, and
does not begin falling after leaving an edge until the slide finishes. Restore
the correct standing, crouching, or airborne state afterward.

### TF-11: Dodge cancellation and advanced movement

Build consistent state and momentum transitions that naturally produce:

- Tap-cancelled dodge or hyper-dash.
- Jump-cancelled dodge.
- Super jump.
- Hyper jump.
- Upward dodge as a limited second lift.
- Momentum retention at the cancellation frame.
- Wall jumping during a dodge without automatically cancelling the dodge.

These behaviours must emerge from shared cancellation and momentum rules rather
than individually hard-coded actions.

### TF-12: Combat interaction

Connect movement states to gameplay:

- Dodge catching or deflecting appropriate projectiles.
- Dodge vulnerability during cooldown.
- Stomping.
- Ground aiming prevents walking.
- Air aiming removes steering without erasing momentum.
- Shooting releases a ledge cling.
- Explosion and weapon impulses remain effective during ordinary movement.

Weapons do not all need to become TowerFall arrows, but their movement-state
interactions should match.

### TF-13: Calibration and polish

Compare fixed-step trajectories with the recorded reference measurements:

- Position per frame.
- Apex frame and height.
- Landing frame.
- Run acceleration and reversal.
- Wall-jump displacement.
- Dodge distance and cancellation velocity.

Tune only the TowerFall movement JSON unless a discrepancy is caused by
controller logic. Debug measurement gathering remains disabled by default.

## Post-controller follow-up phases

### TF-14: Separate camera look-ahead

Replace the camera's dependency on the legacy shared aim offset with dedicated
camera look-ahead behaviour:

- Give camera look-ahead its own configuration instead of deriving it from the
  former crosshair distance.
- Express the look-ahead distance in world units so it remains consistent when
  a level changes `pixelsPerMeter`.
- Define separately when each controller requests look-ahead: continuous aim
  for Liero and active hold-to-aim for TowerFall.
- Preserve camera smoothing while making its strength and maximum displacement
  independent of weapon guides and spray-paint range.
- Apply the same explicit policy to shared-camera and split-screen modes where
  look-ahead is appropriate.

This phase changes camera framing only and must not change projectile direction,
weapon range, or movement physics.

### TF-15: Separate spray-paint targeting

Replace spray painting's dependency on the legacy shared aim offset with its own
world-space targeting:

- Give spray painting a dedicated range expressed in world units.
- Calculate its target directly from the player's world position and aim
  direction rather than from a camera-relative pixel position.
- Decide explicitly whether zoom modifies spray range; remove the accidental
  doubling inherited from crosshair zoom unless it is retained as an intentional
  configurable rule.
- Keep the existing overlap query and surface-painting behaviour after the
  target point has been calculated.
- Remove `getAimOffset`, `aimMaximumDistancePixels`, and
  `aimRestingDistancePixels` after camera and spray painting no longer use them.

This phase changes spray targeting only and must not affect the hologram aim
guide or camera framing.

## Completion criteria

The controller is complete when:

- Liero levels retain their intended movement and control feel while sharing
  improved engine-level input scheduling where appropriate.
- Tower Keep uses its own TowerFall profile.
- Short and held jumps match the reference trajectories.
- Wall movement and dodge windows match the documented frame counts.
- Advanced movement emerges from cancellation and momentum preservation.
- Explosions and dynamic objects still influence the player.
- TowerFall movement never depends on player mass or Box2D contact friction.
- Gameplay tuning remains in JSON.
