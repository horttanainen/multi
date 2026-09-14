# Character animation phase 3A: jumping, falling, landing and crouching

Status: accepted by the user, including the stronger impact, airborne-arm and
held-crouch revision. Validation and independent review passed; commit authorized.
Baseline: `d138623` (accepted movement-driven running and flat-ground planting).

This records the accepted original phase. The subsequent
[kneeling and landing polish](character_animation_kneeling.md) replaces the shared
crouch clip and state described below with separate kneeling and landing clips.

## Behavior

The normal `locomotion` playback now selects five animation states:

| State | Selection and behavior |
| --- | --- |
| Grounded | Existing movement-driven idle/run, cadence, stride and flat-ground toe planting. |
| Jump | Upward airborne movement. Release foot anchors immediately, play the 0.18-second takeoff/tuck clip, then hold its final pose with both hands above the head while rising. |
| Fall | Unsupported downward movement or the jump apex. Blend into the 0.16-second extension clip, lowering the hands toward head/shoulder height, and hold until support returns. |
| Land | Support returns after a fall faster than the configured minimum. Add a 0.36-second crouch/recovery, scaled by incoming fall speed, to the ongoing idle/run pose. Moving legs retain their gait and stance timing. |
| Crouch | Hold Down while supported to hold the low pose of the same crouch clip. The hips stay 0.32 m below the normal gait, and the legs keep walking/running. |

Crouch is a visual state in this animation phase; collision size and movement speed
continue to use the existing gameplay controller. Down already exists in keyboard
and gamepad input and still requests fast falling when airborne.

A jump can interrupt a fall, landing or crouch. Walking off an edge also enters the
falling state; there is no requirement for a jump-button event. Another jump
while already rising retains the current jump clip. Small support interruptions
below the impact threshold return to running/idle without a landing recoil.
Reload, respawn and teleport discard transient action and contact state. Initial
placement on the ground does not invent a landing impact.

The ground probe may still see the floor on takeoff. Animation checks velocity
away from the support normal, relative to that supporting body's point velocity,
before accepting support. This distinguishes jumping from uphill travel or riding
a rising platform. Vertical velocity determines rise/fall and landing strength.
The previous physics sample retains incoming speed when collision resolution
reduces the current downward velocity to zero. Support comes from the existing
movement controller; with sweep grounding, landing may start just before physical
contact. This is a visual response, with no change to collision or jump timing.

Action transitions extend the existing turn-blend mechanism: preserve the previous
control positions, then decay offsets toward the selected clip. Rendering still
interpolates controls and re-solves IK; it preserves bone lengths and reapplies
shared stance/sole-clearance constraints. State selection and surface queries
remain in the fixed physics step.

## Editable assets and ownership

`character_actions/airborne.json` contains the three non-looping clips and their
response settings. It is 225 lines with 91 control keys, interpolated with the
existing Bézier evaluator. The accepted run assets and original dense backup are
unchanged.

The bundle has its own schema version and stable ID. Its `jump`, `fall`, and
`crouch` objects use the existing motion schema: named controls, rig ID, canonical
X-forward/Y-up coordinates, meters, radians, seconds, normalized phase, handles,
and contact intervals. `cycle_seconds` is the duration of each non-looping clip;
`reference_speed_mps` is zero because these actions advance with simulation time.
This makes the clips usable as separate future Blender actions. No Blender
project, exporter or animation editor is introduced in this phase.

The outer settings are:

| Field | Initial value | Purpose |
| --- | --- | --- |
| `blend_seconds` | 0.045 | Exponential response time for action transitions; facing changes retain the run profile's turn response. |
| `takeoff_speed_mps` | 0.2 | Speed away from the support normal that overrides lingering probe support. |
| `min_landing_speed_mps` | 1.0 | Impacts at or below this speed skip the landing clip. |
| `full_landing_speed_mps` | 12.0 | Downward speed that reaches the full authored crouch; larger impacts are clamped to that strength. |
| `crouch_hold_phase` | 0.22 | The normalized phase of the shared crouch clip to hold while Down is pressed. Landing plays through the entire clip. |

The shared crouch clip adds offsets from the rig's neutral controls to the underlying
idle/run pose, scaled by impact strength. Its foot curves equal neutral, so they
add zero and preserve the locomotion foot paths. Lowering the pelvis bends the
knees through the existing IK solver. While moving, the run cycle supplies contact
intent; while standing, the crouch clip can request both feet. Recovery preserves
existing contacts when returning to ordinary locomotion. The contact solver still
requires an actual reachable static floor. Acquired foot positions can remain
slightly wider than neutral, avoiding a slide back into an exact rest stance.

`data.zig` owns all four file reads, generic JSON decoding, shape checks and arena
allocation. `character_animation.zig` validates clip bindings and action-specific
constraints, then installs the entire asset set atomically. A failed read, decode
or validation retains the previous assets and live animation state. The shared
§ menu's reload action reloads the bundle along with the rig/run/profile.

## Validation and review

Use the existing script:

```sh
bash scripts/character_animation_check.sh
```

The focused tests cover existing run regressions, action curve/IK reach, takeoff
with lingering support, the apex, air-jump and landing interruptions, soft and
hard impacts, both facing directions, an airborne turn, settled foot stability,
reset/reload ownership, and invalid action assets. A real Box2D jump runs through
`movement.processSensorEvents` and `character_animation.fixedUpdate`, using the
existing TowerFall grounding profile. That test also checks a rising platform.
Floor clearance, anchor stability and bone lengths are checked at five rendering
fractions between physics steps. A paired-player regression at 0.5 and 9 m/s
compares full landing compression with zero compression: hips lower while the
foot paths and running contact schedule remain the same.

Exact solved positions from the physics test are exported to
`artifacts/character_animation/airborne_samples.json`. The usual test/build/smoke
logs and game capture remain under `artifacts/character_animation/`.
Held-crouch samples at standing, walking and running speeds are in
`artifacts/character_animation/crouch_samples.json`; the current exact pose sheet is
`artifacts/character_animation/crouch_review.svg`.
These automated checks do not replace manual gameplay/visual acceptance.

The independent reviewer inspected the complete phase, its callers, ownership,
shared tooling and applicable repository skills. It reported one actionable
finding:

- **P2, `character_animation_tests.zig`:** the real-physics fixture assigned
  movement settings directly, leaving the derived support-normal threshold
  uninitialized. Fixed by calling the existing `movement.configure` with the
  loaded TowerFall profile before processing contacts.

No other actionable findings were reported. During implementation, visual
inspection also exposed delayed touchdown anchoring; the fall clip's foot angles
were adjusted to allow a toe anchor within the first 0.1 seconds after landing,
and the physics test now checks that recovery. This was an implementing-agent
finding, separate from the independent review. The diagnostic line retains the
existing stride display alongside the new action/vertical-speed information.

During the same phase, the user's gameplay test found that blending the entire
pose toward the landing clip suppressed the gait and caused sliding. The landing
response now adds compression to locomotion and preserves its moving-foot contact
schedule, with the paired-player regression above. This landing correction was
made after the independent pass and received local inspection and automated checks.

The physics fixture supplies velocity and runs actual grounding/animation; it does
not replay the complete player-input/controller update loop. Manual gameplay and
visual acceptance, including buffered input behavior, remain part of user testing.

Previous revision validation: `bash scripts/character_animation_check.sh` passed all 32 tests,
built the game, and completed the five-second smoke run and PNG capture without
warnings, errors or panics. `git diff --check` passed. The regenerated exact poses
were inspected, including the corrected moving landing. A contact sheet is at
`artifacts/character_animation/airborne_review.svg`.

The current revision deepens full crouch to a 0.32 m pelvis drop, lowers the
full-impact threshold to 12 m/s, and uses a shared `crouch` motion for the landing
recovery and held Down state. Ascent now keeps both hands above the head; descent
lowers them toward head/shoulder height. Tests check actual hip-to-floor distance,
held crouch at 0, 0.5, 3.2, 9 and -3.2 m/s, release and airborne overrides, and
the existing input map through `fixedUpdate`.

A fresh independent reviewer inspected the entire current phase against
`d138623` and reported **no actionable findings**. The existing 34 tests, game
build and five-second smoke/capture all passed without warnings, errors or panics.
`git diff --check` passed. The exact crouch/airborne pose sheet was inspected.
The same manual controller/gameplay verification gap described above remains.

## Manual review

Run `zig build run -- --character-animation`. Use § then Z for close view, D for
joint/contact diagnostics, and S for slow motion. P should be on `locomotion`;
the existing neutral and continuous-run modes remain reference views. Diagnostics
now include the action state and horizontal/vertical speed.

1. Jump from standing and while running in both directions. Check takeoff, the
   apex, falling, and the blend back into motion.
2. Drop from different heights, stop on landing, and continue running on landing.
   Check that stronger impacts crouch more and feet settle without persistent motion.
3. Reverse in the air, jump again while falling, and jump immediately after landing.
4. Hold the existing Down movement input while standing and moving; release it to
   stand up. Jumping overrides crouch, and holding Down on touchdown stays crouched.
5. Compare normal speed/gameplay zoom with slow motion/close view. Optionally edit
   the bundle and use § then R to reload it.

Foot planting still covers static flat surfaces. Aiming/grapple attachments,
wall-specific poses, slope/step foot placement, moving-support anchors and rubble
adaptation remain for subsequent agreed phases. Knee/elbow bending uses the
existing planar facing convention.
