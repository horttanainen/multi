# Curb Rat articulated artwork

Status: the whole-character [side profile](../concepts/alien_skater_v1/a_curb_rat_side.svg)
and segment preparation are approved. Runtime integration is accepted, including
the adjusted head size, and the user has authorized the commit. The game loads
this pack by default. See [game controls and implementation](../../docs/character_animation_artwork.md).

The ten editable SVGs in `source/` provide the head, torso, pelvis/belt, thigh
with its shorts cuff, shin, upper arm, forearm/wristband, open hand, gripping hand
and three-toed foot. Both anatomical sides share these sources. The head and
torso retain the approved drawing; limbs are redrawn around movable joints.
Hidden rounded extensions cover bends instead of cutting the concept into flat
rectangles. The shorts cuffs move with the thighs under a separate waistband.

Each source has two named groups, `skin` and `fixed`. Draw skin first, then fixed
details, at the **same placement**. Skin is neutral grey and receives a multiply
by player RGB. The fixed layer preserves glasses, shorts, wristbands, teeth,
claws and dark outlines. Only skin receives the additional far-side multiplier
(0.65). This avoids changing accessory colors or swapping the weapon hand when
turning.

## Authoring contract

`manifest.json` is a versioned art contract, separate from the existing
rig, motion and locomotion JSON. It references `humanoid_v1` and existing joint
names. It does not add joints, animation curves, IK or collision dimensions.
Future Blender animation export continues targeting the existing motion contract;
these art bindings only consume the final solved joints.

- `parts`: editable source, generated layers, pivot, second axis point and fixed
  meters per source pixel. Both layers have identical canvases. Coordinates are
  SVG pixels: right/down. Head and pelvis are decorative parts; their axis sets
  orientation, not bone length. Other limb lengths match the rig at rest.
- `bindings`: named rig anchor and two joints defining the **world right/down**
  direction. Uniform scale is fixed; poses rotate parts without stretching them.
  `length_mode` explicitly selects direct rig-bone length validation or decorative
  sizing. Subtract the source pivot, multiply by scale, mirror source X when facing left,
  rotate the mirrored source axis onto the solved direction, then add the anchor.
  Feet use heel-to-toe direction while their pivot remains at the ankle.
- `contacts`: the foot's heel/toe source points map exactly to the existing rig's
  contact offsets. These are guides, not new physics/contact probes. The toe's
  claws extend beyond that support span; the outline has a small visual thickness.
- `draw_order`: back-to-front assembly. Resolve far/near from facing: anatomical
  right is far when facing right and near when facing left. The center waistband
  overlaps both moving shorts cuffs. The right hand stays the weapon hand.
- `weapon_hand`: use the rig's canonical `weapon_hand` attachment and select `hand_grip` when a weapon
  is carried. The gripping hand follows the exported weapon orientation and
  facing; open hands follow the forearm, including during holster transitions.
  Insert the gun immediately below its
  matching hand. The `holstered_weapon` draw-order slot handles the existing wall
  brace/push behavior. Specialized wall-contact hand art remains later work.

The head uses 75% of the initial integration scale in both dimensions, retaining
the neck pivot and the approved drawing. The rig's current neck-to-head direction
also tilts it down when kneeling. Feet are shorter than in the concept to fit
existing contacts.
These fit choices are visible in the review sheets and the game; no gameplay rig
changes are included. Art thickness is not collision clearance: ground/wall
clipping and readability in motion still need user review.

## Export and review

No external Python packages are required. From the repository root:

```sh
# Existing game tests generate solved pose samples (use the full script after code changes).
bash scripts/character_animation_check.sh --unit-only
python3 scripts/export_character_art.py --preview agent-temp-files/curb-rat-segments
python3 scripts/export_character_art.py --check
```

The exporter writes twenty generated `export/*_{skin,fixed}.svg` files. Edit
`source/` and the manifest, then rerun the exporter; never hand-edit exports.
`--check` compares generated content without writing it and checks rig bindings,
limb lengths, foot offsets, neutral tint layers and complete draw order.

Open `agent-temp-files/curb-rat-segments/preview.html` in a browser. It provides
play/pause, frame scrubbing, quarter speed and an 80-pixels-per-meter size option.
It displays sixty existing solved poses from the 0.6-second reference run. The
source has 360 poses; this viewer selects every sixth pose, with no new IK or
interpolation. Those frames have no carried gun. Action samples include the
existing blaster and its exported grip transform. Links open:

- `parts.svg`: separate pieces, pivots and an assembled rig overlay.
- `run.svg`: twelve reference-run frames at a fixed scale and ground reference.
- `poses.svg`: kneeling, aiming, kneeling aim and wall slides on both sides,
  including white/cyan/pink tint examples.

These are deterministic vector assemblies of test exports, **not screenshots of
an integrated character**. The script adapts the tests' existing coordinate
formats: reference run and wall samples are local Y-up; kneel and aim joints are
already world Y-down. Joint array order comes from the rig JSON and matches the
current `animation.Joint` order. Regenerate test artifacts when rig/motions change.

Validation for this preparation pass: all 30 SVGs parse; generated layers match
their sources; the approved concept is unchanged. A placement check across all
360 run samples and both facings verified 10,800 anchors/bindings, including bone
endpoints and heel/toe contacts. The three review sheets were rasterized and
visually inspected, and the browser script passed `node --check`; interactive
browser playback remains a manual review step. The existing full animation check
passed 93 tests, built the game and recorded the five-second smoke sentinel with
no warnings/errors/panics. That smoke run validates the existing game, not these
as-yet-unloaded art assets.

## Runtime integration

The game now loads this pack through `data.zig` and renders it through the existing
sprite placement and tint helpers. Skin/fixed layers share placement. Standalone
textures keep the art alive across level atlas resets and allow SVG reloads.
The § menu provides artwork, skeleton overlay, legacy sprites and stick views.
See the [integration notes](../../docs/character_animation_artwork.md) for the
current validation and manual review steps. The preparation-pass validation above
is historical; current smoke captures do load and render the artwork.
