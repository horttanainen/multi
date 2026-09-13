# Procedural aiming phase

Implemented against `1337966`, including the user-requested arm extension,
aim-facing, hand-depth and airborne-input revisions. Review and validation results
follow below.
Accepted by the user on 2026-09-13 after review, testing and the revisions above.

This is the accepted aiming phase record. The following
[wall-pose phase](character_animation_walls.md) adds wall contacts and a hip-stowed
weapon during two-hand poses, extending the shared asset load to six files.

## Behavior

In procedural stick/overlay views, the standalone blaster stays attached to the
weapon hand while aiming. The existing two-bone IK moves that arm toward a point
0.545 m from its shoulder in the aim direction (about 15 degrees of elbow bend).
The gun rotates to point along the aim direction. The legs and other arm continue
the underlying running, crouching or airborne motion. Horizontal aim now turns
the character through the existing locomotion
turn transition, preserving valid world-space foot contacts. When momentum carries
the character opposite the aim-facing direction, the stride plays backwards.
Aim within 0.1 of zero on the normalized horizontal axis retains the current
facing to prevent jitter near straight up/down. After release, standing retains
the new facing; renewed travel restores movement-facing after the brief shot hold.
A new aim press without directional input uses the visible character facing.

Left/right hand identity stays anatomical: the rig's `weapon_hand` remains on
`right_hand` through turns. Rendering now exchanges the near/far sides when
facing changes. The right arm draws darker behind the torso when facing right,
and brighter in front when facing left. The blaster follows that hand's depth;
its sprite colors stay unchanged. Legs follow the same depth/shading rule.
The torso/head stay in the player's full color, between far and near limbs.
This corrects the appearance of changing hands caused by always shading the right
arm as the far arm.

Holding Towerfall aim routes live directional input to aiming. When aim begins
in the air, horizontal movement continues with the input from immediately before
the aim press, including neutral input. This uses normal air
acceleration/deceleration and preserves the trajectory as though that direction
were still held. Changing aim cannot change the captured movement direction.

Landing discards the captured input. Grounded aiming supplies no movement intent;
starting aim on the ground then jumping keeps that grounded aiming behavior.
Release resumes live movement input, and neutralization/reset/level cleanup clears
the capture. Supplied input magnitudes are preserved, although the current gamepad
movement sampler digitizes its axes to -1/0/1.
Aim-down cannot crouch or fast-fall. The captured horizontal input still follows
normal wall interaction, and forced wall-jump movement keeps its existing priority.
Ground deceleration, gravity, knockback and independent jump-button input continue
normally. The same policy applies in sprite-only view; Liero retains its existing
movement policy.

The arm raises over 0.09 seconds. On release, firing uses the full aiming pose and
the captured release direction, even for a quick tap. A successful shot holds that
pose for 0.06 seconds and lowers toward the running/airborne hand over 0.14 seconds.
This adds no firing delay. The aim guide follows the currently displayed barrel
during raising; an early release completes the aim for the shot. Re-pressing aim
resumes the live aim, while any queued release retains its own direction.

## Shared owners and data

- `movement.locomotionDirection` owns the Towerfall directional-input policy and
  is reused by control, movement and animation through player IDs. It resolves
  live versus captured input and cancels the capture when grounded. Landing
  contacts, movement reset and level cleanup also clear it, so this does not
  depend on the procedural renderer or an input poll before the next physics step.
  Fixed movement keeps the lateral intent used by friction in sync.
- `player_input` captures release direction alongside its existing button edges.
  It also saves the previous horizontal movement input on an aim press, before
  overwriting it with the new sample, and clears it on release/neutralization.
  `control` consumes that edge once per fixed step through the existing firing path.
  Input neutralization cancels queued releases.
- `character_animation` owns aim weights, a brief shot hold and continuous weapon
  rotation in its existing per-player state. It reuses the pose evaluator,
  attachment transforms and arm IK. No physics joints or second animation engine
  are introduced.
- `player.weaponFrame` combines the character pose and selected visual with the
  existing `sprite.placeAtAnchor`/`placedPoint` geometry. Drawing and aim guides use
  interpolated rendering state; shooting uses current physics state. Muzzles are
  calculated in world pixels before camera conversion, so camera movement and
  render alpha cannot redirect a shot.
- `weapons.json` renames `carriedSprite` to optional `standaloneSprite`. The legacy
  weapon-with-arm sprite remains the fallback in sprite-only mode or for weapons
  without a standalone visual. Existing sprite creation, atlas backing, marker
  validation and cleanup are retained.
- `data.zig` loads the new profile through the existing strict, bounded character
  JSON loader. All five character files share the same candidate arena and atomic
  validation/replacement. Failed reloads preserve assets and transient animation;
  successful reloads reset transient state.

`character_actions/aiming.json` has schema version 1, stable ID `aiming_v1`,
`rig_id: humanoid_v1`, `distance_unit: meters`, and `time_unit: seconds`:

| Field | Default | Meaning and validation |
| --- | --- | --- |
| `hand_distance_m` | 0.545 | Shoulder-to-hand target distance; strictly inside the selected weapon arm's validated IK reach interval. |
| `raise_seconds` | 0.09 | Time from carrying to fully aimed; 0.01–1 s. |
| `lower_seconds` | 0.14 | Time from fully aimed back to carrying; 0.01–1 s. |
| `shot_hold_seconds` | 0.06 | Full aiming pose held after a successful shot; 0–0.5 s. |

Use **§ → R** to reload changes. The rig's `weapon_hand` attachment continues to
select the hand and grip offset. Its wrist angle offset affects carrying; full
aim determines the barrel direction independently. These small named settings can
be future Blender custom properties; direction, blending and final solved elbows
remain runtime state. Existing authored motion curves are unchanged.

## Validation and review

Use `bash scripts/character_animation_check.sh` for formatting, the character
tests, build and five-second smoke/capture. Added tests cover both facings and
eight aiming directions across action poses, fixed limb lengths, near-straight
aiming elbows, unchanged legs within the arm solve, aim-driven turns, backwards
stride/contact playback, near-vertical facing stability and neutral re-aim,
grip placement, continuous lowering across running phases, real movement input
suppression, jumping, camera-independent shot geometry, quick taps/re-presses,
weapon switching, cancellation, death, and failed/successful profile replacement.
The airborne-input regression compares real Box2D positions and velocities through
landing against continuing the earlier input, across both directions, analog
magnitudes and neutral input, with multiple physics steps between input polls.
It also checks a subsequent jump while aim remains held, release/re-press,
neutralization, reset, retaining controller input across movement cleanup/recreation,
and beginning aim on the ground. Fractional sample coverage tests the input
pipeline; the current gamepad sampler itself supplies digital movement directions.
The firing test runs the real control/player/weapon path with silent dummy SDL
audio and inspects the resulting hitscan trails.

Native pose samples are exported to `artifacts/character_animation/aim_samples.json`.
The inspected `aiming_poses.svg`/`aiming_poses.png` diagram combines those solver
coordinates with the source blaster SVG and current facing-dependent depth/shading;
no image generation was used. This illustrates static poses, not live rendering.

Current revision validation: **47/47 tests passed**, the game built, and the
five-second procedural locomotion smoke passed with its success marker and
screenshot capture, without warnings, errors or panics. Evidence is in
`artifacts/character_animation/`: `tests.log`, `build.log`,
`aiming_air_input_smoke.log`, and `preview.png`. `git diff --check` passed.
The static aiming diagram and pose rendering are unchanged by this input fix;
their visual inspection belongs to the preceding hand-depth revision.

The initial phase passed 44/44 tests and procedural/sprite-only smoke runs;
`aiming_smoke.log`, `aiming_legacy_smoke.log`, and `aiming_legacy.png` retain that
evidence. The sprite-only placement path is unchanged in this iteration.

Before independent review, implementation checks found and corrected a possible
rotation discontinuity when lowering from backwards aim across the moving wrist's
angle wrap. Fixed-step continuous rotation and a regression across gait phases,
both facings and render interpolation cover that transition.

The initial independent reviewer inspected the complete phase against `1337966`
and found **no actionable findings**. The pass covered production input/physics ordering,
release capture and cancellation, movement filtering, IK and attachment geometry,
both weapon placement paths, sprite/Liero fallbacks, strict JSON loading, atomic
replacement, initialization/cleanup, shared component reuse, and applicable
repository skills. No review corrections were needed in that pass. This predates
the requested arm-extension and aim-facing revision. The reviewer inspected
the test/build/smoke evidence and native pose diagram and ran no mutating checks.

A fresh independent pass reviewed the six revision files against their saved
pre-iteration copies and traced their input, firing, registration/reset and
rendering callers. It found **no actionable findings**, including no applicable
style, guard-clause or logging violations. The optional suggestion was to verify
interpolated toe-to-anchor stability during backpedaling, beyond counting locked
contacts. That improvement was implemented by reusing the existing pose/clearance
test helper and requiring sustained contacts so the assertions execute. The full
45-test/build/smoke script passed again after this improvement.

The hand-depth correction received a separate independent review against its
pre-iteration snapshots. It found **no actionable code findings** and verified
anatomical limb identity, attachment selection, facing-dependent shade/depth,
torso/head layering, sprite/GPU draw order and applicable repository skills.
One **P3 documentation finding** was fixed: the text had implied the blaster
itself changes brightness. It now distinguishes limb shading from weapon depth;
the sprite's colors remain unchanged. The existing 45 tests, build and five-second
smoke passed, and both the game capture and updated static pose sheet were
inspected. No solver/asset changes or new renderer-specific tests were needed.

The airborne-input correction received a fresh independent review of the seven
revision files and their input, fixed-step, wall-jump, landing and lifecycle
callers. It found one **P2 bug**: captured movement survived level cleanup because
controller input registrations are retained across level reloads. Movement cleanup
now clears the capture, and the lifecycle regression recreates movement state
while aim remains held to verify that the previous jump's input stays cancelled.
An optional documentation correction also clarifies that fractional input samples
are supported internally, while the current gamepad sampler supplies digital
movement directions. All 47 tests, the build and the five-second smoke passed
again after these corrections. The reviewer inspected validation evidence without
running mutating checks; live controller feel and wall interactions remain manual
verification.

Remaining verification is controller feel and live visual transitions, especially
rapid aim changes, limb/weapon overlap during turns, and release while moving.
The sprite-only smoke establishes
startup/rendering; the new automated firing test exercises the procedural path.
Interactive legacy firing is included in the user checklist below. Review and
automated checks do not replace user acceptance.

## User testing

1. Run `zig build run -- --character-animation`. Use **§ → Z** for close view,
   **§ → S** for slow motion, and **§ → R** after editing the aiming profile.
2. Hold aim from rest and sweep every direction. The blaster should follow aim,
   with the same right hand on its handle: darker behind the torso when facing
   right, brighter in front when facing left. Directional input should not start running.
3. Aim while running or airborne, including backwards and downwards. Momentum
   and gravity should continue; legs should follow motion. In a jump, compare
   holding Right throughout with holding Right then entering aim and pointing
   Left: the trajectory should match until landing. Release aim to steer again,
   and verify landing/re-jumping while holding aim does not reuse that input.
   Reload the level with **Ctrl+R** while holding airborne aim and verify that the
   new character does not inherit the previous jump's directional input.
   Aiming down should
   not crouch or fast-fall. The character should turn toward horizontal aim,
   including while stationary, and retain its facing near vertical aim. Jump
   should still work while aim is held.
4. Release to fire, including quick taps and switching weapons. The shot should
   leave the aimed muzzle before the hand returns to its ordinary animation.
5. Switch to sprite-only view with **§ → V** and check legacy aiming/firing.

Grappling arm priorities, wall poses, further terrain support and Blender tooling
remain separate planned phases.
