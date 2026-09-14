# Configurable directional input

Status: accepted by the user; independent review, correction, and validation are
complete.
This is one commit-sized control phase before kneeling and landing polish. The
procedural rig consumes the resulting aim direction in either mode.

## Profile configuration

Levels already select a JSON file through `movementFile`. The selected file now
accepts an `input` block alongside `mechanism`, for example:

```json
"input": {
  "movementMode": "eight_directions",
  "aimMode": "free"
}
```

| Field | Values | Behaviour |
| --- | --- | --- |
| `movementMode` | `axis_thresholds`, `eight_directions` | Independent axis thresholds or equal 45-degree stick sectors. |
| `aimMode` | `free`, `eight_directions` | Preserve the stick angle or snap to the nearest 45 degrees. |

`aimMode` is required when the block is present. `movementMode` defaults to
`axis_thresholds`. Files without the whole block retain the preset defaults:
TowerFall uses eight-direction aim; Liero uses free aim; both use axis thresholds
for movement. The three shipped movement files make those choices explicit.
Unknown mode names fail through the existing JSON loader.

The two choices are independent of one another and of the movement mechanism.
TowerFall retains left-stick movement/aiming and hold-to-aim/release-to-fire;
Liero retains its separate aim stick and hold-to-fire. Keyboard direction keys
still provide eight possible directions even in free mode. This phase adds no
new mouse aiming or button remapping.

The eight-direction movement option includes a down sector extending 22.5 degrees
to either side of straight down. Diagonals retain full horizontal movement intent
(`x = -1` or `1`), so they do not reduce running speed. Sector selection happens
after a radial deadzone using the existing movement threshold (currently 0.2).
The existing independent-axis path keeps its thresholds and axis deadzones.
There is no angular hysteresis in this phase.

Eight-direction TowerFall aiming now uses equal angular sectors, independent of
stick strength. Previously it inherited the movement axis thresholds, so its
angular boundaries varied with stick strength. Aim uses a radial deadzone: the
movement threshold for TowerFall's shared stick, and the existing 0.15 deadzone
for Liero's aim stick. Free aiming preserves small axis components outside that
radial deadzone. Aim snapping retains the processed stick magnitude.

## Try the modes

Run the game normally and use a gamepad. Press and release `§`, then select:

- `F`: toggle free/eight-direction aiming. The menu label shows the current mode.
- `M`: toggle axis thresholds/eight-direction movement sectors.
- `C`: restore the input settings from the loaded profile.

These are temporary choices for all players in the active level. Reopening the
menu shows the current values. Loading/reloading a level restores its profile;
edit the JSON block for persistent game defaults. The menu uses the existing
input blocking/neutralization, so opening it cancels a held or queued shot.
Input debug actions are hidden while editing levels, backgrounds, or music.

Suggested manual checks:

1. In Tower Keep, hold Shoot and rotate the stick. Compare smooth free aiming
   with eight discrete angles; check that the hand, barrel, guide, and shot agree.
2. Return the stick to neutral before releasing Shoot. Check that the last aim
   direction is retained and that release fires once.
3. Aim partway through a sideways jump in both modes. The jump should keep its
   pre-aim horizontal input; aiming down should not introduce a fast fall.
4. Enable movement sectors and hold the stick mostly down. Small sideways
   offsets should remain down; a diagonal should resume full horizontal running.
   Stationary Down now uses the separate [kneeling pose](character_animation_kneeling.md).
5. Compare the same aim modes in a Liero level. Movement and aim should still use
   separate sticks. Restore with `C`, and verify that a reload restores defaults.

## Implementation and validation

`data.zig` owns the serialized types and existing loader. `movement.configure`
passes loaded input settings to `player_input`, which owns active and profile
direction settings and resolves aim before storing held/released directions.
`gamepad.sampleSticks` reuses the existing axis and radial-deadzone helpers;
movement and aiming each receive the original stick direction. `debug_menu.zig`
adds actions to the shared `menu.zig` UI. No animation or weapon geometry is
duplicated for the new modes.

The shot regression also exposed a pending-press edge case in `control.zig`:
returning the stick to neutral before physics consumed the aim press reset aim
to the character's facing. Default facing is now resolved only while the new
hold has no remembered direction; subsequent neutral samples retain that aim.

Use the existing check script:

```sh
bash scripts/character_animation_check.sh
```

The suite covers profile defaults and overrides, valid/invalid mode decoding,
all sector boundaries, radial neutral input, diagonal run intent, separate Liero
sticks, menu shortcuts/restoration, and release-shot geometry in both aim modes.
The existing real-physics airborne trajectory comparison runs in both modes.
The full script formats, runs the tests, builds, and checks a five-second game run.

Validation: `bash scripts/character_animation_check.sh` passed 62/62 tests, built
the game, captured `artifacts/character_animation/preview.png`, and logged
`info: Ran successfully for 5 seconds` without warnings, errors, or panics.
`git diff --check` passed. Logs are in `artifacts/character_animation/`.

Independent review covered all phase changes and relevant input, menu, movement,
animation, and weapon callers. The sole actionable finding was P3 in
`debug_menu.zig`: long mode labels clipped the `M` shortcut. The implementer
identified this during screenshot inspection and the reviewer confirmed it.
The new mode labels were shortened; no additional actionable findings were found.
The pending-press correction above was an implementer finding before review.
After correction, the same 62 tests, build, and smoke checks passed again using
the check script's `--` arguments to open the debug menu. The new capture at
`artifacts/character_animation/input_menu.png` confirms the movement shortcut and
label fit; the final smoke log contains the capture and five-second success
markers with no warnings, errors, or panics.

Kneeling and landing polish will have a separate plan and review. Agreement on
that next phase is required before its implementation begins.
