# Repeated-death collision performance

Status: accepted by the user with explicit commit authorization. Independent
review, corrections and validation are complete, including the patch-review
reminder beside the Box2D dependency pin.

## Cause and change

The remaining Tower Keep hitch occurs during physics after blood bursts, even
when particle, giblet and explosion scratch pools do not grow. A diagnostic
capture isolated Box2D's broad-phase pair search: one 18.076 ms world step spent
11.234 ms finding candidate collisions. The pinned Box2D revision queries its
spatial trees using every category bit, then rejects droplet-versus-droplet pairs
inside its callback. Dense clouds therefore visit many pairs that cannot collide.

`build.zig` now generates a patched copy of that dependency's `broad_phase.c` in
the Zig build cache. Its three tree queries use the querying shape's collision
mask. Shapes with a positive collision group retain the original all-category
query because matching positive groups override masks. The existing callback
still applies both masks, group rules, body/joint exclusions and custom filters.
This covers dynamic, kinematic and static query trees without changing the
simulation step, particle emissions, colliders or collision rules.

Mask pruning alone passed one twelve-death capture but another reached 33.894 ms,
just over the unchanged 33.333 ms gate. The latter recorded 18.844 ms in Box2D,
of which only 4.282 ms was pair search. Legitimate collision work was still
running in an unoptimized native library, leaving little frame-time headroom.
Debug game builds now compile Box2D alone with `ReleaseSafe` optimization and
`-UNDEBUG` to retain its assertions. Game code remains Debug; other game build
modes retain their matching Box2D mode by default. Use
`zig build -Dbox2d-optimize=Debug` when stepping through unoptimized Box2D source.
This is a build-time choice, independent of performance instrumentation.

The dependency remains pinned to `8c661469c9507d3ad6fbd2fea3f1aa71669c2fe3` in
`build.zig.zon`. The original dependency cache and upstream license header remain
untouched. The build uses Zig's existing generated-file and C-compilation steps;
no external patch command or duplicate physics implementation is introduced.
It checks that the expected shape lookup and three query sites exist before
patching, and fails explicitly if they change. Reassess/remove this local patch
when updating Box2D rather than assuming a newer implementation needs it.

The existing player-death profiler now records `box2d_us` and
`collision_pairs_us`. These timings accumulate across catch-up steps and appear
in capture totals and worst-frame records. Pair-search time is a subset of the
Box2D time, which is itself included in `physics_us`; do not add them together.
The instrumentation is compiled out of ordinary builds.

## Validation and review

Dedicated tests exercise the actual linked Box2D implementation:

- All three body trees and both creation orders, with mutual masks, one-sided
  exclusions, positive group overrides, negative group exclusions, differing
  groups and high category bits.
- Runtime group, category and mask changes, plus pooled-body disable/enable cycles.
- A dense 512-droplet cloud with no self collisions, followed by terrain contact
  for every individual droplet, with no duplicate contact events.

The performance gate remains 33.333 ms for repeated Tower Keep deaths. Capture
checks still reject new particle/giblet bodies and explosion scratch growth.
Run the existing scripts:

```sh
bash scripts/character_animation_check.sh -- --level levels/tower_keep.json
bash scripts/explosion_perf_test.sh 12 tower-keep-ragdolls
bash scripts/explosion_perf_test.sh 6 air-ragdoll
```

The controlled 512-droplet test measured the first open-air physics step at
31.899 ms before mask pruning and 0.432 ms afterward. Both used unoptimized
Box2D, the same scene and the same passing collision assertions; the comparison
isolates the search change from the later native-library optimization. Temporary
timing prints were removed after measurement.

Twelve Tower Keep deaths with the final optimized native library passed the
unchanged gate: maximum 29.880 ms, with average physics time ranging from
0.417 to 1.056 ms across captures. No particle/giblet bodies or explosion scratch
growth occurred during any event. The earlier 33.894 ms failed capture with
unoptimized Box2D is retained as part of the evidence. These real gameplay runs
use random outcomes and are not deterministic timing comparisons or guarantees
of 60 FPS on every frame.

Independent review found no actionable code issues in the mask patch, native
build adjustment, profiler or tests. The reviewer verified that the optimized
archive still references native assertions. Its optional suggestion to test
runtime mask/category changes was implemented alongside the existing group and
pooling cases. Optimization does not guarantee bit-identical floating-point
trajectories across build modes; collision settings and acceptance rules remain
the same.

Final default-build validation passed all **137 tests**, including the added
runtime mask/category cases, the build, and the five-second Tower Keep smoke
sentinel with no warnings or errors. The native Debug override was also built
successfully. Six `air-ragdoll` events passed the allocation/migration checks,
with a 26.285 ms maximum captured death frame. This supplements Tower Keep with
unobstructed airborne blood; it does not resolve the gravestone overlap described
below. Two events each of `ragdoll-gib`, `ragdoll-remove` and `ground-explosion`
also passed, with no new particle/giblet bodies, explosion scratch growth or
unexpected texture migrations. All final runtime logs are free of warnings and
errors. Logs and the controlled before/after cloud measurement are kept in
`agent-temp-files/ragdoll-frame-polish/` during this phase.

For user testing, repeatedly fire missiles at the other player as they respawn
on Tower Keep, including shots that gib existing corpses. Check frame pacing,
blood spray/stains, and collisions when walking on corpses or rubble. The
previously observed respawn overlap with gravestones is a separate unresolved
behavior; this phase does not change spawn placement.
