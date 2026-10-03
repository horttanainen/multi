# Dreadlocks

Static artwork was committed as `9383af0`. The motion phase, including the
curtain shape and extended side scalp, is accepted by the user for commit.

The head has one scalp layer covering its crown, back and side, extending down
the temple and behind the ear, plus fifteen instances of one shared lock SVG.
Some near-side roots sit within that side area rather than along the crown.
Near-side roots form a hanging curtain over the ear and
part of the cheek, leaving the eye/sunglasses visible. Three additional crown
roots allow locks to lift above the head while falling. Each
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
  within each layer. Front locks also sit in front of the head and torso in the
  simulation: their overlap in projection is intentional. Back locks use the
  approximate head/torso obstacles.
- `lock.image`: the shared editable source, exported file, and root pivot in source pixels.
  `lock.source_size` gives the nominal template width and root-to-tip distance, used
  for scaling independently across and along the lock.

Length changes preserve root positions and widths. The overall base length is a
styling control, not a measurement along each curved strand. The lock's drawn
curve is shared, and the renderer bends its texture along the simulated chain.
Omitting `hair` or setting it to null preserves a hairless pack. The rig and motion
formats are unchanged; the existing named head anchors drive the chains.

Artwork assets and configuration use the existing `data.zig` loading and
`character_art.zig` ownership/reload path. A failed candidate preserves the
installed pack. Hair shares the existing standalone sprite storage, placement/tint helpers and
GPU sprite batches. The pack loads one lock texture and one scalp texture;
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
should remain attached and keep its color independently of skin. Locks should lag
when accelerating, swing after a jump or turn, and settle when standing still.
Check that deaths retain moving hair and that respawns have no stretched strands.
Check the idle curtain, a small movement followed by rest, a running stop and a
fall/landing on both facings. The lower lengths should lag the roots, with small
movements producing small disturbances. Resting heads should become completely
still after the locks have dropped and settled.
The simple head/torso obstacles deflect rear locks; hair can still pass through
arms, walls, floors and other locks. Environment and self-collision are outside
this phase.

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
poses with hair. These vector sheets show the authored static shapes; they do not simulate hair.
They complement the actual game capture at
`artifacts/character_animation/preview.png`.

### Static phase validation

The preceding static phase passed 140 native tests; all 32 SVG exports matched, and the game
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

## Motion implementation and tuning

`character_hair.zig` owns chains keyed by the existing player/head body IDs.
Each lock has six points by default, including its pinned root. The fixed-step
solver applies gravity and damping, constrains distances and bends, and deflects
rear links around a head circle and torso capsule while preserving their lengths.
Near-side locks hang in front of those obstacles, matching their existing draw
layer. New chains start in a downward curve rather than a straight swept-back
shape. Authored angles influence their emergence at the root.
Roots embedded in these approximate obstacles have a clearance exemption so
short locks can emerge without stretching. Root links resist bending more
than tips. These are visual constraints: they do not push the player or create
Box2D bodies/joints. They are approximate obstacles, not full body mesh collision.

The renderer interpolates the simulated points and bends the existing lock image
as a strip of textured quads through `gpu.zig`'s sprite pipeline. The scalp stays
rigidly attached. Both layers retain the established draw order and hair color.
There is no per-frame SVG rasterization, texture upload or separate hair pipeline.

Player spawn and head-pool creation reserve chain storage. Death copies moving
points/velocities into the already prepared head; converting an existing ragdoll
head to a giblet keeps its state. Disabled/recycled heads reset without freeing
their reserve. Entity cleanup frees it. A successful artwork reload resets chains
after preparing replacement capacity; failed replacement retains installed hair.
Facing changes mirror the chain around the head; teleports and length changes
restart it. Hair sleeps from measured head/torso movement, including live idle
characters and resting bodies that Box2D still considers awake. It compares the
current attachment against the beginning of the rest interval, so small contact
jitter is tolerated while accumulated drift wakes it. Velocity damping increases
during rest, reaching its full additional strength after `settle_seconds`.
Sleep requires measured point movement below `sleep_speed_mps` for
`sleep_seconds`; elapsed time alone never freezes a pose. Normal motion resumes
when the attachment moves. Constraint corrections have a velocity limit based on
incoming speed and a configurable contribution from the moving root, diminishing
down the lock. This limits artificial energy from corrections while preserving
momentum and allowing visible trailing during a run. Neighboring links also
damp relative motion to suppress small ripples.

The optional `hair.motion` object uses these defaults when omitted. Save the
manifest and press **§ R** to apply edits:

| Field | Default | Effect |
| --- | ---: | --- |
| `points_per_lock` | 6 | Chain resolution, 3–12 including the root. |
| `iterations` | 6 | Constraint passes per fixed step, 1–12. |
| `gravity_mps2` | 9 | Downward acceleration. |
| `damping_per_second` | 2.5 | Larger values settle swinging sooner. |
| `stiffness_per_second` | 1.5 | Resistance to bending, strongest near the root. |
| `root_bend_radians` | 3.0 | First link's maximum bend from the authored direction. |
| `bend_radians` | 0.85 | Maximum bend between following links. |
| `head_radius_m` | 0.13 | Rear locks' head collision circle; zero disables it. |
| `torso_radius_m` | 0.13 | Rear locks' torso collision capsule; zero disables it. |
| `teleport_distance_m` | 1.5 | One-step head travel that resets the chain. |
| `sleep_speed_mps` | 0.04 | Maximum point speed considered settled. |
| `sleep_seconds` | 0.6 | Settled duration before quiet hair sleeps. |
| `settle_seconds` | 1.8 | Time for additional rest damping to reach full strength. |
| `rest_distance_m` | 0.003 | Head/torso movement tolerance; angular movement uses a 0.2 m head radius. |
| `bend_damping_per_second` | 12 | Dissipates ripples between neighboring links while retaining shared momentum. |
| `motion_transfer` | 0.2 | Root speed contribution to the correction velocity limit, 0–1; reduced toward the tip. |

Use damping/stiffness first for feel. More points/passes increase CPU work; the
current defaults use 90 points per head. Appearance color and base length remain
independent per-player settings. Ponytail and loose-hair styles remain later work.

Motion validation before the curtain revision: 147 native tests passed, including root attachment, inertia,
sleep/wake, mirrored turns, teleport/length resets, ribbon interpolation and pooled
head inheritance, death while turning and 0.01–2 m lengths at 3/6/12 points.
The full script checked all 32 exported SVGs, built and completed
the five-second captured smoke run without warnings or errors. An eight-death
`tower-keep-ragdolls` benchmark averaged about 16.7 ms per frame and peaked at
21.9 ms; it reported no particle/giblet body creation or explosion scratch growth
during the measured deaths. These are whole-game measurements from one run, not
an isolated hair cost or a guarantee for every scene. Final controller feel,
fast-motion overlap and longer corpse accumulation remain user gameplay checks.

The motion reviewer found two P2 issues in `character_hair.zig`, both corrected:
turning on the death tick bypassed the facing mirror during inheritance, and
collision projection stretched short links whose roots were inside the head
obstacle. Live turns and death now share the mirror transform; collision rotates
links while preserving length and permits embedded roots to emerge. Dedicated
regressions cover both, with length checks tightened to a 0.00001 m tolerance.
The collision revision also resolves constraints on initialization and keeps
shallow contact corrections continuous so stationary chains settle to sleep.

Review scope included the solver, entity/pool/reload lifecycle, schema, shared
sprite batching, and integration callers. Failed GPU/file reload with initialized
chains and a dedicated atlas-versus-standalone UV regression remain unexercised;
those paths were inspected. Gameplay motion/overlap still needs user acceptance.

User feedback iteration: reduced gravity, air damping and straightening stiffness
for slower flowing motion; widened bend limits so falling locks can lift instead
of staying pinned downward; added three crown anchors sharing the existing SVG.
Regression checks cover upright/sideways/upside-down resting heads, contact jitter,
waking after gradual motion, and all crown tips lifting during falls on both
facings. The rest interval is based on external attachment movement rather than
Box2D sleeping or solver-generated velocities alone.

The focused review of that feedback iteration found no actionable issues. It
covered rest/wake transitions, reset and inheritance, relative velocity damping,
configuration, and reuse of the texture/pool path. Its settling ceiling has since
been removed: the curtain revision lets locks drop and become quiet before sleep.

The curtain revision passes 148 native tests. New checks cover front locks hanging
down over the body in both facings, limiting movement from a 1.5 cm head oscillation,
and returning to a hanging shape after a sustained run. Upright and rotated heads
settle within the checked three-second interval, then remain still under tiny
contact jitter. The existing fall test checks all three crown locks lifting and
dropping again. Controller feel and unusually long locks still need gameplay review.

The curtain iteration's independent review found no actionable issues across its
seven changed files and inspected the shared component/texture ownership, schema,
preallocation, reload and death paths. The full validation script passed all 148
tests and 32 SVG checks, built the game, and completed the five-second capture
without warnings or errors. The actual idle capture shows the hanging curtain
with sunglasses visible. Both-facing gameplay remains the acceptance check for
motion, overlap in other poses, and longer configured locks.

The latest eight-death benchmark averaged about 16.7 ms per frame and peaked at
26.0 ms, passing the existing 33.3 ms limit. The first run failed that limit with
one 37.8 ms frame (37.1 ms in rendering, 0.55 ms in physics); that spike did not
recur in the repeat. Both runs completed eight deaths without particle/giblet
body creation or explosion scratch growth during the captures. The first log is
preserved in `agent-temp-files/hair-curtain/deaths-first.log`, with the repeat in
`artifacts/explosion_perf/tower-keep-ragdolls.log`. This does not isolate hair cost
or rule out occasional rendering stalls.
