# Character animation: phase one review

Status: phase one accepted by the user on 2026-09-12, including the compact run
motion; full independent review and corrections completed.

## Run and review

From the repository root:

```sh
bash scripts/character_animation_check.sh
```

This runs the project formatter, focused animation tests, `zig build`, and the
existing five-second game smoke-test script with stick-figure playback enabled.
It stops on failure and checks the smoke log for the success marker and unexpected
warnings/errors. Logs and a game-rendered PNG go in `artifacts/character_animation/`.
The capture is taken before the screen postprocessing effects.

For a persistent interactive session:

```sh
zig build run -- --character-animation
```

Normal startup retains sprites. The diagnostic run plays continuously, including
while standing still or airborne, to make the rig easy to inspect at any location.

Press **§** to show the debug menu, then press a letter to select an action.
Holding § while pressing the letter also works. Each selection closes the menu;
§ or Escape closes it without selecting anything. The game keeps simulating, but
gameplay input is suppressed while the menu is open and until held shortcut keys
are released.
Arrow keys and Enter, or the controller D-pad and confirm button, also use the
same navigation as the other menus. The debug menu is a `menu.Item` list using
the shared menu renderer and input handling, with optional shortcuts and an
overlay presentation that keeps the game scene visible. Other menus retain
their default presentation and button behavior.

| Letter after § | Action |
| --- | --- |
| Z | Toggle a closer view following the viewport's player (player 1 in a shared view) |
| V | Cycle sprites → stick figure → sprite/rig overlay |
| P | Switch neutral standing pose / reference run; restart the cycle |
| D | Show joints, preferred targets, maximum reach, and contact intent |
| R | Reload both JSON assets; restart playback after a successful reload |
| S | Switch normal / quarter-speed simulation |
| A | Save texture atlases to disk (previously § alone) |

Animation controls are available during gameplay, outside other menus and
level/music/background editing. During editing, the debug menu offers only atlas
export. The bottom-left animation status shows the selected view, pose, and speed.
The menu recognizes § and the physical grave/ISO section-key positions, so US
keyboards can use the backtick key.

White rings mark solved joints. Yellow crosses mark preferred foot/hand targets;
red crosses indicate a target beyond the configured limb reach. Faint circles show
maximum reach. Green foot marks show the clip's **contact intent**, not acquired
world contacts. Far limbs use half the player's color intensity.

Other startup options: `--character-animation-overlay`,
`--character-animation-neutral`, `--character-animation-diagnostics`,
`--character-animation-close`, and `--character-animation-capture path.png`.
Add `--debug-menu` to start with the debug menu visible.
The capture option saves one frame two seconds after gameplay rendering starts.

For solver/asset checks without launching the game:

```sh
bash scripts/character_animation_check.sh --unit-only
```

Extra arguments after `--` replace the validation script's default smoke-test
arguments. For example, this checks the neutral overlay:

```sh
bash scripts/character_animation_check.sh -- --character-animation-overlay --character-animation-neutral
```

## Review checklist

1. Inspect both players' colors, proportions, and alignment with the ground in
   neutral mode. Compare with the sprite overlay and closer view.
2. Inspect the reference run at normal and quarter speed. Its cadence is fixed at
   one stride per 0.60 seconds, with the accepted twelve poses as reference points.
3. Move left and right, then aim in another direction. The skeleton follows
   movement facing; aiming alone does not mirror the skeleton.
4. Switch all visual modes while playing. Shoot, use the rope, die/respawn, and
   reload a level. Movement, collisions, and player lifecycle should still work.
5. Change `head_radius` in `character_rigs/humanoid.json` from `0.105` to `0.13`,
   save, and press § then R. The head size should change. Set it to `-1` and reload:
   the last valid rig should remain visible, with an error in the log and status.
   Restore `0.105` and reload when done.
6. To inspect reach handling, switch to neutral mode, press § then D, and change the
   neutral `left_hand_x` control to `2`. The arm should retain its lengths and
   show a red unreachable target. Restore the original `0.108` afterward.

The phase-one run uses preferred local foot paths. Speed adaptation, actual foot
planting, and start/stop/reversal transitions are phase two. Jump, wall, aiming,
grapple, and terrain pose adaptations are phase three. Existing weapon and rope
placement still uses the original sprite anchors in this phase, so free-running
skeletal hands can be visually separate from them. Cosmetic rig joints are not
Box2D bodies and do not change gameplay collisions or projectile spawn positions.

## Accepted compact run

`character_motions/run_reference.json` now uses fitted cubic Bezier hand/foot
tracks: 159 total keys and 48,512 bytes (2,046 formatted lines), down from 1,728
keys and 225,764 bytes (8,859 lines). Timing, contact intervals, control names,
and the rig are preserved. The existing runtime Bezier evaluator plays the file.

The exact original is retained at
[`character_motions/run_reference_dense.json`](../character_motions/run_reference_dense.json).
The compact motion is accepted. Tests retain this archive as the regression
reference; the exporter does not overwrite it.

To compare during an interactive game session, save the compact candidate and
switch to the dense original from the repository root:

```sh
cp character_motions/run_reference.json /tmp/character_run_bezier_review.json
cp character_motions/run_reference_dense.json character_motions/run_reference.json
```

Press § then R to reload. Restore the compact candidate with:

```sh
cp /tmp/character_run_bezier_review.json character_motions/run_reference.json
```

Press § then R again. Reload restarts the cycle; § then S enables quarter speed.
Compare both legs through touchdown/lift-off, the arm swing, and the cycle wrap.
Restore the compact candidate before running its validation script.

Regression checks compare controls, solved joints, clamping, and contact intent
at 4,097 evenly spaced phases plus every key/contact boundary and adjacent points.
Control differences must stay within 0.00021 meters/radians and solved joint
positions within 0.5 mm of the dense original. The original twelve-pose checks,
fixed bone lengths, loop continuity, and no-foot-penetration checks remain.

The independent review of this compact-run iteration found no actionable
findings. It confirmed the exact dense archive, valid Bezier handles, preserved
metadata, exporter reproducibility, and use of the existing runtime. All 19 tests,
the build, and the five-second smoke/capture passed without runtime warnings or
errors. The user subsequently accepted this iteration with phase one.

## Independent phase-one review

The independent reviewer inspected all phase-one changes against the pre-phase
commit, including the complete new files: assets and exporter, loading and memory
ownership, curves and IK, menu/input, rendering/cameras, player lifecycle,
fixed-step timing, and build/test tooling. The shared menu, `fs.zig`, and `data.zig`
reuse was accepted. Three actionable findings were corrected:

| Priority | Finding | Correction and regression coverage |
| --- | --- | --- |
| P2 | Single-precision IK changed a valid 1 mm lower bone to about 2.19 mm when paired with a 5 m upper bone. | Keep reach/triangle calculations in `f64`, converting only final positions to `f32`. Test extreme length ratios, both bend signs, reach bounds, and restricted bend ranges. |
| P3 | Resetting playback cleared facing, briefly mirroring a right-facing player after respawn. | Reset only playback phases. Check that both facing directions and other players' state survive the reset. |
| P3 | Named attachment lookup scanned an unordered slice, contrary to the repository map-by-key rule. | Prepare an arena-owned string map while retaining the serialized array. Check both named attachments after reordering and reject duplicate IDs. |

The new regression checks reproduced both behavioral bugs before their fixes.
After correction, `bash scripts/character_animation_check.sh` passed all 18 tests,
the build, and the five-second stick-figure smoke/capture without warnings or
errors. The neutral overlay with the shared debug menu also has smoke/capture
evidence under `artifacts/character_animation/full_review/`. Re-exporting the
saved source in an isolated directory reproduced both JSON assets byte for byte.

No actionable findings were rejected or left unresolved. Live controller input,
movement through both facings, death/respawn at quarter speed, valid/invalid live
reload, split-screen close view, and varied rendering frame rates remain manual
acceptance checks. This review does not constitute the user's acceptance.

## Runtime JSON version 1

Files loaded together:

- `character_rigs/humanoid.json`: rig ID `humanoid_v1`.
- `character_motions/run_reference.json`: motion ID `run_reference_v1`, referencing
  that rig through `rig_id`.

The loader rejects unknown fields/IDs, unsupported units/versions, duplicate
bindings, missing controls, invalid hierarchy/lengths/limits, malformed curves,
and invalid contact intervals. Loading builds a complete replacement asset set
before changing the current one. Failed reloads preserve both assets and phase;
successful reloads reset all players' phases. Arrays can be reordered: stable
names, never array positions, define identity.

`fs.zig` provides bounded, allocated file reading so the motion file can exceed
the 16 KiB buffers used by older asset loaders. Character assets have a 1 MiB
limit per file; exceeding it fails rather than truncating the JSON. `data.zig`
owns the file schemas, JSON decoding, and file/field diagnostics. Its decoded
rig and motion share a temporary arena and own their strings and arrays.

`character_animation.zig` consumes that decoded data, validates the rig and
motion, and prepares the runtime arrays and named attachment map. The map shares
the candidate arena; the JSON attachment representation remains an array.
Failed validation releases the
candidate arena; successful preparation transfers it to the runtime assets.
Only then does replacement release the previous assets and reset playback.
Startup and § then R use the same loading path. The JSON format is unchanged.

### Coordinates and rig

Distance is in meters, time in seconds, and angles in radians. `coordinates` is
`x_forward_y_up`. The root is the neutral pelvis reference. Root-relative foot
and hand controls are independent of animated pelvis displacement.

`root_from_body` is a canonical vector from the Box2D body origin to that root.
With facing sign `s` (+1 right, -1 left), canonical point `(x,y)` maps to:

```
world_x = body_x + s * (root_from_body.x + x)
world_y = body_y - root_from_body.y - y
```

The initial offset is `(0,0.54)`. The neutral pelvis is 0.84 m above the reference
floor, placing the soles at `body_y + 0.30`, the existing lower collider's bottom.
The root offset affects the drawing only.

Version 1 supports the named humanoid hierarchy in `Joint` in
`src/character_animation.zig`: pelvis → chest → neck → head, shoulder/elbow/hand
chains from the chest, and knee/ankle/toe/heel chains from the pelvis. Every
non-root joint names its incoming bone. Bone length is the magnitude of that
joint's `rest_offset`; there is no second, conflicting length field. Offsets are
parent-relative vectors in the canonical rest pose. Torso rotation rotates the
chest, neck, head, and shoulder offsets; IK drives the limb chains. Foot angle
rotates the ankle-to-toe and toe-to-heel offsets.

Each of the four `limbs` names its `root`, `middle`, and `end`, its `bend_sign`
(+1/-1), and minimum/maximum bend angles. Zero bend means fully straight and pi
means fully folded. Valid limits avoid those singular endpoints. Unreachable and
coincident targets yield bounded solutions; the resulting pose reports clamping.

`attachments` have unique string IDs, a joint, and a `local_offset`. Attachment
local +X follows the joint's incoming bone; +Y is counterclockwise perpendicular.
At the pelvis, offsets use the canonical axes. `weapon_hand` and `grapple_hand`
are present for later integration. They do not yet drive existing weapon placement.

### Controls and curves

Both the rig's `neutral_controls` and the motion's `tracks` supply these 13 bindings:

- `pelvis_x`, `pelvis_y`: displacement from the neutral pelvis reference.
- `torso_angle`: forward lean, clockwise from the canonical upright torso.
- `left_foot_x/y`, `right_foot_x/y`: preferred ankle targets, root-relative.
- `left_foot_angle`, `right_foot_angle`: counterclockwise rotation from the rest foot.
- `left_hand_x/y`, `right_hand_x/y`: preferred hand targets, root-relative.

Every track contains ordered `keys`, starting at phase 0 and ending at phase 1.
Each key has `phase`, `value`, and outgoing `interpolation` (`step`, `linear`, or
`bezier`). Optional `in_handle` / `out_handle` values are `[phase,value]` pairs.
The last key's interpolation is unused. An interior exact-key lookup uses that
key's value; a stepped segment holds its starting value until the next key.

Bezier segments require the start key's outgoing handle and end key's incoming
handle. Handle phases must satisfy `start <= out <= in <= end`. Evaluation solves
the Bezier time coordinate before evaluating its value. Constant controls use
equal-valued keys. Looping tracks have matching first/last values; non-looping
playback clamps at the endpoints. Matching endpoint derivatives are the author's
responsibility. No renderer frame count is part of this contract.

`contacts` hold non-overlapping, half-open `[start,end)` phase intervals per leg.
Split intervals crossing phase 1 into two entries. They describe authored intent;
surface anchors and actual contact acquisition will be runtime state in phase two.

### Reproduction and Blender preparation

`scripts/export_character_run.py` recreates the initial assets from
`tests/fixtures/character_run_source.json`. It retains the original pelvis/torso
Bezier handles and fits preferred hand/foot controls into cubic Bezier segments.
Source boundaries seed each track, including contact changes and wrapping. The
fit uses endpoint values and one-sided slopes, with time handles at segment
thirds. A segment splits only when its checked error exceeds 0.0001 m for
positions or 0.0001 radians for angles. Each accepted segment is checked at 64
interior points; this is a sampled error check, not an analytical bound over
continuous time. Runtime regression tests independently compare the compact and
dense motions across the cycle and retain the twelve accepted pose comparisons.

The game rig rotates shoulder offsets with the torso. This is a deliberate
hierarchy correction from the original study, shifting arm positions by under
6 mm. Other sampled reference joints agree within 0.15 mm.

Running the export script replaces both initial assets; ordinary JSON tuning
needs only § then R. The game never invokes the exporter. Later Blender tooling can
bootstrap its controls from these assets and export the same named tracks,
explicit handles/samples, and contact intervals. Blender is not needed to run,
review, or tune this phase. Locomotion settings will have their own asset in
phase two; neither editor state nor transient player state is embedded here.
