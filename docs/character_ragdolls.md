# Ragdolls — phase 6C

Status: accepted by the user, with explicit commit authorization. Independent
review and corrections include the repeated-death performance work and reusable
explosion storage. The remaining Tower Keep frame-time spike and obstructed
respawn are documented below for follow-up.
The subsequent [performance-polish phase](ragdoll_performance_polish.md) addresses
the collision-search cost and native build performance; it is accepted by the user.

## Behavior

Ordinary death creates a connected corpse from the final procedural pose,
including player tint, facing, root velocity and relative limb motion. The
original player follows the existing death, score and respawn lifecycle.
Gravestones and weapons retain their existing behavior; the gun is not a new
physical corpse part.

Each corpse has a fresh **100 HP shared across all its parts**. Damage to its
head, torso or limbs subtracts from the same pool:

| Remaining health | Result |
| --- | --- |
| Above 0 | Continue simulating the ragdoll. |
| Above −40, through 0 | Remove every part and joint with particle bursts. |
| −40 or below | Release the joints and apply the same weighted anatomical selection as live-player gibbing. |

Surviving giblets keep their actual Box2D bodies, pose, velocity and pool
activation identity. They regain the existing 1 HP giblet behavior and severed
blood overlays. Consumed parts emit the existing destruction effect and return
to their pools. Whole-corpse removal distributes one particle burst budget over
the body instead of multiplying a full burst by every limb. Gibbing uses the
same consumed-part emission amount as live gibbing. Respawning does not remove
a corpse or record another kill.

Connected ragdolls emit **no blood from movement or environmental impacts**.
Detached giblets retain their existing impact spatter. Death, gibbing and
whole-corpse removal still emit their configured blood effects.

An explosion samples each overlapping limb but subtracts health once per corpse,
using the strongest sample. Impulses still affect individual bodies. A projectile
retains one attack identity across its contacts and explosion; a hitscan shot
and its explosion likewise share one identity. Fresh corpses and new giblets
ignore the attack that created them. Separate pellets remain separate attacks.

Arrows can stick into a corpse and damage its shared health. If the attached
part survives gibbing, the arrow remains attached. Removal, recycling and artwork
reload use the existing projectile attachment checks: released arrows fall and
stick again, with damage and player collisions disabled.

The default limit is **eight corpses**. Creating a ninth retires the oldest
whole corpse. Connected parts are reserved in the existing giblet pools so a
new loose giblet cannot recycle an individual corpse limb. Solid parts use the
existing player support/foot-anchor filters and collide with rubble.

## Ownership and tuning

- `ragdoll.zig` owns connected body/joint groups and whole-corpse recycling.
- `damage.zig` owns the health entry on the root body; limb `shared_health`
  entries point to it. `destruction.zig` dispatches whole-corpse destruction.
- `gibbing.zig` supplies snapshots, survivor selection, shared part bodies and
  blood effects. Pools are prepared for the corpse limit plus two gibbing deaths.
- `character_art.zig` renders through the existing body-part appearance map;
  no corpse textures or duplicate renderer are created.
- `physics.zig` consumes transient hook, particle, giblet and projectile contacts
  after every fixed step, including catch-up steps. Stain painting and texture
  uploads remain in `deferred_work.zig` outside the physics loop.
- `particle.zig` disables and returns a droplet to the pool immediately when its
  contact is captured. The blood reserve covers two overlapping direct-hit /
  explosion / consumed-part bursts (1,020 bodies with the current art and preset).
- `projectile.zig` retains explosion scratch collections between blasts: an
  ordered body list, a body-ID set for duplicate shapes, and an insertion-ordered
  health-owner map for strongest-limb damage. Setup reserves capacity against
  the actual world body count, including disabled pool members. Before a blast,
  the same reservation grows if new objects exceed the existing capacity; it
  never truncates the query at a hardcoded body limit. The callback and damage
  grouping use this reserved memory, then clear entries while retaining capacity.
  Level cleanup frees it. Damage order remains sorted by body ID before grouping.

Explosions currently resolve sequentially. Scratch preparation rejects a nested
explosion before it can overwrite pending outer damage. Future synchronous chain
reactions would need queuing or independent scratch storage. Pressure fields and
visuals keep their existing allocation behavior; this change concerns body
queries and pending damage only. The performance runner reports and rejects
scratch growth during benchmark events; unusual world growth can still allocate
before a subsequent blast.

`damage_rules.json` contains `ragdollHealth`, `maximumRagdolls` and the existing
`gibHealthThreshold`. Restart after changing these rules; the count must be 1–64.

Each non-root art binding has optional `ragdoll` metadata in
`character_art/curb_rat_v1/manifest.json`:

```json
"ragdoll": {
  "parent": "left_thigh",
  "reference_angle": 0,
  "limits": [-0.05, 2.75]
}
```

The hinge joins this binding to its named parent at the child's artwork pivot.
Angles are radians between the parts' source axes in the right-facing,
world-Y-down pose. `reference_angle` defines the zero of the relative angle;
`limits` bound motion around it. Facing left mirrors these values. Source-axis
offsets are accounted for, including the gripping-hand variant.

The current graph has one torso root and 14 hinges. Knees and elbows have
opposite bend directions; wrists, ankles, neck and pelvis have narrower limits.
The loader validates names, finite ordered limits, one root and absence of
cycles. Older art packs may omit the entire graph, retaining their previous
ordinary-death behavior.

Press §, then R to reload joint/art metadata. Successful reload clears existing
corpses before replacing their shared art and pools. Failed preparation preserves
them. Level cleanup releases every corpse joint and part before entity cleanup.

## Validation and user testing

Use the existing runners:

```sh
bash scripts/character_animation_check.sh
bash scripts/explosion_perf_test.sh 2 air-ragdoll ragdoll-gib ragdoll-remove air-death
bash scripts/explosion_perf_test.sh 2 ragdoll-projectile ragdoll-hitscan
bash scripts/explosion_perf_test.sh 12 tower-keep-ragdolls
```

The dedicated character test suite covers pose/motion continuity, mirrored joint
limits, shared health and threshold equality, birth-attack protection, weighted
in-place release, whole-corpse recycling, failed/successful artwork replacement,
score/respawn independence, shared-health serialization, arrow release and a
120-limb explosion. CPU fixtures
exercise real physics and ownership; particle emission and rendering are covered
by the runtime checks. Fatal physical-projectile and hitscan scenarios also
verify that their following explosions leave the fresh corpse at 100 HP.
Additional regressions exercise a blood collision in the first of three physics
steps within one rendered frame, immediate pool reuse, and contacts on both the
root and limbs of an intact corpse without any impact emission. A fatal physical
projectile on the same step as a turn verifies that the corpse captures the
current animation facing. Restoring the incorrect order makes this test fail.
Scratch regressions cover 5,121 bodies with duplicate shapes, growth after setup,
large/small/empty query reuse, cleanup/reinitialization, and destroying all eight
corpses while their damage entries are still queued. A separate case crosses
only the body-set load threshold to verify that its allocation is counted.
Visual quality still needs playtesting.

`tower-keep-ragdolls` preserves normal respawn health and fires a real missile
from 0.5 m left of the victim's current position. It repeats as soon as the death
capture and respawn permit, allowing corpses to accumulate. Obstructed missiles
retry without resetting health, with counters retained across the attempts.
This is an automated close-range reproduction, not a recording of controller
input. The runner rejects any particle/body allocation during the entire
capture and any death frame above 33.333 ms. Tower Keep's expected first-stain
texture migrations remain allowed; other scenarios retain their existing check.

The original repeated-death reproduction reached a 149.470 ms frame on the
second kill, including 143.099 ms of physics, and grew the blood pool by 138
bodies. Intact limbs each emitted their own impact burst. Catch-up steps then
lost earlier blood contacts, retaining droplets that should already have become
stains. The correction removes intact-corpse spatter and consumes contacts before
Box2D replaces them on the next step.

The initial phase review found one P3 issue: adding shared health left the public
entity serialization helper's exhaustive model switch incomplete. Serialization
now resolves the limb's health owner, and a dedicated regression calls that API.
No other actionable findings were reported in that review. During runtime checks, the
implementing agent found excessive particle multiplication on corpse removal;
the shared burst budget addresses that separately from the review finding.

Initial phase validation: **129/129 tests**, build and the five-second smoke/capture passed
without runtime warnings or errors. All six benchmark scenarios above completed
two events. After the corrections, the four affected gib/removal/direct-weapon
scenarios were run again: no particle/giblet bodies or texture migrations were
created during their trigger or capture windows. Measured maximum death frames
were 17.333 ms for corpse gibbing, 17.281 ms for corpse removal, 17.848 ms for the
fatal projectile and 17.967 ms for hitscan. Before bounding its burst, removal
peaked at 112.346 ms. These are individual runs, not frame-time guarantees.

The initial reviewer inspected the full implementation before that correction pass.
The implementing agent checked the serialization correction, particle budgeting
and added weapon scenarios and ran the final checks. Interactive visual review
of settling, traversal and transitions remains with the user.

The independent review of the repeated-death correction found one **P2** issue
in `physics.zig`: processing lethal contacts before animation advancement could
capture the previous pose at the newly stepped body position. The animation
update now precedes contact processing, preserving the original death snapshot
order while consuming all transient events each step. The implementing agent
verified the correction with the failing/passing turn-and-projectile regression.

After that correction, **132/132 tests**, the build and the five-second Tower
Keep smoke passed without warnings or errors. The first twelve-kill performance
run allocated no new particle or giblet/ragdoll bodies during any event, with
average death-capture frames around 16.7 ms. One frame reached **40.829 ms**, so
that run failed the new 33.333 ms gate; the prolonged baseline slowdown did not
recur. A second twelve-kill run after the pose-order correction also allocated
zero particle or giblet/ragdoll bodies, with averages of 16.673–16.686 ms. Its
worst frame was **38.915 ms** on death 11 (32.633 ms in physics, including contact
processing), and it also failed the unchanged 33.333 ms gate. A smaller burst-time
hitch remains; performance validation is not fully green. The remaining spike
was mainly physics/contact work, not pool growth. Neither run is a frame-time
guarantee or a deterministic comparison against the baseline.

User observation exposed an additional limitation of the Tower Keep capture:
the second victim respawns with its blood emission point inside the previous
gravestone. A temporary diagnostic recorded 216 droplets contacting surfaces
for each of two deaths; on death two, 215 contacted a dynamic object within
about 17 ms. A separate point-in-shape check identified the overlapping object
as `gravestones/Untitled.png`. Ragdolls are already excluded from droplet
collisions. The missing airborne spray is rapid conversion into stains, not a
reduced blood preset. These diagnostics were removed after capture. Obstructed
respawns remain unchanged, and this capture alone does not establish performance
under sustained airborne blood load.

The existing `air-ragdoll` scenario was then run for six deaths to supplement
that capture with unobstructed airborne bursts. It completed without particle
or giblet/ragdoll body allocations or texture migrations. Average captured frame
times were 16.678–16.683 ms; the maximum was 17.843 ms. This isolated scene has
less collision geometry than Tower Keep, so the remaining Tower Keep frame-time
failure and obstructed-respawn issue still apply.

The four existing projectile, hitscan, corpse-gibbing and corpse-removal runtime
scenarios each completed two events after the contact/pool fix, before the final
pose-order correction. Their allocation/migration checks passed. The final
repeated-missile run and dedicated fatal-contact regression cover that correction.

The scratch-storage review found one **P2** issue in `projectile.zig`: comparing
body count against hash-map bucket capacity could miss allocations triggered by
the map's lower load threshold. The counter now compares capacities before and
after reservation. The focused regression failed with the original counter and
was added to the dedicated test suite. No other actionable findings were reported
for this refactor.

Final scratch-refactor validation: **134/134 tests**, the build and the five-second
Tower Keep smoke passed without warnings or errors. Two events each of
`ragdoll-projectile`, `ragdoll-hitscan`, `ragdoll-gib`, `ragdoll-remove` and
`ground-explosion` passed, as did six `air-ragdoll` deaths. Twelve
`tower-keep-ragdolls` deaths completed, but the frame-time gate still failed:
the last, gibbing death peaked at **45.431 ms**, above 33.333 ms. All these captures
reported zero scratch-storage growth and zero new particle/giblet bodies.
The six open-air deaths peaked at 19.200 ms. These are unseeded individual runs;
they establish storage reuse, not resolution of the remaining frame-time issue.

For review:

1. Kill a player with modest overkill while standing, running, jumping and aiming
   in either direction. Check continuity into the ragdoll and how it settles.
2. Hit different corpse limbs with arrows, hitscan and explosions. Check shared
   damage, whole-body removal, and gibbing without a pose reset.
3. Walk over bodies on floors, slopes, stairs and rubble. Check that connected
   limbs remain attached under contact and push forces.
4. Leave an arrow embedded while destroying, gibbing or recycling a corpse.
   A surviving part should retain it; a removed part should release it harmlessly.
5. Accumulate more than eight corpses, respawn, reload artwork and change levels.
   Check whole-corpse retirement and clean replacement.
6. On Tower Keep, fire missiles at the other player each time they respawn.
   Check frame pacing and that bodies settling, sliding or being pushed produce
   no blood. Destroying or gibbing a corpse should still produce blood.
