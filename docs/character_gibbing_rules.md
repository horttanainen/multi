# Shared gibbing rules — phase 6A

Status: accepted by the user; commit authorized. Independent review, corrections
and validation are complete. Body-part selection and ragdolls are the following
phases; this change uses the existing death visuals and giblets.

## Rule and configuration

`damage_rules.json` sets `gibHealthThreshold` to **-40**. The game loads it at
startup through `data.zig`; restart after editing it. It must be finite and
negative. Invalid configuration is logged and fails startup. `damage.configure`
validates before replacing its active settings. An omitted field uses -40;
unknown fields are rejected.

After each accepted damage event:

| Remaining health | Outcome |
| --- | --- |
| Above 0 | Alive |
| Above -40, at or below 0 | Ordinary death |
| At or below -40 | Gibbing death |

For a player with 10 HP, 49 damage produces an ordinary death and 50 damage gibs.
For a player with 100 HP, a single 100-damage hit kills without gibbing; a
140-damage hit reaches the gibbing threshold. The corpse's future 100 HP pool will
use this same calculation.

`damage.applyHealth` owns subtraction, signed remaining health and classification.
The player chooses its existing death/gibbing effect from that result. Physical
objects call the same helper, retain the signed result, and still use their
registered destruction effect and remove/pool lifecycle. They do not acquire
character gibbing behavior. Pool reset restores maximum health and clears pending
destruction. Non-finite inputs or overflow are logged and ignored; nonpositive
damage is ignored. Dead players and objects pending destruction ignore more hits.

The new profile extends the existing value-profile loader in `data.zig`, also
used for movement profiles. It uses the shared bounded filesystem reader and
releases decoding allocations before returning value-only configuration. No
second JSON or filesystem implementation is introduced.

## Attack ordering

This phase changes the health threshold, not the established weapon ordering:

- Each pellet is a separate hit. The first fatal hit decides death; later hits
  do not add overkill to an already dead player. With 15 damage per pellet, the
  current shotgun will therefore ordinarily kill without gibbing.
- Explosive projectiles retain their existing direct-hit budget: when explosion
  damage is enabled, the applied direct damage is subtracted from the explosion's
  player damage. A fatal direct hit still ends player damage processing before
  the explosion remainder. No attack-wide accumulation is added in this phase.
- An explosion still evaluates each living player once. Grouping health damage
  across several ragdoll bodies will be implemented when those bodies exist.

The explosion benchmark and automatic debug explosion read the configured
threshold when preparing a living victim. If their damage cannot reach it with
the setup's one-HP safety margin, they report that before damaging the victim.

## Validation and user review

Use `bash scripts/character_animation_check.sh` for the existing asset checks,
regressions, build and five-second game smoke run. The suite covers threshold
boundaries, accumulated hits, configurable thresholds and invalid replacements,
invalid damage, physical-object destruction/reset, and real ordinary player death
through health -39 with one score update and unchanged respawn scheduling.

The existing death benchmarks exercise real gibbing, blood and pool lifecycles:

```sh
bash scripts/explosion_perf_test.sh 1 ground-death tower-keep-player-kill
```

Validation completed: **105/105 tests passed**, build passed, and the five-second
smoke run completed with no warnings/errors/panics. Both death benchmarks passed
and logged `gibbed=true`; neither allocated particle or giblet bodies during the
death capture. Tower Keep's maximum death frame was 19.042 ms, passing its 25 ms
gate. The ground-death terrain-edit scenario peaked at 31.183 ms; that scenario
has no frame-time gate. These are individual runs, not a performance guarantee.

The independent review covered all phase 6A changes and found one test setup
issue: the configuration test relied on the wrapper creating its output
directory. The test now creates that directory itself. A direct
`zig build test-character-animation --summary new` run, starting without
`artifacts/character_animation`, passed all 105 tests. The reviewer reported no
runtime correctness or architecture findings in this phase.

For manual review, use the existing weapons and compare an ordinary full-health
kill with a strong hit on a wounded player. Check kill scoring and respawn, and
that ordinary damaged objects still break normally. The currently displayed
giblets are the legacy templates; actual character parts arrive in 6B. Non-gibbing
deaths still use the existing gravestone behavior until ragdolls arrive in 6C.
