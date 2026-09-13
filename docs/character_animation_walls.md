# Procedural wall poses

Implemented against `69c9656`; independent review and corrections are complete,
including the wall-jump extension iteration. Accepted by the user on 2026-09-13.
The requested wall-slide revision follows as a separately reviewed phase.
Grappling and rope animation are deferred.

## Behavior

- Approaching a static upright wall while holding toward it raises both hands.
  A speed-based lookahead starts the brace before the body reaches the wall.
  The running stride continues during approach.
- At contact, the pelvis briefly compresses according to approach speed. Holding
  toward the wall for 0.18 seconds settles into a leaning, two-hand push with a
  lower pelvis and staggered, planted feet.
- The movement controller's wall-slide state selects a braced airborne pose with
  bent legs and soles turned toward the wall. Hands and feet follow the wall
  vertically as the body slides.
- An actual wall jump triggers a 0.22-second push-off clip. Hands release
  immediately; reachable toes briefly keep their world positions as the hips
  move away, extending the knees. Each foot releases at its reach limit, at the
  end of its authored contact interval (44 ms), or if the surface disappears.
  Released jump feet cannot reattach during that jump. The clip holds extended
  legs through its first 88 ms before folding into the airborne pose.
  The character briefly keeps facing the wall before resuming travel-facing
  motion. This event works even with zero forced-movement steps configured.
- Neutral input, moving away, leaving the wall's edge, or removing the wall
  releases the brace. Existing pose transitions blend back to locomotion.
- Both hands remain anatomically consistent through turns. The initial weapon
  behavior is to stow the blaster at the hip for two-hand wall actions. Aiming
  takes priority: the gun arm aims and the free hand can retain an existing wall
  contact. Aim alone does not initiate a wall push. Forced shot sampling bypasses
  holstering and uses the existing aimed grip/muzzle calculation.

The initial hip-stow choice was presented during implementation as a configurable
default. User feedback on its appearance and timing is part of this phase's review.

## Existing owners extended

`movement.zig` adds a one-fixed-step `wallJumpedDirection` event at the existing
wall-jump execution point. Its duration is independent of forced lateral movement.
Velocity, jump timing, collision bodies, friction and wall-slide physics retain
their existing behavior.

`character_animation.zig` owns wall action state, approach/contact timing, hand
and foot targets and holster blending in its existing per-player state. It
consumes the shared `movement.locomotionDirection`, including captured airborne aiming input.
Existing action curves, body transitions, foot planting, limb IK and world-space
attachments produce the pose. Wall-facing clips are mirrored when aiming requests
an opposite facing; the bracing arms retain their bend side relative to the wall.

Surface probes reuse `box2d.castRayClosest` and the wall sensor collision filter.
They run during the fixed animation update. Each hand's actual contact height is
queried; grounded hand contacts retain their world height within the surface and
height bounds, and sliding contacts follow the body. IK limits the reach.
Wall targets are blended into fixed-step controls once; interpolating those
controls with the body preserves stationary world contacts. Rendering performs
no additional physics queries. On contact release, a short blend of upper-arm
and elbow angles preserves limb lengths while returning to the ordinary IK bend.
Wall-foot contacts share the existing rendered toe-anchor correction and reach
limits with floor planting, while retaining separate surface state. Jump contact
release uses the existing IK and transition offsets. Foot heading stays oriented
toward the wall during slides and push-off, including when aiming away. The
existing diagnostics show cyan wall-hand and wall-foot targets.

The sprite renderer and `player.weaponFrame` continue to consume the character's
shared placement. A stowed weapon is placed at a named pelvis attachment and drawn
between torso and near limbs; it returns to the selected weapon hand for aiming.

## JSON and Blender compatibility

`character_actions/walls.json` contains four ordinary motion clips: `brace`,
`push`, `slide`, and `jump`. Each uses the existing named control bindings,
normalized phase, interpolation handles, units and rig ID. `push` contact
intervals request floor planting; `slide` and `jump` intervals request wall
contacts. Jump contacts must begin at phase 0 because they represent launch
contacts, not later reattachment. `brace` keeps the underlying stride contacts.
Hand surface contacts remain runtime state. Tracks use two or three keys; the
jump extension, hold and recovery are curves rather than dense samples.

The wall profile's scalar settings are:

| Setting | Initial value | Purpose |
| --- | --- | --- |
| `anticipation_seconds` | 0.10 s | Approach-speed lookahead. |
| `probe_distance_m` | 0.75 m | Maximum wall search distance from the body. |
| `contact_distance_m` | 0.35 m | Near-wall threshold for impact and push timing. |
| `blend_seconds` | 0.06 s | Entry, exit and holster response. |
| `push_delay_seconds` | 0.18 s | Contact time before sustained pushing. |
| `full_impact_speed_mps` | 9 m/s | Approach speed that produces full compression. |
| `impact_compression_m` | 0.09 m | Additional impact pelvis compression. |

`character_rigs/humanoid.json` adds `weapon_holster` on `pelvis`, with its local
offset and rotation. These curves, scalar properties and named attachment can be
authored/exported by the planned Blender tooling. Surface queries, state selection
and final solved elbows/knees remain runtime behavior.

`data.zig` extends the existing bounded, strict JSON loader and shared candidate
arena to six files. The wall profile and clips validate before atomic replacement;
failed replacement preserves live assets and pose, and successful replacement
clears transient wall contacts and holstering. Use **§ → R** to reload.

## Validation and review

`bash scripts/character_animation_check.sh` passed **54/54 tests**, the game build,
and the five-second smoke run with the success marker and screenshot capture.
The smoke log contains no warnings, errors or panics. `git diff --check` passed.
The full script passed after the initial review corrections and again after
the wall-jump extension review correction. Evidence is in
`artifacts/character_animation/tests.log`, `build.log`, `walls_smoke.log`, and
`preview.png`. The final game capture and regenerated `wall_poses.svg`/PNG were
inspected; the smoke capture shows startup, while the pose sheet covers wall poses.

New tests cover both wall sides, anticipation, sustained pushing, interpolated
hand placement and bone lengths, holstering, aiming away with a free-hand contact,
neutral input, wall removal/edges, unsupported moving/rotated surfaces, relocation,
and atomic profile replacement. They also require feet to remain planted for
seconds beyond the push clip's duration, validate forced shot geometry while
holstered, and compare adjacent render endpoints during partial brace entry,
release, re-entry and wall removal while aiming away.
A real Box2D movement/input trial covers running
into a wall, ground takeoff, wall sliding and wall jumping with zero and nonzero
forced-movement durations. It also verifies that animation leaves physical
position and velocity unchanged.

Native samples are exported to `artifacts/character_animation/wall_samples.json`
and `wall_jump_samples.json`. The static pose sheet uses these solver coordinates
and the existing blaster SVG. It demonstrates poses, not live gameplay timing.
During implementation, visual inspection led to preserving wall-facing through
the short push-off and preserving the free elbow's bend side when aiming away.

The initial independent reviewer inspected all phase changes, component reuse, applicable
repository skills and the recorded validation evidence. It reported three P2
issues, all in `src/character_animation.zig`, and no optional suggestions:

| Finding | Correction and verification |
| --- | --- |
| Held pushing lost its foot contacts when the clip reached phase 1. | Shared contact evaluation now includes the final endpoint of a non-looping clip whose contact extends to phase 1. Looping contacts retain half-open intervals. The pushing regression requires both feet to remain locked with stable world anchors well beyond the clip duration. |
| Releasing a wall while aiming away switched IK branches immediately and snapped the free elbow. | Contact release blends from the preceding upper-arm and elbow angles while retaining bone lengths. Both wall sides are checked at the release boundary and subsequent interpolated frames. |
| Wall-hand weights were applied during both fixed update and render interpolation, changing the pose at a shared frame boundary. | Apply the contact blend only during the fixed update. A regression compares tick N at alpha 1 with tick N+1 at alpha 0 during partial entry, release and re-entry. |

The reviewer ran no mutating checks. Correction validation uses the same phase
script. Manual controller feel and rapid visual transitions remain for user
testing.

### Wall-jump extension iteration

User testing identified that the original jump clip kept both knees bent. This
iteration adds wall-foot contacts, a visible extended follow-through and a sparse
three-key recovery curve. The actual movement trial now requires both legs to
exceed 95% of full reach for at least three early physics frames. A separate test
covers fixed world toe positions at interpolated times, both wall sides, aiming
away, contact expiry/reach release, wall removal and no reacquisition. These
checks also preserve bone lengths and adjacent render endpoints.

`artifacts/character_animation/wall_jump_extension.svg` is an exact 12-panel
sequence: the preceding slide and the first 11 wall-jump physics samples, 1/60 s
apart. It uses exported solver joints, not generated artwork. The sequence was
visually inspected.

The iteration reviewer found one P2 in `src/character_animation.zig`: sliding
contact planning always sampled foot height at phase 0, overriding valid animated
height curves. This is fixed by sampling the current slide phase while retaining
world anchors during push-off. A regression loads a valid height ramp through the
shared JSON loader and checks multiple phases on both walls: the ankle follows
the authored height and the toe stays on the surface. No other actionable issues
or optional suggestions were reported.

The reviewer compared this iteration with saved pre-iteration snapshots. A fresh
reviewer spawn was blocked by the conversation's agent limit, so an existing
independent reviewer received a new task packet. It ran no mutating checks. Live
controller feel remains for user testing.

## User testing

1. Run `zig build run -- --character-animation`. Use **§ → Z** for close view,
   **§ → S** for slow motion and **§ → D** for contact targets.
2. Run into a tall wall from each side. Hands should reach before contact, the
   hips should compress briefly, then both hands should push while input stays held.
3. Release or reverse the direction; the character should leave the pushing pose.
4. Jump toward the wall, slide down it, and wall-jump away. The feet should stay
   against the wall briefly as the hips launch away, both legs should straighten,
   then fold back into the airborne pose. Check at normal speed and with **§ → S**
   slow motion; confirm the familiar movement response remains.
5. Aim and fire while bracing or sliding, including aiming away from the wall.
   Check the free hand, gun pickup/stow and facing transitions.
6. Leave a wall edge, destroy its surface, respawn or reload the profile during
   contact. Old hand and foot targets must release.

This phase supports static upright faces. Slopes, moving or rotating rubble,
grappling, and body artwork remain separately planned work. The current weapon
aiming system can still point a gun into a wall; muzzle obstruction is outside
this visual-pose phase.
