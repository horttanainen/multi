# Carried blaster phase

Accepted by the user after implementation, independent review and validation.

This is the accepted carried-weapon phase record. The following
[aiming phase](character_animation_aiming.md) supersedes its aiming fallback and
renames the optional weapon field from `carriedSprite` to `standaloneSprite`,
because the same arm-free sprite is now used while carrying and aiming.

## Result and scope

The procedural stick/overlay character carries a standalone alien blaster with a
large muzzle, visible trigger guard and grip. The selected weapon's existing
projectile, damage, timing and sound behavior remain in place. All four existing
weapons currently share this prototype visual, just as they share the legacy one.

The solved animated hand drives the grip position and rotation during running,
crouching, jumping, falling and landing. There is no second gun-sway animation.
Reference/neutral playback uses the same attachment calculation as locomotion.
The sprite is inserted at its hand's depth, with the colored hand drawn over the
handle. Limb identity stays independent of facing.

This phase covers carrying. Holding aim still uses the original weapon-with-arm
sprite and placement; releasing it returns to the carried visual. Sprite-only
view also retains the original visual. The next agreed commit will replace the
aiming pose with this blaster, aim-driven arm IK, and movement-input suppression.
It must preserve momentum and normal physics, route directional input exclusively
to aiming, keep aim-down separate from crouch/fast-fall, and use the final aim pose
for release-to-fire before blending back to carrying. Grappling follows later.

## Reused components and editable data

- `weapons/alien_blaster/weapon.svg` is the deterministic, editable artwork, loaded
  directly by the existing SDL image loader. It contains no arm. The 160×96 canvas
  has a magenta grip marker at (49,64) and alpha-1 cyan muzzle marker at (151,35).
- `sprites.json` defines its 0.36 m canvas height (0.60 m width), atlas profile and
  marker extraction. `weapons.json` opts into it through optional `carriedSprite`.
  Sprite and weapon artwork changes take effect on restart.
- `data.zig` owns the optional weapon field and its strings, loads the carried
  sprite through the existing factory, and validates both required markers at
  creation. The carried sprite uses immutable atlas backing and existing cleanup.
- The `weapon_hand` rig attachment selects either hand. Its `local_offset` is
  relative to the incoming forearm (+X along it, +Y counterclockwise). Optional
  `angle_offset_radians` defaults to zero and rotates the weapon relative to that
  forearm; positive is counterclockwise in the canonical Y-up rig. Changing it
  does not move the grip. These fields reload with **§ → R** and can be exported
  by the future Blender workflow without altering motion clips.
- `character_animation.zig` derives the attachment from the final interpolated
  IK pose, then converts position and rotation to the world/facing convention.
  It validates the named hand and angle during atomic rig preparation.
- `sprite.zig` now owns shared anchor placement and transformed marker positions.
  The legacy weapon drawing and muzzle calculation use this same geometry.
  Muzzle extraction uses SDL's pixel format interpretation for candidate colors,
  covering both the SVG decoder's RGBA and the PNG decoder's BGRA layouts.

The attachment itself is continuous. Drawing uses the existing integer sprite
pixel coordinates, with the colored hand overlapping the grip to cover rounding
at the sprite boundary. This phase adds no motion channels or dense samples.

## Review and validation

Use `bash scripts/character_animation_check.sh` for formatting, character tests,
build, and the five-second game smoke/capture. The added checks cover source
markers in both new SVG and legacy PNG, mirrored/rotated grip and muzzle geometry,
interpolated wrist transforms across locomotion/action transitions, view/aim
selection, and invalid attachment reload preservation. Existing 34 tests remain.

Independent review of the entire phase against `d1bbd62` found **no actionable
findings**. It covered repository skills and existing component reuse, sprite
creation/ownership/cleanup, JSON and failed replacement, attachment and sprite
transforms, hand layering and legacy weapon placement. No review corrections
were needed. During implementation, the asset test exposed the SVG/PNG pixel
layout difference; that was fixed in the shared marker extractor before review.

Completed validation: **38/38 tests passed**, build passed, and five-second smoke
runs passed in locomotion, reference run, and sprite-only views with captures and
no warnings, errors or panics. `git diff --check` passed. Logs and screenshots
are under `artifacts/character_animation/`: `tests.log`, `build.log`,
`smoke_locomotion.log`, `smoke_reference.log`, `smoke_legacy.log`, `preview.png`,
`blaster_reference.png` and `blaster_legacy.png`.

The reviewer inspected the locomotion/reference evidence; the sprite-only smoke
completed afterward without implementation changes. Interactive aiming/release,
weapon switching, live wrist-angle reload and player-controlled transition feel
remain manual acceptance checks. The native pose/geometry tests cover the
underlying transforms and selection, not every interactive sequence.

## User testing

1. Start `zig build run -- --character-animation`.
2. Run left/right, stop, turn, jump, land, and hold Down to crouch. The handle
   should follow the weapon hand without detaching; the barrel follows the wrist.
3. Use **§ → Z** for close view, **§ → S** for slow motion, and **§ → P** to cycle
   locomotion, neutral and reference run playback. **§ → V** changes body view.
4. Try aiming/firing and switching weapons. This commit intentionally still shows
   the original aiming visual; movement controls are not locked until next phase.
5. Optionally edit `weapon_hand.angle_offset_radians` in the rig JSON and use
   **§ → R**. A small offset should rotate the blaster around the same grip.

The user has accepted this phase. Procedural aiming and movement-input locking
are the next commit-sized phase, with its plan presented before implementation.
