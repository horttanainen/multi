 # Running animation in Blender

Open `run.blend` in **Blender 4.5 LTS**. This is a prepared workspace using the
current run animation. Blender is an optional authoring dependency; the game
continues to read JSON and needs no Blender installation.

From the repository root:

```sh
bash scripts/character_blender.sh open
bash scripts/character_blender.sh check
bash scripts/character_blender.sh export
bash scripts/character_blender.sh export --apply
```

The script finds Blender in `/Applications`, on PATH, or in the local scratch
copy used to prepare this phase. Set `BLENDER` to its executable to override.
`check` runs authoring checks and compares 121 Blender poses with the actual game
loader, curve evaluator and IK. `export` performs the same runtime comparison
without the authoring regression tests. Both write to `artifacts/character_blender/`.
Only `export --apply` replaces the game's motion and locomotion JSON; it first
saves the previous files in `artifacts/character_blender/before-apply/`.

## Edit a run

1. Open the scene and press Space to play. The figure faces right. Light/gold
   limbs are the right side; dark/blue limbs are the left side.
2. Select a named sphere control: pelvis, either foot, or either hand. Move with
   G then X or Z. Select the torso ring and use R then Y for lean. Foot rotation
   also uses Y. Press I with the prepared **Run Controls** keying set to key the
   supported channels, or edit existing keys in the Graph Editor. Avoid inserting
   keys on every transform channel with a different keying set.
3. Use the Animation workspace or change an editor to Graph Editor for curves.
   Start at frame 1; frame 37 is the duplicate endpoint of the 0.6-second cycle
   at 60 fps. Playback ends at frame 36. Keep first/last values equal for looping.
   Blender supports fractional key times, so existing keys need not be on integers.
4. **Save the `.blend` file** before running export. Export reads the saved file,
   not an unsaved Blender window. Run `export` to validate, then `export --apply`
   when ready to test it in the game. Restart the game or use its animation reload.

Scene Custom Properties contain `cycle_seconds`, `cycle_end_frame`, reference
speed and a few locomotion settings. Preview speed is Blender's scene fps; when
changing duration, also set fps/fps_base to `(cycle_end_frame - 1) / cycle_seconds`.
The feet's Object Custom Properties contain normalized `contact_0_start/end`.
These properties are authoritative, with half-open [start, end) intervals.
Timeline markers are rounded reference labels only; moving markers does not
change contact timing. This initial workspace preserves the existing number of
contact intervals; adding intervals is outside this phase.

## What is exported

Named bindings, not display names or object order, identify controls. Game +X
forward / +Y up maps to Blender X/Z, in meters. Angles are radians. Hand and foot
targets stay relative to the neutral pelvis origin; moving the pelvis does not
move their targets. Torso lean is positive Blender Y; foot angles have the opposite
sign. Key time maps as `phase = (frame - 1) / (cycle_end_frame - 1)`.

Constant, Linear and Bezier curves export directly, including time/value handles.
No dense baking is involved. Keep Bezier handles ordered within each segment;
the runtime rejects folded time handles. Modifiers, drivers, NLA, extra transform
channels and control constraints are rejected rather than silently lost.
Scene settings must be static; scene-level actions, drivers and NLA are rejected.

The native two-bone IK skeleton previews the base pose. The runtime comparison
requires controls to agree within 0.00002 and preview joints within 3 mm. Terrain,
turning, blending and collision response are still evaluated in the game. The
preview skeleton and rig proportions are fixed for this first authoring phase;
edit target controls, not bones or preview geometry. The export includes the
original rig for validation but does not replace the game's rig.

`run.blend` is the editable source after bootstrap. Do not run the older
`export_character_run.py` generator over accepted Blender edits. To bootstrap a
separate scene from current game JSON, use:

```sh
bash scripts/character_blender.sh create character_authoring/new_run.blend
```

Creation refuses to overwrite an existing workspace. Blender backup files and
validation artifacts are not maintained sources.

## Current pose-tuning pass

The run compresses around the passing pose, then rises through push-off into
flight. Review **frames 4 and 22** for down/passing and **15 and 33** for the high
pose. The pelvis rises and falls about 9 cm. The support leg allows a shallow
landing bend, then extends without the previous late dip.

The recovering ankle reaches about 62 cm above the ground behind the body, then
lowers as it passes the hips. Contact ends at phase 0.30 / 0.80 (frames 11.8 /
29.8), about two frames earlier, and the foot lifts promptly through release.
Both legs share the motion half a cycle apart. Grounded toe travel, the
0.6-second cycle, reference speed and runtime speed scaling are unchanged.

The original scene and JSON are retained locally in
`agent-temp-files/run-pose-polish/`; the version immediately before this timing
pass is in `agent-temp-files/run-timing-apply/before/`. Open the updated scene
again if Blender still shows the previous version. The game JSON has also been
updated for testing this pass.

Idle now uses a taller stance with slightly bent knees and a small forward lean.
It remains in the rig's `neutral_controls`; the run's authored curves are
unchanged. The saved workspace includes the updated neutral rig reference.

The neck attachment sits 4 cm forward of the chest in torso-local space, bringing
the head forward with it throughout the animation. The preview uses the same rig.
