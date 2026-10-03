# One-handed wall slide

Implemented against `00637cd`, in one reviewable phase. Independent review,
corrections and validation are complete. Accepted by the user, including the
near-straight leg and downward-toe adjustment.

## Intended pose

The character slides with the non-gun hand raised behind the head against the
wall, as though gripping an embedded knife. The body faces into the arena. The
left leg extends almost straight down to the wall while the right knee remains
bent; both soles face the surface with their toes pointing down.
The gun hand carries the blaster outward and slightly downward. Aiming controls
that arm while the support hand continues to slide down the wall.

The references supplied by the user are the
[itch.io wall slide](https://img.itch.zone/aW1nLzQ1MDYxNTkuZ2lm/original/8G1wll.gif)
and [Dylan Greenwood's slide](https://cdna.artstation.com/p/assets/images/images/023/618/038/original/dylan-greenwood-slide-animation.gif?1579789490).
All six frames of the first and four frames of the second were inspected. The
raised grip, open torso, free arm and staggered legs informed this pose. The
support hand originally reserved a place for knife artwork; the follow-up below
adds that artwork to the accepted pose and blaster placement.

On a wall jump, the support hand releases and both legs extend through the
accepted push-off. The character continues facing outward, or follows active
aim, and keeps the gun in hand. The existing airborne pose resumes afterward.
Grounded approach, impact bracing and sustained pushing retain their two-hand
poses. Physical movement, slide speed and jump impulses retain their behavior.

## Existing components extended

- `character_actions/walls.json` tunes the existing slide and jump control tracks.
  Coordinates remain wall-facing: negative X points away from the wall. Curves
  stay sparse and use the existing JSON/Blender contract. The shipped rig uses
  the left hand for support and the right hand for the blaster. The slide's
  lowered left ankle gives that leg its near-straight pose through ordinary IK.
- `character_animation.zig` excludes the named `weapon_hand` from slide contact
  planning. Facing defaults away from the wall for slides and wall jumps; aiming
  retains priority. Only brace/push actions request hip stowing.
- The existing wall probes, foot-contact intervals and IK still place the limbs.
  The supporting arm and knees keep their bend relative to the wall when aim
  changes facing. The free weapon arm uses the same bend convention as aiming.
  The existing foot-heading transition turns the feet outward on slide entry,
  making the authored quarter-turn point the toes down. That heading continues
  through push-off and stays independent of aim.
- The previous arm-release angle blend now handles selected limbs changing IK
  branch. This lets the knees transition from a wall-facing brace into the new
  slide without flipping immediately. Toe/heel links follow a blended ankle
  with their original lengths. The arc clears the queried wall and floor
  planes. Toe targets remain available for immediate push-off, but a separate
  planted flag records when the entry arc has reached them. Stable contacts
  interpolate along the wall, including while the foot angle changes.
- Initialization synchronizes the previous-facing and foot-heading snapshots
  with the selected pose, including an outward-facing initial slide.

There is no new loader, editor, render-placement path or movement mode. The
existing gun attachment, aim solver and muzzle calculation remain shared between
drawing and shooting. Grappling and moving/sloped surface support remain later
phases.

## Validation and review

Validation uses `bash scripts/character_animation_check.sh`: the repository
formatter, animation tests, game build and five-second smoke/capture workflow.
The full script passed **55/55 tests**, the game build and the five-second
smoke/capture with the success marker and no warnings, errors or panics.
`git diff --check` passed. Evidence is in
`artifacts/character_animation/tests.log`, `build.log`, `one_hand_slide_smoke.log`
and `preview.png`.

Before the first handoff, the independent reviewer inspected all six phase files, applicable repository
skills and the shared contact, IK, aiming, attachment and rendering paths. It
reported one actionable finding: **P2**, `src/character_animation.zig` — the new
knee transition could overwrite an already constrained ankle and move a sole
about 0.21 m through the wall during real brace-to-slide entry. Fixed by keeping
surface limits through the free-leg arc, clearing the preceding airborne brace,
and distinguishing a toe target from a planted contact. The correction preserves
bone lengths and the existing visible push-off. During verification, the longer
slide trial also exposed a small interpolation drift as foot angles changed;
interpolating the wall anchors explicitly corrected it. The full checks above
were rerun after these corrections. Those findings were resolved before handoff.

The subsequent leg-tuning iteration lowers the left slide ankle from -0.72 m to
-0.91 m and uses outward foot heading through slide and push-off. Existing
regressions now check one nearly straight leg, one bent leg, wall-facing soles,
downward toes and ankle clearance on both sides and through all tested aim
directions. The height-curve test uses the bent leg so its whole authored path
remains reachable during entry. The nearly extended leg releases on jump launch;
the bent leg retains contact until extension or wall removal. The full validation
script passed again after this iteration. Its independent reviewer inspected the
four-file delta, relevant shared code, repository skills, tests and pose evidence;
no actionable findings or optional suggestions were reported. Controller feel
remains for user testing.

The new runtime test checks both wall sides, one support hand, a grip above the
head, knees clear of the wall, the ready gun angle, downward travel of the grip,
outward/upward/inward aiming, forced shot sampling, gun attachment and outward
facing through push-off. The existing real Box2D trial checks three/eight slide
ticks before jumping, zero/five forced movement steps, sole clearance at five
interpolation fractions throughout entry, planted contact positions, unchanged
physical velocity/position, near-straight legs over several departure frames,
and gun availability. Render boundaries are checked
through wall turns as well as transitions with unchanged facing. Turning allows
the rig's small reflected shoulder offset; unchanged-facing boundaries retain
the strict tolerance. Bone lengths are checked throughout interpolation.

Native solver samples are exported to
`artifacts/character_animation/one_hand_slide_samples.json`. The corresponding
`one_hand_slide.svg`/PNG sheet was inspected, including both sides and aiming
directions. These are exact solver coordinates with the existing gun SVG, not
generated artwork. Controller feel and rapid transitions still need user testing.

## User testing

1. Run `zig build run -- --character-animation`; use **§ → Z** for close view.
2. Slide down a tall wall on each side. Look for the raised support hand, outward
   torso/gun, one nearly straight leg and one bent knee, and downward toes.
   **§ → D** shows the wall-contact targets.
3. Aim outward, upward and back toward the wall. The gun hand should stay free
   while the same anatomical support hand follows the surface. Release aim and
   check that the character returns to the outward-ready pose.
4. Wall-jump from a short and a longer slide. The support hand should release,
   the legs should extend, and the gun should stay in hand through push-off.
5. Release the wall, land, or leave its edge. Check the return to ordinary motion
   at normal speed and with **§ → S** slow motion.


## Knife artwork follow-up — accepted

The character now carries a straight double-edged dagger in reverse grip for
wall actions. On approach the dagger is readied before contact. Sustained ground
pushing drives it horizontally into the wall with both hands on the handle, bent
elbows and a forward torso lean over the knife (about 52 degrees). The raised
grip, bent front knee and nearly extended rear leg follow the supplied pushing
reference, with the staggered feet behind the hips and the arms reaching forward.
The stance fits the actual grip distance, including contacts near the maximum
pushing distance and optional artwork packs that use bare hands. This shifts
the hips and foot targets together using the existing arm limits. The gun uses the
existing holster transition. Aiming retains an established push even after gameplay
consumes horizontal input. Turning to shoot away from the wall frees the gun
arm and eases the torso upright until the knife arm is nearly straight. The
existing two-link solver derives that torso angle from the planted hand and
the rig lengths, using the aiming profile's hand reach. Feet and knife contact
keep their contact targets. Knees use the existing limb-release blend as the
feet turn, avoiding a sudden bend reversal. Releasing aim blends back into the
two-handed pushing pose.

During sliding the left hand holds the dagger angled 45 degrees down into the
wall, with half the blade buried. The right hand keeps the blaster. On wall jump
the dagger stays in the support hand through the short push-off clip before the
normal airborne pose resumes. All mirroring follows the wall side independently
of aim-facing. The blade draws before the first gripping hand so both sets of
fingers cover the handle during two-handed pushes.

The optional `knife` manifest entry supplies image paths, grip pivot,
blade base/tip and a second grip point on the handle. These use the closed hand's
source pixel scale. The blade midpoint determines both the wall contact and the
wrist offset; the second hand uses the same transform. Existing wall rays query
that contact height and ordinary arm IK reaches the two grip targets. Physical
movement and bone lengths are unchanged. The existing sparse brace/push/jump
curves author the preparation and forward effort pose.

The source SVG shares a `hilt` between the angled and horizontal blade views.
The `fixed` and `buried` groups make the full straight blade; `horizontal` ends
at the midpoint with the correct cut for a level push. They export separately
because SDL's SVG reader does not apply clip paths. A planted dagger draws only
the matching exposed portion; its tip stays hidden until it clears the wall
during withdrawal. `FramePose.knife` shares contact, readiness, orientation
and second-hand information with artwork and particle placement.
The blade layers follow the same texture loading, validation, atomic reload
and cleanup ownership as the rest of the art pack.

Downward sliding emits small debris through the existing `particle_effect` and
pooled `particle` components. The `wall_scrape` preset in `particles.json` controls
chip size, color, speed and lifetime. A fixed-step fractional budget limits the
shipped effect to 40 chips/second and scales slower movement by distance. Idle,
upward movement, missing/released contacts and discontinuous movement produce
no debris. Chips start at the shared blade contact, offset 2.5 cm outward to
clear their collider radius, and scatter away from the surface. The emitter's
optional `spawn_radius_m` preserves the old 18 cm default for existing effects;
the dagger uses zero spread in spawn position. There is no stain behavior.

Edit `character_art/curb_rat_v1/source/knife.svg` and check with:

```sh
python3 scripts/export_character_art.py
bash scripts/character_animation_check.sh
python3 scripts/export_character_art.py --preview agent-temp-files/wall-knife-reference/preview
```

`knife.svg` shows slide, aim-facing and jump departure. `knife_actions.svg` shows
preparation, pushing and returning to aim on both walls. These are native solved
poses. Their hair uses the existing static SVG preview and they do not simulate
debris. In game the accepted custom hair simulation remains active.

Automated coverage checks the two grip positions, forward lean, bent elbows,
horizontal pushing, body clearance, blade midpoint and hidden/visible tip layers,
approach/jump readiness, aiming, removal, physics/render sampling and bounded
emission at 60/120 fixed steps per second. Push-to-aim coverage uses neutral movement input and verifies knife-hand
continuity, near-straight support-arm reach, gun direction and returning to push
on both sides at ordinary, close and near-limit contact distances. In-game
transitions and debris appearance can be reviewed in artwork view with **§ → Z** for a close view.
