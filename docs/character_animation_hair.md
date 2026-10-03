# Static dreadlocks

Status: accepted by the user for commit. This phase establishes the approved
silhouette and attachment data. Hair motion is the next proposed phase.

The head has one scalp layer covering its crown and back, plus twelve instances
of one shared lock SVG. Three fall from the temple in front of the ear. Each
anchor varies the shared drawing's length, width and angle. The artwork is hand-authored
SVG, with neutral grayscale shading multiplied by hair color. Skin tint remains
independent. Rear locks draw behind the character; the scalp and near locks draw
over it. Roots follow the final head transform, including turning and leaning.

## Configuration

Edit the `hair` section of
[`manifest.json`](../character_art/curb_rat_v1/manifest.json):

- `default.color`: RGB hair color for players without an override. Initially
  `{ "r": 166, "g": 142, "b": 116 }`.
- `default.length_m`: base lock length, initially `0.8` meters. Each lock uses
  this value multiplied by its `length_scale`. Valid range is 0–2 meters;
  zero hides the locks while retaining the scalp.
- `players`: overrides keyed by zero-based `player_id`. Player 1 (the second
  player) initially has lighter hair and a base length of `0.58` meters.
- `anchors`: named root positions in head SVG pixels (right/down), angle in
  radians clockwise from the lock template's downward axis, width in meters,
  length multiplier, and `back`/`front` draw layer. Array order controls overlap
  within each layer.
- `lock.image`: the shared editable source, exported file, and root pivot in source pixels.
  `lock.source_size` gives the nominal template width and root-to-tip distance, used
  for scaling independently across and along the lock.

Length changes preserve root positions and widths. The overall base length is a
styling control, not a measurement along each curved strand. The lock's drawn
curve is shared; procedural bending belongs to the motion phase. Omitting `hair` or
setting it to null preserves a hairless pack. The rig and motion formats are
unchanged; future motion can consume these same named roots and rest shapes.

Artwork assets and configuration use the existing `data.zig` loading and
`character_art.zig` ownership/reload path. A failed candidate preserves the
installed pack. Hair shares the existing standalone sprite storage and draw
placement/tint helpers. The pack loads one lock texture and one scalp texture;
every anchor and player shares them. Color and length do not create per-player textures.
Death snapshots retain the appearance on the head; ragdolls and head giblets
keep it, and pooled reuse replaces it along with the rest of the part visual.
Connected corpse hair uses rear/front scene passes around entity rendering, so
pool insertion order cannot place an arm over a front lock. Both passes use the
head entity's interpolated transform. Isolated head giblets draw their scalp and
locks locally with the head.

## Review and tuning

Run the game normally. Press §, then Z for close view. Check both characters,
turning, running, aiming, kneeling, wall slides, death and respawn. Head hair
should remain attached and keep its color independently of skin. Long locks are
rigid in this phase, so they rotate with the head and may overlap the torso or
environment. No hair collision or motion is implemented yet.

For JSON-only changes, save and press §, then R. For SVG changes, edit the
`source/hair_lock.svg` or `source/hair_scalp.svg` and regenerate the exports first:

```sh
python3 scripts/export_character_art.py
```

The existing validation script checks the SVGs, geometry, appearance and lifecycle,
then builds and runs the five-second game smoke test:

```sh
bash scripts/character_animation_check.sh
python3 scripts/export_character_art.py --check --preview agent-temp-files/hair-static/preview
```

The preview's `hair.svg` shows both lengths/colors and facings using native idle
pose samples. Rerun the character checks after changing appearance settings so
these samples reflect them. `preview.html` also shows the existing run and action
poses with hair. These vector sheets complement the actual game capture at
`artifacts/character_animation/preview.png`.

Validation: 140 native tests passed, all 32 SVG exports matched, and the game
built and completed the prescribed five-second captured smoke run without
warnings, errors or panics. Idle, running and action review sheets were also
exported and visually inspected.

The independent review covered the full phase and found two P2 issues: front
locks could be covered by ragdoll limbs because of entity insertion order, and
several optional checks did not follow guard-clause style. Both were fixed.
The corrected corpse path is covered for both facings, interpolation, disabled
pool entries and the transition to a severed head. Its final rendered overlap
still needs user gameplay review. Actual failed GPU image reload/partial upload
cleanup was inspected but not exercised; invalid JSON/preparation preservation
is covered by tests.

The shared-lock revision received a focused independent review against the prior
iteration. No actionable findings were reported. It retains the same checks,
with 32 exported layers after consolidating the lock artwork.

## Next phase

Next, agree on the implementation plan for moving locks: anchored
roots, configurable bending/drag and length, stable simulation during turns,
jumps, respawns and detached-head motion. Choose the simulation approach before
implementation. Ponytail and loose-hair styles follow later.
