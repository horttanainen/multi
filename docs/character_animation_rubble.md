# Moving and destructible rubble support

Status: accepted by the user, including generic solid support, L-shaped support
corrections and the SVG blood-color fix. Independent review and validation are
complete; the user has authorized the phase commit.
Baseline: `657ac10`, the accepted static slope and stair phase.

## Behavior and ownership

`movement.zig` extends its existing ground traversal and contact queries to solid
objects that collide with the character, including giblets. Sleeping and awake
bodies are both eligible. Queries use actual solid collision pairs instead of an
additional object-category whitelist. Runtime player colliders use collision
group zero. Sensors,
the player's own body and non-colliding shapes cannot become supports. Foot
probes skip these shapes before selecting the closest surface; their existing
finite polygon face and slope constraints still apply.
The existing step-height limit, complete-body clearance sweeps, slope limits and
jump separation rules apply. Contacts refresh their local points and normals
when a support moves or rotates; invalid or excessively tilted supports release.
Horizontal acceleration targets movement relative to the supporting point's
velocity, including rotation. Existing airborne aiming and jump rules remain.

Step clearance is checked before Box2D resolves a low obstacle. The player is
raised along the verified path, Box2D supplies horizontal travel, and the existing
post-step traversal settles the player onto the surface. The probe includes the
physics contact margin so early contacts do not shove the obstacle first.
When a taller obstruction belongs to the same body supporting the character,
walking is limited to the available clearance relative to that support. Separate
objects retain collision-driven pushing. No body is frozen or has its velocity
reset; external impulses can still move an L-shaped support and carry its rider.

`character_animation.zig` extends the current finite surface probes, foot
planting, IK, sole clearance and pelvis adjustment. Each planted foot stores its
own body/shape identity, pool activation and local anchor. The world anchor is
resolved from the current support transform and released on lost contact,
excessive slope, reach failure, disabled/destroyed support or lifecycle change.
Different feet may use different bodies. Cadence uses horizontal displacement
relative to support velocity, so being carried does not itself create a run.

Previous/current foot and face snapshots carry support transforms. Rendering
interpolates those transforms and reconstructs local anchors and face endpoints;
it does not query Box2D. Entity drawing and animation reuse `box2d.zig`'s shared
transform interpolation, including the shortest rotation across ±π. Polygon
collision radii are included in both local endpoints and world face bounds.
Replaced moving supports discard the previous face. Static surfaces retain the
existing finite-face interpolation rules.

`pool.zig` extends its existing reverse membership map with an activation number.
Every acquisition, including recycling an active body, gets a distinct number.
Release clears it. This distinguishes new uses of the same still-valid Box2D
body/shape IDs, including reuse between animation updates. Movement owns the
shared support identity validation used by the controller and animation.

No new animation clips or JSON animation schema are required. Existing asset
loading, authored controls and the Blender export plan remain applicable.

## Test level

```sh
zig build run -- --level levels/animation_rubble.json --character-animation
```

This extends the terrain course with a lower rubble lane and starts the players
there. From the left spawn, travel right to low dynamic stone blocks around
0.3 m and 0.5 m, generated irregular rubble piles, and larger breakable objects.
The blue-gray low L and tan tall L are each one triangulated dynamic body, loaded
from simple SVG silhouettes through the existing image/collider path.
The accepted ramps and stairs remain above for comparison. The new `rubble`
level entity type calls `rubble.spawnPlaced`: normal generated debris with its
normal triangulated shapes, damage behavior and pools, placed without a launch
impulse. Piece generation is seeded by the serialized entity ID. Pieces remain
physical and settle after loading; collision rounding affects visible dimensions.
The shared image loader normalizes decoded surfaces to BGRA before sprite
painting, alpha masks or rubble generation read their bytes. SVG Ls previously
swapped red and blue blood channels, and the stone fixture exposed RGB/XRGB
images without the expected alpha channel. Both now use the same loading path;
rubble no longer needs its own conversion.

Manual checks:

1. Run over both low blocks and irregular piles, including starting against an
   obstacle. Repeat slowly with the debug slow-motion option (§ then S).
2. Stop on a piece and aim in both directions; watch the feet as it moves or tips.
3. Stand across neighboring pieces. Shoot a supporting piece and check release,
   falling and landing. Break the larger objects to produce ordinary debris.
4. Jump and aim over rubble, then revisit the original slopes and stairs. Use
   § then Z for zoom and Ctrl+R to reset the level.
5. Walk along the low L toward its upright; it should step up without propelling
   the L. On the tall L, hold toward the upright; walking should stop relative to
   the L. Push a separate tall block from the floor to compare.
6. Produce giblets by killing the other player and walk across the settled pieces.
   Small loose pieces may move or tip, releasing contact normally.
7. Spill blood on both L-shaped objects; stains should remain red, and the empty
   parts of their silhouettes should stay transparent.

The existing workflow formats, tests, builds and runs the five-second smoke:

```sh
bash scripts/character_animation_check.sh -- --level levels/animation_rubble.json --character-animation --character-animation-capture artifacts/character_animation/rubble_preview.png
```

Regression coverage adds actual controller traversal of awake/sleeping dynamic
0.3 m and 0.5 m obstacles with rounded triangle colliders; local anchors and
render interpolation on translating/rotating supports; support-relative idle
cadence; real controller carrying and support disable/recovery; separate supports
under each foot and release after tipping; destruction, pool release/reacquire
and active recycling. The accepted static-terrain and action tests also run.
Review regressions cover destroyed/recycled supports replaced by lower surfaces,
asymmetric supports rotating across ±π, and a planted toe near a rotated rounded
triangle's actual face endpoint.
The current revision adds pooled giblet stepping/planting, physical collision
filters and group overrides, low/tall L behavior in both directions, external
impulses on the supporting L, and pushing separate objects from terrain or another
dynamic support.

Interactive feel and unpredictable rubble piles remain user review items.

## Review and validation

One independent review covered the phase changes in movement, animation, pools,
rubble generation/placement, level loading, tests and documentation, including
repository skills and reuse of existing owners. It reported three actionable P2
findings, all fixed before handoff:

| Finding | Correction |
| --- | --- |
| A replaced moving support could remain as a stale render clearance surface (`character_animation.zig`). | Discard incompatible moving-face snapshots, including different pool activations. Added lower-replacement coverage for actual destruction and recycling. |
| Feet and entity drawing disagreed when support rotation crossed ±π (`character_animation.zig`, `box2d.zig`). | Extend the shared Box2D transform interpolation and reuse it for faces and anchors. Added an asymmetric rotating-support regression. |
| Rounded face bounds differed between fixed-step probing and rendering (`character_animation.zig`). | Derive both world bounds and local endpoints from the radius-offset face. Added a near-endpoint planted-foot regression. |

The source-image pixel-format crash was found during implementation smoke testing
and fixed in `rubble.prepare`, separately from the review findings. The test level
was also reframed to keep its lower lane visible above the HUD.

At the previous handoff, all **86 tests** passed, the game built, and the rubble-level
five-second smoke logged its success marker and capture without warnings, errors
or panics. `git diff --check` passed. The updated game capture and visual/collision
overviews were inspected. Interactive traversal and destruction feel still await
user testing; the smoke test establishes startup and rendering, not play feel.

The generic support/L revision received one independent review of movement,
animation probes, collision filtering, tests and fixtures, including integration
with the prior rubble changes. It reported one P2 finding:

- **Positive collision groups with an empty mask:** Box2D's world queries reject
  a zero-mask shape before our filtering callbacks, even if matching positive
  groups would force a physical collision. This affects movement sweeps and foot
  probes. **Rejected as a current-game defect:** both solid player colliders in
  `player.zig` retain Box2D's default group zero, with no player configuration for
  changing it; a zero-mask object therefore cannot collide with these players.
  Matching positive groups with empty masks remain an unsupported future
  configuration of the query path. Added a regression proving that an empty-mask,
  positive-group object does not become a false support for a group-zero player,
  and narrowed the documentation's collision-group claim. No dependency changes
  or second query engine were introduced.

The reviewer found no other actionable issues. After the final regression,
**91 tests**, the game build and the five-second smoke passed without warnings,
errors or panics. `git diff --check` passed. The level collision overview and
startup capture were inspected. The low/tall L tests
cover both directions, starting flush, starting nearby and approaching from a
distance. Interactive feel and blocking against a rotating L remain manual
verification gaps; the automated impulse test covers linear support motion.

The blood-color correction received a separate independent review of image
loading and cleanup, sprite painting/copying, rubble generation, texture uploads
and its two regression tests. No actionable findings were reported. The tests
reproduced the incorrect SVG stain color and surface format before the fix. All
**93 tests** now pass, including red staining on both Ls, retained transparency,
and exact decoded color/alpha preservation across SVG and PNG assets. The game
build and five-second smoke passed without warnings, errors or panics, and
`git diff --check` passed. The startup capture was inspected; it contains no
active blood stains, so the in-game splatter check remains for user testing.
