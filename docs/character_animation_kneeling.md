# Kneeling and landing polish

Status: accepted by the user, including the aiming correction. Validation and
independent review are complete; commit authorized.
Baseline: `1131fd9` (configurable movement sectors and aiming modes).

## Behavior

- Hold Down while stationary and supported to kneel: rear knee on the ground,
  opposite foot planted forward, torso leaning forward and head low.
- Horizontal input leaves kneeling immediately, even before physics moves the
  body. Existing horizontal travel also prevents entry. Down plus horizontal
  movement uses the ordinary running animation.
- Landing plays its own squat and recovery before a held Down can enter kneeling.
  Impact speed controls compression. When moving, the running foot cycle and
  contact timing continue underneath the lowered hips.
- TowerFall preserves an existing kneel while aim is held, freeing the movement
  stick to aim in any direction. Releasing aim restores the current movement
  input: Down keeps kneeling, neutral stands up, and sideways input runs.
  Aiming down from standing does not start a kneel. Liero's separate movement
  stick continues to control kneeling while the aim stick controls the gun.
- Outside the TowerFall aim hold, releasing Down stands up. Jumping or losing
  support interrupts the stance.
  Wall actions retain their existing priority.

The stationary check reuses `run.json`'s `stop_speed_mps` (0.08 m/s), considers
both measured displacement and current horizontal velocity, and requires zero
horizontal locomotion input. It uses the previously accepted input resolver;
axis thresholds and eight-sector movement are still independently configurable.

The collider and movement speeds remain those of the existing controller.
Kneeling changes the visual pose, so it does not yet lower the hitbox.

## Assets and runtime

`data.zig` owns decoding and storage. `character_animation.zig` validates the
assets, selects states, blends controls and reuses the existing two-bone IK,
flat-ground queries, contact anchors and render interpolation.

`character_actions/airborne.json` uses action-container schema version **2**:
`landing` and `kneel` replace `crouch`; `crouch_hold_phase` is removed. Old action
containers fail validation without replacing the live assets. The nested clips
still use motion schema version 1 and the same named controls, units, sparse
Bezier keys and contact intervals suitable for a later Blender exporter.

The kneel clip takes 0.16 seconds and holds its endpoint. Each track has two eased
keys; contact intent begins near the end of entry. Entering or leaving kneeling
releases the old foot anchors so the feet can adopt the new stance. The landing
clip retains its 0.36-second duration and 0.32 m maximum hip compression, with
forward torso lean. Jump and fall clips are unchanged.

Low poses also check knees against real flat static ground. The fixed update
uses the existing ground query beneath each knee; if needed, a bounded search
raises the pelvis enough to clear the ground while retaining ankle targets and
bone lengths. Rendering interpolates those surface limits and reapplies the
same clearance. This prevents a knee dipping into the floor during an aim turn.
As with existing foot planting, this is flat static terrain support; broader
moving-platform and rubble adaptation remains a later phase.

## Validation and manual review

Use `bash scripts/character_animation_check.sh` for formatting, regression tests,
build and the existing five-second smoke run. Tests cover authored reach and
bone lengths, both facing directions, floor clearance during entry and aiming
turns, contact release, immediate exit on horizontal input, residual travel,
landing priority, ongoing running feet during impact, grip geometry and asset
reload validation. Exact runtime joint samples are written to
`artifacts/character_animation/kneel_samples.json`.

Manual checks:

1. Run `zig build run -- --character-animation`. Stop, hold Down, and check the
   grounded knee, forward foot and low head in both directions. Release Down.
2. Hold Down while starting to run, and while already moving. Check that regular
   running resumes without a crouch walk.
3. Compare a stationary landing with a sideways landing from the same height.
   Both lower the hips; sideways movement keeps stepping. Hold Down on landing:
   impact recovery should come before the stationary kneel.
4. In Tower Keep, kneel first, hold Shoot and aim across the character, including
   up and down. Check that the stance stays low in either aim mode. Release with
   neutral, Down and sideways input; verify the corresponding stance resumes.
   Jumping should interrupt it. In Liero, hold Down with the movement stick and
   aim using the other stick; releasing Down should stand up while still aiming.
5. Press § then M to compare axis thresholds with movement sectors. Mostly Down
   should be easier to hold still in sector mode; diagonal input should run.
   Press § then C to restore the level profile.
6. Jump out of kneeling, and reload animation assets with § then R.

`bash scripts/character_animation_check.sh` passed all 65 tests, built the game
and completed the five-second smoke with the success marker and preview capture.
There were no smoke warnings, errors or panics. `git diff --check` also passed.
The exact runtime pose sheet, `artifacts/character_animation/kneel_review.svg`,
and the game capture were inspected. The game capture checks startup/rendering;
it does not exercise interactive kneeling.

The independent reviewer inspected all eight phase files against `1131fd9`,
including loader ownership, motion validation, IK, foot anchoring, interpolation,
the existing locomotion input resolver and applicable repository skills. It
reported **no actionable findings**. No reviewer corrections were required.

Before review, the implementation tests exposed a knee dipping below the floor
during a kneeling aim turn. The knee-clearance extension above fixes that case;
the regression checks both turn directions and intermediate render frames.
Interactive kneeling, aiming turns and movement feel still need user testing.

## Aiming correction

The initial pose-level aim-turn regression explicitly supplied the kneel request
and missed TowerFall's real input routing: `movement.locomotionDirection` consumes
Down while aiming. The fixed-update adapter now preserves an existing kneel
through that aim hold. It does not change locomotion input or introduce another
input latch; jumping, support loss and motion still use the normal state rules.

Two new regressions use player input, control, movement, Box2D contacts and the
production animation fixed update. They cover free/eight-direction aim, both
facing directions, gun alignment, neutral/Down release, input neutralization,
jump/landing interruption, standing downward aim and Liero's independent sticks.
`bash scripts/character_animation_check.sh` passed all 67 tests, built the game
and completed the five-second smoke and preview capture without warnings, errors
or panics. `git diff --check` passed. The independent correction review covered
the three changed files and relevant input, movement, fixed-step, aiming and
weapon callers; it reported no actionable findings. No reviewer corrections
were required. Interactive controller feel remains for user testing. Sideways
release and support-loss interruption have existing lower-level coverage; the
new integrated tests directly exercise neutral/Down release and jumping.
