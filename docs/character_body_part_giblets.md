# Body-part giblets — phase 6B

Status: complete and accepted by the user; independent review, corrections and
validation are complete. Connected ragdolls are the next phase, 6C.

## Behavior

A gibbing death captures the final procedural physics pose before player death
resets animation. Every anatomical binding is considered once: head, torso,
pelvis and both arms, hands, legs and feet. The carried hand uses the grip artwork
when appropriate. Skin and fixed-color layers remain one physical part.

Each binding has an independent `survival_weight` probability in the character
art manifest. Zero consumes it, one always preserves it. There is no compulsory
survivor or duplicate anatomy. The initial probabilities range from 0.35 for the
pelvis to 0.8 for the head. Consumed parts emit blood at their original positions;
only survivors activate solid bodies. The -40 HP threshold is unchanged.

Survivors retain world position, orientation, facing, player tint and depth
shading. They inherit current physics velocity, including an already-applied
fatal blast impulse, plus motion of the limb relative to the player. Shortest
angle differences carry angular motion without wrapping through a full turn.
Discrete facing/artwork changes do not produce artificial limb velocities.
A small random scatter velocity and spin separate the parts.

Detached parts keep the existing 1 HP, contact blood, particle destruction and
pool-return behavior. Players can step on and anchor feet to their solid shapes.
Respawning and changing player color do not recolor or remove existing parts.
Spray painting skips the borrowed character layers, preventing edits to a piece
from changing the shared artwork on living players. Per-piece paint decals are
not implemented in this phase.
Non-gibbing deaths retain their current behavior until phase 6C.

Severed ends draw a tinted grayscale blood overlay authored in each part's
`gib_blood` SVG group. It covers the neck, torso/pelvis attachment areas, both ends
of limb segments, wrists and ankles, including the gripping-hand variant. Larger
parts also have two surface stains away from joints; each hand/foot has one. Only giblet
activation sets the visual's `severed` flag; living parts keep it false. All three
layers use the same placement, but only skin receives player tint. No shared
surface is edited and no per-death texture is created.

The `blood` preset's `color` in `particles.json` drives the overlays, droplets and
surface stains. Red (`138, 3, 3`) remains the default. Edit those RGB channels and
restart to apply a new color. The renderer uses the existing `blood.currentColor`
lookup. Particle stains inherit the emitted particle color when their optional
color is omitted or null; explicit stain-color overrides remain supported. The
blood preset omits that override so there is only one color to edit. § then R
still reloads the artwork; it does not reload particle presets.

Embedded arrows detach when a part is destroyed or recycled. They retain their
position and momentum, fall under their existing gravity, and stick again on
contact with solid scenery or objects. Released arrows pass through players
without damage; their penetration sensors, damage and explosion are disabled.
The projectile component reuses its flight and sticking behavior and tracks the
target's existing pool activation ID, so reusing a physical body cannot bring an
old arrow back. This also applies to pooled rubble and ordinary targets that are
removed. Level cleanup still removes the arrows.

## Components and tuning

- `data.zig` loads collider metadata and binding probabilities through the existing
  artwork decoder. The obsolete runtime template JSON loader has been removed;
  historical giblet files remain available to existing offline tools.
- `character_art.zig` owns placement and rendering for both living and detached
  parts, plus the `bodyParts` appearance map keyed by physical body ID.
  `entity.zig` dispatches rendering with its existing interpolated transform and
  removes the component when the entity is destroyed. `gibbing.zig` registers
  appearances during pool preparation and updates them without allocating on
  activation. Textures are borrowed, never copied or individually recolored.
- `gibbing.zig` owns part snapshots, weighted selection and pools. The snapshot
  carries identity, appearance, pose and motion so a future ragdoll can provide
  the same input from its physical bodies.
- `damage.zig`, `destruction.zig` and `pool.zig` retain damage and lifecycle
  ownership. Removing pools also cancels their queued releases. `entity.addSprite`
  now grows its existing array without freeing the original before allocation
  succeeds.

In `character_art/curb_rat_v1/manifest.json`, each part's `physics` specifies a box
center and half-extents in source pixels, density and friction. These use the same
pivot, scale and facing mirror as the artwork. Boxes approximate the silhouette;
transparent SVG canvas borders do not enlarge colliders. Binding
`survival_weight` values tune selection independently for left and right parts.
These physical properties are separate from the animation curves.

The optional per-part `gib_blood` path names the exported overlay. The existing
exporter generates it from the editable source group, and the existing art
loader validates its path and matching canvas and owns its texture. Failed
replacement frees candidate layers while retaining the active pack. Omitted or
null overlays keep older packs valid. To tune the patches and compare both
facings, edit the source SVGs and run:

```sh
python3 scripts/export_character_art.py --preview agent-temp-files/giblet-blood-color/preview
```

Open that folder's `giblets.svg` for enlarged clean/cyan/mirrored-pink comparisons
using the configured blood color. `giblets_green.svg` and `giblets_blue.svg` show
alternate tints without editing configuration.
The sheet uses the source vectors; final readability at game scale needs playtesting.

Pools are prepared before combat for each art variant and facing, with at least
four bodies each and enough slots for two complete deaths per facing. Exhaustion
recycles the oldest slot through the existing pool activation identities. The
shared blood pool is prepared for two composite death bursts, including all
potentially consumed parts. This is a bounded preparation budget; arbitrary
numbers of simultaneous particle effects may still require more capacity.

Press §, then R to reload the manifest. Successful reload builds the complete
replacement pools before removing old detached bodies and replacing artwork.
A failed load/preparation retains the old assets and pools. Level cleanup removes
all detached bodies before resetting level assets.

## Validation and manual review

Use the existing runners:

```sh
bash scripts/character_animation_check.sh
bash scripts/explosion_perf_test.sh 2 air-death ground-death tower-keep-player-kill
```

Regression coverage includes both facings/colors and running phases, paired
layers and hand variants, deterministic weighted selection, all/none survival,
invalid metadata, relative limb motion, collider mirroring, signed-angle wrap,
activation identities, damage/reset, partial pool preparation failure and cleanup
with outstanding releases. CPU pool tests use borrowed fixture sprite IDs;
rendering and blood effects are exercised in the game runs.

For user testing:

1. Gib a wounded character while running and jumping, facing either direction.
   Check that the visible body separates into its actual parts without a pose
   reset, and that sunglasses, claws and clothing retain their colors. Check that
   severed ends and surfaces are bloody, that blood keeps its configured color
   regardless of player color, and that
   living and respawned characters remain clean.
2. Walk over surviving pieces and shoot them. Check blood bursts, collision and
   foot support, then repeat deaths to exercise pool recycling. Embed an arrow
   in a piece, destroy it, and check that the arrow falls and sticks to the floor
   without hurting players it crosses. Repeat deaths: the old arrow must not
   reappear on a replacement piece. Also check recycling a piece while its arrow
   is present, and destroying the object an already released arrow sticks into.
3. Reload artwork and change levels with pieces present. Check that they clear
   cleanly, and repeat a death afterward. Check that ordinary respawning leaves
   existing pieces intact.
4. Tune binding survival probabilities and collider boxes if the visual balance
   or support feel needs adjustment. Use the existing collider debug overlay.

## Independent review and corrections

The reviewer inspected the entire phase and identified three P2 findings:

| Finding | Correction |
| --- | --- |
| Spray painting a giblet could mutate the living pack's shared sprite surface; its paint coordinates also assumed a centered sprite. | The existing spray path skips character-part visuals. A CPU test calls the actual spray function against a detached part and checks that the shared surface remains unchanged. |
| The previous physics sample reused the current aim direction, losing arm swing when aim changed. | Animation retains the previous direction for previous-physics sampling. A test changes aim with a stationary root and checks the real sampled pose and inherited velocity. |
| Empty pools were mistaken for startup, so a successful reload after initial artwork failure could not recover gibbing. | Reload now checks subsystem initialization and prepares missing pools once blood is available. Tests cover that recovery and replacement of active bodies. |

During implementation, a repeated-death benchmark exposed extra blood-particle
allocations from consumed parts. Composite burst preparation now uses the
existing particle pool and the emitter's shared count calculation. Cleanup
inspection also found that removing queued releases could mutate the release
iteration; the queue now removes each item before processing it, covered by an
invalid-body/remaining-releases regression.

The reviewer reported no additional material architecture or style issues.

The user's playtest found that an embedded arrow reappeared when a destroyed
giblet body was reused. Disabling a pooled body preserves its Box2D weld joints;
the projectile component previously discarded the joint ID after embedding.
The initial fix retained the attachment and removed the arrow and weld when the
target was disabled, removed or acquired a different pool activation. The later
release iteration keeps the arrow and removes only the weld. Cleanup runs after
firing inputs within each fixed physics step, before the Box2D solver, and after
projectile contact processing. Four regression tests create real contact-driven
welds and cover destruction followed by body reuse, live recycling, immediate
release/reacquisition, ordinary target removal, and target destruction by actual
fixed-step firing.

The independent arrow-correction review found one P2 ordering issue in
`main.zig`: checking attachments before `physics.step()` was too early, because
firing inside that step can recycle targets. The check now lives in
`physics.zig` immediately before Box2D runs. The recycling test uses the real
physics step and verifies that the replacement position is undisturbed; an
additional firing test checks cleanup after the shot destroys its target. The
reviewer found no other actionable issues in the attachment correction.

Validation after the arrow correction: **117/117 tests passed**, the game
built, and the five-second smoke sentinel and artwork capture completed without
warnings/errors/panics. Before this correction, all five deaths across the
repeated airborne/ground benchmarks and Tower Keep passed, with no particle or
giblet body creation during either trigger or death
capture. Tower Keep peaked at 17.269 ms, below its 25 ms gate. The terrain-editing
ground scenario peaked at 36.126 ms; it has no frame-time gate. These are sampled
runs, not a performance guarantee. Logs are in `artifacts/character_animation/`
and `artifacts/explosion_perf/`.

Visual feel, manual aiming/running death comparisons, spray behavior in the full
game and controller-driven reload/level changes remain for the user's playtest.

Initial severed-end polish validation: **118/118 tests passed**, all 30 exported layers
match their sources, and build/five-second smoke passed without warnings/errors.
SDL decoding checks matching canvases and opaque blood pixels with dominant red;
metadata checks cover unsafe/duplicate paths, incorrect types and omitted/null
overlays. Pool activation/reuse checks confirm the severed flag. The 20 original
skin/fixed exports are unchanged. The enlarged comparison sheet was visually
inspected, as was the clean living character in the game smoke capture.
Two airborne deaths passed the existing benchmark, with zero particle/giblet
body creations or texture migrations during trigger/capture. The maximum sampled
death frame was 20.949 ms. Interactive reload and the blood's readability during
normal gameplay still need the user's review.

The independent review of that initial polish found no actionable findings. It covered
the loader, partial-load cleanup, transactional replacement, shared texture
ownership, untinted/mirrored rendering, pooled activation, exporter and tests.
Missing/mismatched overlay failures during an interactive reload were checked
by code inspection, not an automated GPU reload test.

Configurable-color/surface-stain iteration: **119/119 tests passed**, including
JSON omitted/null/explicit stain-color cases, inherited green/blue tints, an
explicit red override, the configured blood lookup and neutral SDL-decoded masks.
All 30 exports match their sources; build and five-second smoke passed cleanly.
Default red, green and blue offline comparison sheets were inspected. Two more
airborne death benchmark events completed without warnings/errors or new
particle/giblet bodies/texture migrations in trigger/capture; the maximum sampled
death frame was 22.707 ms. Color changes are startup configuration, not an
interactive reload feature. Non-red blood in the full game remains a manual
visual check; the offline previews and CPU tests cover the alternate tints.
The independent review of this iteration found no actionable findings after
checking preset/renderer reuse, initialization, explicit overrides, RGB
independence, export integrity and repository skills. Interactive artwork reload
and stain readability at gameplay scale remain for the user's playtest.

Arrow release iteration: **121/121 tests passed**, all 30 export layers match,
and the game build and five-second smoke/capture completed without warnings,
errors or panics. The four original attachment regressions now require release
instead of deletion. Additional contact-driven coverage checks sleeping arrows
waking, falling through both owner and opponent without health loss (including
penetrating shots), disabled penetration sensors, ground reattachment, repeated
release/reattachment and cleanup when the arrow entity was already removed.
Ordinary target removal also checks preserved position, rotation and velocity.
Logs are in `agent-temp-files/arrow-release/` and `artifacts/character_animation/`.
Interactive arrow motion and level changes remain for the user's playtest.
The independent release review found no actionable findings. It checked the
scoped projectile changes, dedicated tests and behavior notes against the
iteration baseline, including physics ordering, collision masks, weapon sensors,
damage, pool activation, entity removal, level cleanup and repository skills.
No reviewer-requested corrections were needed.

Character-part ownership refactor: `Entity.characterPart` is removed. The
character-art component owns body appearances; entity rendering supplies its
existing interpolated transform, and entity cleanup unregisters the body.
Pool preparation registers each appearance once, activation updates it without
allocating, and sprite painting consults component membership to preserve shared
textures. Artwork installation retires only the previous assets so it preserves
the replacement pool's already registered appearances; full component cleanup
frees the map as well.

Validation: **122/122 tests passed**, all 30 export layers match, and build and
five-second smoke/capture passed without warnings/errors/panics. Lifecycle tests
cover updated tint on body reuse, rollback after partial pool preparation,
individual and bulk entity removal, teardown with queued releases, and artwork
installation after replacement bodies are prepared. The existing spray test
still verifies shared surface preservation. Two airborne death events passed
without new particle/giblet bodies or texture migrations during trigger/capture;
the maximum sampled death frame was 26.378 ms (this scenario has no frame-time
gate). Logs are in `agent-temp-files/character-part-component/`. Interactive
artwork reload, level switching and appearance comparisons remain for playtesting.
The independent ownership review found no actionable findings. It inspected
registration rollback, pool reuse, artwork installation, rendering dispatch,
entity/level cleanup and the repository skills. No reviewer-requested corrections
were needed; the install/cleanup separation was part of the implementation.

The final readability pass applies the agreed conditional style to this phase's
code and tests: simple guards stay compact, compound guards use blocks, and
meaningful local names shorten long expressions. All 122 tests, asset checks,
build and five-second smoke/capture passed afterward. No additional independent
review was run for this mechanical iteration, as requested by the user. The user
then accepted the phase and authorized its commit.
