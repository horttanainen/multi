# Static slope and step adaptation

Status: accepted by the user on 2026-09-24, including slope running and automatic
stair climbing. Independent review, corrections, validation and user testing complete.
Baseline: `6a90e2d` (accepted kneeling and aiming).

## Behavior and ownership

Running retains its authored recovery shape and contact timing. The runtime
adjusts each foot's height and orientation to static terrain, adds a short
look-ahead lift over rising steps, and adjusts the pelvis within the available
leg reach. Kneeling, aiming turns and landing reuse the same constraints.
The rig, sparse motion curves, action clips and input settings are unchanged.

This extends `character_animation.zig`'s existing probes, toe anchors, knee
clearance and two-bone IK. `data.zig` still owns JSON decoding and asset memory.
No new editor or physics skeleton is introduced. Animation moves visual joints;
the movement controller still determines the physical body trajectory.

The controller integration lives in `movement.zig`. Grounded TowerFall movement
follows the support tangent in both directions instead of zeroing vertical
velocity or applying falling acceleration on an uphill run. After Box2D advances,
`physics.zig` calls the ground traversal resolver before updating contacts and
animation. It reconnects to nearby descending ground and climbs reachable stairs.
Actual jumps and upward separating motion bypass traversal, including forces
integrated during the physics step. All upward-facing body contacts are checked
so a collision that redirects motion around a ramp seam is not treated as takeoff.

For a blocked forward step, the resolver sweeps every solid player collider up,
forward and down. It checks the raised origin for overlap, requires a walkable
static landing surface within the height limit, and only uses the uncompleted
horizontal travel from that physics step. Low ceilings, excessive rises and
blocked routes retain ordinary collisions. Sensors are excluded, while solid
colliders retain their actual geometry and collision filters. The existing
Box2D helper owns the overlap/cast calls; no alternate collision system is added.
At a stair corner, the rounded player collider's radial hit normal is resolved
against the actual walkable polygon face. This allows starting against a riser
and low-speed climbing without requiring a running approach. Descents check the
height difference between the support faces as well as the body sweep distance,
so rolling around a ledge cannot split an excessive drop into accepted pieces.

A successful traversal supplies its queried contact to the existing grounding
update, so animation receives the corrected body and support in the same step.
The original ground sweep also falls back to the existing body-contact query
when it misses an initial overlap, and ignores steep hits while looking for
support. Liero movement remains on its existing path.

`towerfall.maxStepHeight` is optional in movement profiles (default 0, disabling
step-up). `movements/towerfall_keep.json` sets it to **0.5 m**. It is validated
between 0 and 0.75 m. Ground-following searches down by the larger of the step
limit and grounding sweep distance, allowing a small collision skin tolerance;
larger drops become airborne normally. Gameplay colliders and jump input remain
the same. Animation probe range is independently configured below.

## Surface queries and contacts

Ground queries use the existing Box2D helper and foot-sensor collision filter.
The controller's support normal defines the reference plane; each probe is
centered on that plane at the target's X coordinate. Accepted footholds are
static polygon faces within the configured slope limit. Dynamic/kinematic
supports, steep faces and rounded corners without a matching plane are skipped.

Each accepted surface stores its world point, normal and finite horizontal
extent. Toe and heel queries can therefore find separate step heights. A face
does not become an infinite floor beyond its ledge. Swinging feet get one extra
probe in the direction of travel to help clear a rising step.

Existing world-space toe anchors remain fixed during stance. They are rechecked
against fresh surface queries, contact intent, correction distance and leg
reach. Losing support, jumping or exhausting reach releases the anchor using
the existing recovery. Moving-support anchors remain a later phase.

After target blending, sole clearance and pelvis fitting reuse the current leg
solver. Low poses also check knee clearance. When reach prevents a requested
placement, a bounded iteration alternates sole clearance and reach projection,
then invalid anchors are released. Bone lengths remain fixed.

Rendering uses cached previous/current faces and the existing body interpolation;
it performs no physics queries or contact acquisition. It reapplies contact,
sole, knee and reach constraints to interpolated controls. Selecting a valid
face at each rendered foot position avoids inventing a ramp between two steps.

## Locomotion JSON

`character_locomotion/run.json` now uses schema version **2**, ID `run_v2`.
`surface_tolerance_m` replaces `flat_height_tolerance_m`; `terrain` adds:

| Field | Default | Meaning |
| --- | --- | --- |
| `probe_up_m` / `probe_down_m` | 0.65 / 0.65 m | Search above/below the support plane. |
| `max_slope_radians` | 0.7853982 (45°) | Maximum animation foothold slope; controller support rules also apply. |
| `pelvis_limit_m` | 0.18 m | Nominal terrain-driven pelvis adjustment from the authored height. |
| `blend_seconds` | 0.06 s | Terrain height/tilt response. Height follows a sloped target directly to avoid stance lag. |
| `swing_clearance_m` | 0.04 m | Additional lift when the look-ahead probe detects a rising step. |
| `lookahead_m` | 0.12 m | Distance of that extra swing probe. |

`surface_tolerance_m` (0.025 m) distinguishes meaningful changes in surface height.
Search dimensions, slope, pelvis correction, response and clearance are validated
for finite values and supported ranges. Older or invalid profiles are rejected;
an unsuccessful reload preserves the installed assets and player state.

The pelvis limit governs nominal adaptation and reach fitting. Knee-clearance
safety can raise the pelvis further on an obstructed low pose. A surface that
cannot be reached may require releasing a foot rather than preserving both
contacts. These animation corrections are cosmetic; physical stair traversal is owned by
the movement controller described above. Hitboxes retain their dimensions.

Blender can later export the same named motion controls and this separate
locomotion profile. Terrain-specific solved joint positions are not authored data.

## Validation and manual review

Run the terrain scene directly:

```sh
zig build run -- --level levels/animation_terrain.json --character-animation
```

The small `--level` option uses the level component's existing loader and reload
path; the normal level rotation is unchanged. Overview and benchmark launch
modes keep their existing priority. The scene uses the existing TowerFall
movement profile, stone texture and a dark fortress background. It contains roughly 15° and 31° ramps,
**0.3 m and 0.5 m stairs**, with both ascending and descending sections.

1. Run in both directions; inspect foot tilt, touchdown, toe planting and the
   transition between flat ground and a ramp. Use § then Z for close view and
   § then S for slow motion.
2. Run up and down both staircases without pressing Jump. Also stop against a
   riser and start again. Check continuous stepping, stopping partway across an
   edge and the transition back onto flat ground.
3. Stop on either slope, hold Down to kneel, then hold Shoot and turn the aim
   across the character. Check the supporting knee, planted forward foot and hips.
4. Land on a slope or step, both stationary and with sideways travel. Check
   impact compression and continued stepping, then jump away again.
5. Compare the accepted flat-ground run and kneel. § then R reloads the assets.

Use the existing validation script for formatting, regression tests, build and
the five-second smoke run. To smoke-test this fixture:

```sh
bash scripts/character_animation_check.sh -- --level levels/animation_terrain.json --character-animation --character-animation-capture artifacts/character_animation/terrain_preview.png
```

Regression coverage includes four slope orientations, multiple running speeds,
both travel directions, stable planted toes, fixed bone lengths, finite step
boundaries, kneeling aim turns on slopes/steps, landing, and five render fractions
per physics step. A controller integration test exercises real input, movement,
Box2D contacts, kneeling, aiming, jumping, landing and running in both directions
on slopes, including flat/ramp seams. The full-height body fixture also traverses
0.2, 0.3, 0.4 and 0.5 m stairs in both directions without jumping. Starting against
0.3 and 0.5 m risers, low-speed traversal, and stopping/resuming at an edge are
also covered. Negative cases cover taller walls, a low ceiling, disabled climbing,
jumps, a larger drop and upward forces applied after movement but before Box2D.
Existing flat-ground, airborne, aim, wall and failed-reload regressions remain.

Exact solved uphill-running joints are exported to
`artifacts/character_animation/terrain_run_samples.json`; the corresponding
`terrain_run_review.svg` is a visual review sheet. Level and collision overviews
are under `artifacts/character_animation/terrain_level/` and can be regenerated
with `bash scripts/level_overview.sh levels/animation_terrain.json`.

Moving/destructible rubble, body-local anchors and a committed future touchdown
planner are deferred. The current swing adaptation uses immediate probes and a
short look-ahead. Automated checks establish the tested geometry and transitions;
interactive movement and animation feel have also been accepted by the user.

Before this correction, the full validation script passed **72/72 tests**, built the game and completed
the terrain-level five-second smoke with the success marker and capture. There
were no smoke warnings, errors or panics. `git diff --check` passed. The exact
uphill-running pose sheet, terrain collision overview and game capture were
inspected. The game capture establishes startup and rendering; traversal is
covered by the described regressions and still needs interactive user testing.

Before independent review, implementation tests exposed slope-height filtering
that left stance feet hovering, and the controller's initial-overlap sweep miss.
Directly following a slope's target height fixed the former; reusing body
contacts on a missed sweep fixed the latter. Tests also verify that IK reach
clamping cannot push cleared soles back into the tested surfaces.

## Initial independent review

The independent reviewer inspected all ten phase files against `6a90e2d`, plus
the existing movement, Box2D, IK, JSON and level-loading owners and applicable
repository skills. It found one actionable issue: **P3**, the look-ahead query
in `character_animation.zig` nested its successful optional path instead of
handling a missing surface first. This now uses `orelse break :terrain`, as
required by the guard-clause skill. No runtime correctness or ownership findings
were reported.

## Slope-running and stair-climbing correction

User testing showed that the initial movement limitation prevented the intended
result: descending slopes selected a fall pose, and ordinary stairs blocked the
player. This iteration fixes that behavior in the existing movement owner rather
than masking an airborne controller state in animation.

The initial traversal test only required some supported frames and limited
progress. It now requires all 120 running steps to remain supported/grounded in
both directions on each slope, more than 15 m travel in two seconds, and the
configured running speed. Additional tests cover actual stairs, ground seams,
clearance and release conditions as described above. The larger animation probes
also keep the leading sole clear before the body reaches a 0.5 m stair.

The test scene now contains 0.3 m and 0.5 m staircases. This correction is included
in the accepted static-terrain phase. Moving/destructible rubble remains separate.

The correction reviewer inspected all eleven iteration files and the existing
movement, physics, animation, Box2D and data owners. It found one actionable
**P2** issue in `movement.zig`: traversal used eligibility captured before the
physics step and could erase upward velocity produced during that step. Fixed
by checking post-step separation against the current body contacts before
climbing, snapping or realigning. A force-through-Box2D regression confirms that
takeoff position and velocity survive unchanged. Existing slope and seam tests
confirm that ordinary uphill travel is still supported.

During the correction pass, an additional implementation test exposed sticking
when starting against a riser. Resolving the true tread face fixed this; stopping
and resuming at a corner is also tested. The large-drop regression caught a
related ledge case, fixed by measuring the support-face height difference.
These were implementation findings, separate from the independent review.

Final correction validation passed **78/78 tests**, built the game and completed
the terrain-level five-second smoke with its success marker and capture. No
warnings, errors or panics were logged. `git diff --check` passed. The updated
level/collision overviews were inspected. The user subsequently tested and
accepted the slope and stair behavior.
