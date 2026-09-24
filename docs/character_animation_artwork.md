# Procedural character artwork

The Curb Rat body now draws from the existing final procedural pose. Artwork is
selected by default. Movement, contacts, aiming, grappling and collision geometry
remain owned by their existing components; this phase adds the visual assembly.

## Try it

```sh
zig build run
# Existing slope/stair/rubble scene, with the review status and close-up camera:
zig build run -- --level levels/animation_terrain.json --character-artwork --character-animation-close
```

Press **§**, release it, then press the action letter:

- **V**: artwork → artwork plus skeleton → legacy sprites → stick → artwork.
- **Z**: close-up zoom.
- **D**: joints, targets and contacts.
- **P**: gameplay movement → neutral pose → reference run → gameplay movement.
- **S**: quarter-speed simulation.
- **R**: reload animation JSON, artwork manifest and exported SVG layers together.

`--character-animation` still starts the stick view;
`--character-animation-overlay` starts artwork with its skeleton overlay.
`--character-artwork` selects artwork explicitly and enables the review status.
The normal game does not require an animation flag.

Review running and reversals, jump/fall/landing, kneeling with and without aiming,
wall pushing/sliding/jumping, slopes, stairs and moving rubble. Compare both
facings and player colors. Inspect feet and joint overlaps at normal size as well
as close up. The head is 75% of the initial integration size in both dimensions
and follows the current neck direction, including its downward tilt in kneeling.
Collision/hitbox dimensions have not been enlarged to match decorative art.
Open hands are used for wall contact; specialized fingers
or knife artwork and simulated long hair remain later work.

## Assets and reload

The [art pack](../character_art/curb_rat_v1/README.md) contains the editable SVGs,
paired generated skin/fixed layers and `manifest.json`. After editing a source:

```sh
python3 scripts/export_character_art.py
```

Then use **§ R** in the game. Manifest-only changes do not need SVG export.
Exported files are the runtime input. The exporter also produces optional SVG/HTML
fit previews from the existing test poses; it does not implement another solver.

The shared `data.zig` character decoder owns file reads, strict JSON shape checks,
field diagnostics and arena lifetimes. It now understands the named parts map.
`character_art.zig` validates rig/bone references, length modes, source pivots,
foot offsets, layer order, paths and complete draw order, then resolves strings
into part/binding indices. SDL loads both layers and checks their canvas sizes and
pivot bounds before installation.

Reload prepares the full animation set, art metadata and all twenty sprites first.
Any read, validation, image-loading or GPU-upload failure releases the candidate and keeps the
previous rig, motion, artwork and animation state. A successful reload replaces
both sets and resets animation state through the existing animation lifecycle.
The previous set is released only after the candidate is complete.

The art layers use the sprite loader's standalone backing. Both atlases have
level-reset lifetimes; a standalone texture survives those resets and bypasses the
immutable image-path cache on artwork reload. This uses the existing texture
allocation/upload/destruction path. Twenty small shared textures serve all players.
The art component owns their sprite IDs; destruction goes through the sprite owner.

## Rendering contract

`character_animation.playerFrame` supplies the final interpolated pose and weapon
transform. The art renderer converts joints with `character_animation.toWorld`,
rotates each fixed-size segment around its authored pivot, and draws through
`sprite.placeAtAnchor` / `drawPlacedTinted`. It adds no animation or IK solver.
The sprite pipeline uses integer pixel anchors, so very small rounding differences
remain visible when zoomed closely; gameplay foot anchors retain their precision.

- Skin receives player RGB and the optional far-side shade. The following fixed
  layer resets to untinted color, preserving glasses, shorts, outlines and claws.
- `length_mode: rig_bone` checks that the authored span equals a direct rig bone.
  Decorative head, belt, hands and foot orientation axes use `decorative`.
- Feet pivot at the ankle and orient along solved heel-to-toe direction. Their
  authored heel/toe points match the rig's existing contact offsets.
- Anatomical sides exchange depth on turning. The gun stays on the rig's named
  weapon hand. Its gripping hand uses the same world anchor, angle and facing as
  the carried gun, including attachment offsets. The manifest must reference the
  canonical `weapon_hand` attachment; the rig can assign it to either hand.
- The draw order has both hand-depth weapon slots and `holstered_weapon`; wall
  bracing uses the existing interpolated holster placement. An artwork/skeleton
  overlay draws the gun once. During holstering and unholstering, the open hand
  remains attached to the solved wrist while the gun moves independently.

## Validation and remaining review

Run `bash scripts/character_animation_check.sh`. It checks generated art, formats
through the project script, runs the character suite, builds and uses the existing
five-second smoke script to capture the actual artwork view. The standard smoke
script writes its transient log to `/tmp/game_run.log`; this phase does not add
another runner.

New tests cover strict decoding and arena ownership, rejected candidates retaining
installed metadata, SDL decoding of all layers and neutral skin, rendered foot
placement across run phases/facings/resolutions, anatomical hand identity and
weapon attachment transforms, partial holster transitions in both directions,
tint multiplication, and shared-menu view cycling.
Existing movement/action/terrain tests remain in that same suite.

Current results: **101/101 tests passed**, build passed, and the artwork smoke
capture logged the five-second success marker with no warnings/errors/panics.
Additional prescribed smoke captures verified reference-running artwork and the
terrain-level skeleton overlay with two player colors. These are real game
captures, not the offline SVG assembly sheets.

The actual GPU capture checks the loaded artwork after startup level loading,
which clears the atlases. Interactive controller feel, live SVG reload after an
edit, repeated level transitions, and clipping in all action/terrain combinations
still require the user's manual review. Tests of rejected candidates cover
metadata. Missing-image cleanup and GPU-failure rollback are checked by code
inspection; no injected-failure test is retained. Existing movement/action tests
verify poses; captures do not establish visual quality for every action.

## Independent review and corrections

The reviewer covered this runtime integration in full: loading and ownership,
shared JSON/sprite/menu reuse, rendering and weapon placement, reload, lifecycle,
tests and documentation. It found three actionable P2 issues, all corrected:

- `character_art.zig`: grip art followed a partially holstered gun away from the
  forearm. `FramePose` now carries the actual stow fraction; transitional hands
  stay on the solved wrist. A regression samples both transition directions,
  facing directions and interpolation endpoints.
- `character_art.zig`: the manifest could select `grapple_hand` while gameplay
  used `weapon_hand`. Validation now requires the canonical attachment. Tests
  reject the mismatch and accept a rig whose canonical weapon hand is left.
- `texture.zig`: upload failures were swallowed before installation. The existing
  upload helper now propagates errors through standalone creation and cleans up
  failed resources. The temporary fault-injection hook and its dedicated test
  were removed during user review; the production error handling remains.

Separately, implementation smoke testing exposed artwork being cleared with the
mutable atlas during level startup. Reusing standalone texture backing fixed its
lifetime and allows edited SVGs to reload without the immutable image cache.
The reviewer reported no separate architectural duplication or skill findings.
