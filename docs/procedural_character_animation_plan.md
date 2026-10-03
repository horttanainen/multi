# Procedural Character Animation Plan

Status: Phase one accepted by the user on 2026-09-12, including the compact Bezier
control tracks; full independent review and corrections completed. The exact
dense run JSON remains as a regression reference.
Phase two is accepted by the user, including the profile rename to `run.json`;
independent review, corrections and validation are complete.
Phase 3A is accepted by the user: jumping, falling, landing and the shared crouch
pose (held with Down while grounded). Independent review and validation passed.
The standalone alien blaster and procedural carried grip are accepted by the
user; independent review and validation passed. See
[character_animation_blaster.md](character_animation_blaster.md).
The aiming phase is accepted by the user: arm IK points the
standalone blaster, Towerfall aim consumes directional movement input, and
drawing/guide/shots share weapon geometry. Airborne aiming retains the horizontal
input from before the aim press until release or landing, preserving the jump's
trajectory. Existing momentum and physics continue.
See [character_animation_aiming.md](character_animation_aiming.md) for the data,
validation and acceptance checks. Grappling and rope animation are deferred.
Wall bracing, pushing, sliding and jump push-off are accepted by the user,
including the leg-extension correction; see
[character_animation_walls.md](character_animation_walls.md). The one-handed,
outward-facing wall-slide revision is accepted, including the near-straight leg
and downward-toe adjustment; independent review and validation are complete. See
[character_animation_wall_slide.md](character_animation_wall_slide.md).
Running polish is accepted by the user: near-under-hip touchdown,
rearward push-off, high compact heel recovery and forward knee motion, retaining
separate stride and intensity tuning. See
[character_animation_running_polish.md](character_animation_running_polish.md).
Configurable directional input is accepted by the user: independent
movement interpretation and aiming modes in the existing profiles, plus debug
menu comparisons. Independent review, correction, and validation are complete.
See [directional_input.md](directional_input.md).
Kneeling and landing polish is accepted by the user, including aiming from the
kneeling stance. Independent review and validation are complete: stationary Down
kneels with one knee grounded and the torso forward; horizontal movement uses
regular running; impact absorption uses a separate landing squat.
See [character_animation_kneeling.md](character_animation_kneeling.md).
Static slope and step adaptation is accepted by the user on 2026-09-24, including
continuous slope running and automatic stair climbing up to 0.5 m through the
existing movement controller. Independent review, corrections, validation and
user testing are complete.
See [character_animation_terrain.md](character_animation_terrain.md) for the
terrain profile, runtime constraints and test scene. Moving/destructible rubble
is accepted by the user, including generic solid support for giblets, stepping
and blocking against the same supporting body's upright, and correct blood
colors on SVG objects. Independent review and validation are complete; the user
has authorized the phase commit.
See [character_animation_rubble.md](character_animation_rubble.md).
Body artwork is accepted ahead of Blender authoring. The approved design is:
a shirtless alien skater, 1990s sunglasses and white/grey skin for player-color
tinting. The user selected Curb Rat (A). Its current side profile has a subtle
pointed nose with one visible vertical nostril slit, muscles on a skinny frame,
and bare three-toed alien feet with sharp nails. Appearance, segment preparation
and runtime integration are accepted, including the head at 75% of its initial
integration size and removal of the temporary GPU-failure test hook. The segments
use the existing solved poses, asset loading, sprite renderer and debug menu.
Independent review, corrections and validation are complete: 101 tests and the
build/smoke check passed. The user has authorized the artwork commit. See the
[runtime artwork notes](character_animation_artwork.md), the
[art pack](../character_art/curb_rat_v1/README.md), and the
[first appearance study](../character_art/concepts/alien_skater_v1/README.md).
The user has requested another phase for giblets made from the actual body parts,
non-gibbing deaths becoming ragdolls, and revised shared gibbing rules. This is
planned in section 6 below. The agreed threshold is -40 HP, with the same weighted
selection of surviving anatomical parts for players and ragdolls. Phase 6A was
completed in `aa2c27b`: configurable -40 HP threshold and shared signed health
outcomes. Weighted body-part giblets (6B) are complete and accepted by the user,
with independent review, corrections and validation complete; see
[body-part giblet notes](character_body_part_giblets.md). Ragdolls (6C) are accepted
by the user, including the performance and explosion-storage iterations below;
independent review and corrections are complete, and the user has explicitly
authorized the commit. See [ragdoll notes](character_ragdolls.md).
User testing exposed repeated-missile slowdowns. The authorized correction
removes movement/impact blood from intact corpses, consumes transient contacts
after every fixed step, returns droplets immediately to the existing pool, and
adds a Tower Keep repeated-kill benchmark. Independent review found a death-pose
ordering issue, now fixed and covered by a regression. All 132 tests and the
build/smoke checks pass. Twelve repeated kills allocate no new particle or corpse
bodies, but a remaining 38.915 ms burst-time frame exceeds the new 33.333 ms gate.
The prolonged baseline slowdown did not recur; performance validation remains
partially failing.
The user also authorized replacing fixed explosion query/damage arrays with
reusable scratch collections. That refactor is implemented with setup reservation,
world-size-based growth, body/health-owner maps and dedicated regression coverage;
independent review found and corrected a missed hash-map growth counter case.
All 134 tests and build/smoke checks pass. Runtime captures report zero scratch
growth, including twelve Tower Keep deaths, but the last gibbing death reached
45.431 ms and still failed the 33.333 ms frame-time gate. The remaining spike and
obstructed respawn are documented for follow-up; acceptance does not mean that
the performance gate passed.
The user authorized a performance-polish follow-up. It targets the measured
Box2D collision-pair search cost during dense blood bursts, preserving collision
rules and particle amounts, and optimizes Box2D in Debug game builds while
retaining native assertions. Independent review is complete; 137 tests and
build/smoke passed. Twelve Tower Keep deaths passed the 33.333 ms gate with a
29.880 ms maximum. See [performance-polish notes](ragdoll_performance_polish.md)
for the earlier failed capture and final validation. The user accepted this
follow-up and the patch-review reminder beside the Box2D pin, and explicitly
authorized their commit.
See [gibbing rule implementation](character_gibbing_rules.md).
The accepted phase's scope and test instructions are in
[character_animation_phase3a.md](character_animation_phase3a.md).
The accepted running implementation is documented in
[character_animation_phase2.md](character_animation_phase2.md).
Run instructions, the schema specification, and the acceptance checklist are in
[character_animation_phase1.md](character_animation_phase1.md).

## Phase review and commit workflow

Follow [phased-collaboration](../skills/phased-collaboration/SKILL.md) for
commit-sized phase plans and user acceptance, and
[review-before-handoff](../skills/review-before-handoff/SKILL.md) for the independent
review and correction pass. Complete the relevant automated checks and build/smoke
test, then present the uncommitted changes with review findings, corrections,
validation results, and instructions for running and reviewing them. The user
reviews and tests the phase, and requested adjustments precede acceptance.

Do not commit until the user explicitly accepts the changes. After acceptance,
commit only the accepted work, then present the next phase's plan and obtain the
user's go-ahead before implementing it. Acceptance of a plan or the initial run
study is not acceptance of an implementation. Preserve unrelated working-tree
changes throughout.

## Accepted direction

Build a procedural character, initially rendered as lines in the player's color. Establish a convincing run and responsive movement before replacing the lines with artwork.

Blender is the chosen future authoring tool. Defer the Blender template, exporter, and authoring workflow until the game-side setup works. Initial animation profiles will be created and tuned by the coding agent; user animation editing is not a prerequisite for the first implementation.

Use versioned JSON assets from the beginning. Blender will eventually export the same runtime data that the first implementation loads. The game can be closed while editing in Blender.

This revises the earlier editor-first plan: a custom browser editor, a full in-game animation workspace, and a live editor connection are outside the initial scope. Keep only the diagnostics needed to develop and assess the procedural system.

## Ownership of movement and animation

The existing movement controller and Box2D character body continue to determine gameplay position, velocity, grounding, jumping, wall interaction, and collisions.

Animation consumes that state and produces a visual pose. Skeleton joints initially represent calculated positions and rotations, with fixed limb lengths; they are not separate dynamic Box2D bodies. Decorative pelvis bounce and a running cycle's brief visual flight do not change the controller's grounded state or trigger gameplay jumps.

Separate the following responsibilities:

- Authored motion describes preferred foot paths, body movement, arm motion, and contact timing.
- Locomotion planning chooses cadence, transitions, and reachable surface contacts.
- The pose solver applies bounded pelvis corrections and solves arms and legs.
- Rendering displays the resulting segments as colored lines, then later as artwork.

Keep limb identities stable. Horizontal aiming now requests a character turn
through the existing locomotion transition, as requested during aiming review.
Preserve valid world-space foot contacts and let residual travel opposite the
aim-facing direction play the stride backwards. Aim-driven turning changes the
visual pose; it does not change physical velocity.

## Game-side architecture

Start with a `character_animation.zig` component that owns rig/profile assets and runtime animation state keyed by player ID. Follow the existing component conventions: plain data structs, file-level functions, and IDs at component boundaries. Only introduce additional components when there is a distinct ownership responsibility.

Per-player state includes movement mode, stride phase, direction-transition state, each foot's stance/swing state, surface anchors, planned landing points, and previous/current pose inputs. None of this transient state belongs in the authored JSON.

Update stateful animation and contact planning once per fixed physics step, after current movement contacts are available. Use simulation time. Rendering uses the same interpolation timing as the character body; interpolated targets can be solved again for display to retain limb lengths. Surface queries and contact decisions remain on the fixed-step path.

Existing foundations to reuse include:

- `physics.zig`: the 60 Hz fixed-step loop.
- `movement.zig`: velocity access, grounded/wall-slide state, and supporting body/shape contact data.
- `box2d.zig`: ray and shape queries and body-local/world-space conversion.
- `debug.zig`: world-space diagnostic drawing.
- `time.zig`: simulation speed control. Correct single-step behavior still requires the relevant gameplay updates and clocks to advance together.

## JSON contract designed for later Blender export

The first implementation establishes a small supported format and validates it. It does not implement a general animation interchange format or arbitrary Blender constraints.

### Asset responsibilities

Use the following asset types, with stable IDs and explicit schema versions:

| Asset | Contents |
| --- | --- |
| Rig | Named joints/bones, hierarchy, reference offsets, lengths, bend conventions, limits, and named attachment points. |
| Motion clip | Named control tracks, reference cycle duration/speed, looping policy, contact intervals, and optional named phase cues. |
| Locomotion profile | Clip references, speed-to-cadence/stride relationships, transition settings, ground-query rules, and limits on procedural adjustments. |
| Action bundle | Named non-looping motion clips plus transition and impact-response settings. Reuses the motion clip schema. |
| Aiming profile | Rig reference, shoulder-to-hand aiming distance and raise/lower/shot-hold times. Runtime aim direction remains player input. |

The implemented locations are `character_rigs/`, `character_motions/`,
`character_locomotion/`, and `character_actions/`.

Separate rig proportions from the running clip so later artwork or a changed character size does not require silently changing the meaning of its animation data. Locomotion parameters must remain editable data even when they are not naturally represented as animation curves.

### Coordinates and units

- Use meters, seconds, and radians with explicit semantics in the format specification.
- Author in a canonical 2D character frame: positive X is forward and positive Y is up.
- The root frame corresponds to the neutral pelvis reference; its mapping to the gameplay body's position is an explicit rig offset.
- Animated pelvis offsets are measured from that reference. Foot control tracks use the root frame, so moving the pelvis does not implicitly move a planted foot target.
- Keep attachment-local, parent-local, and root-relative quantities clearly distinguished. Do not mix them under one ambiguous position field.
- Facing conversion and the game's Y-down coordinate conversion happen at a defined runtime boundary. Blender export performs its own explicit axis and scale conversion into this canonical format.
- Store references by stable names/IDs. Array order and names generated by Blender must not define limb identity.

### Curves and control targets

Store curves for meaningful controls: left/right foot target coordinates and orientation, pelvis offsets, torso angle, and free-arm motion. Bone rest data and any directly authored joint rotations have explicit bindings as well.

The first profiles must use the same serializable track representation that later exports will use. Do not make the initial run depend on a hidden collection of sine formulas that Blender-authored data cannot replace.

Use normalized clip phase from 0 to 1. For a looping run, one cycle means one foot's touchdown through its next touchdown, including the other foot's step. Store a reference duration and speed so the runtime can adapt cadence and stride without assuming the clip must play at its authored duration.

Support a deliberately small curve vocabulary:

- Constant/stepped segments for discrete control values.
- Linear interpolation.
- Cubic Bezier segments with explicit phase/value handles for smooth authored curves.

Define interpolation on the outgoing segment, loop boundaries, and endpoint behavior. Bezier evaluation must solve the handle-defined phase coordinate; phase is not automatically the curve's polynomial parameter. Validate monotonic time handles and finite values. This makes later curve conversion unambiguous.

A Blender exporter may instead evaluate supported controls into linear samples with a documented error tolerance when their source curves use modifiers or unsupported interpolation. Such samples represent preferred targets and control values; the runtime still adapts contacts and solves limbs. They do not bake terrain-specific final joint positions into the clip.

Keep source/editor metadata optional and separate from runtime-required data. When introducing Blender, seed its first project from the supported initial rig and motion JSON so the already-tuned animation does not need to be recreated by hand. Preserve that native Blender project as the editable source afterward. General-purpose import of arbitrary or unsupported animation formats is outside this bootstrap task.

### Contact timing and transitions

Represent planned stance as explicit per-foot phase intervals, with a defined half-open interval convention. Split an interval that crosses the loop boundary. This allows contact intent to be evaluated at any phase, including when starting playback halfway through a clip.
Non-looping clips held at phase 1 retain contacts whose intervals end at 1; this
supports sustained poses such as pushing against a wall.

Named touchdown/lift-off cues can support export and debugging, but one-time event delivery must not be the only way to determine whether a foot should be planted. Actual contact acquisition/release remains a runtime decision. Footstep effects should follow actual accepted contacts.

Keep authored contact intent separate from the character controller's grounded state and from the runtime's current foot anchor.

Store transition durations and response parameters explicitly. Speed changes, stops, direction reversals, jumps, and interrupted steps must have defined recovery behavior. Stopping movement must allow a raised foot to settle rather than freezing the gait mid-swing.

### Validation and loading

Validate schema versions, required controls, unique identifiers, reference resolution, hierarchy cycles, positive limb lengths, phase ordering, loop continuity where appropriate, finite curve values, valid contact intervals, and valid parameter ranges.

Asset errors should identify the file and offending field/control. Reload a complete validated asset set atomically; retain the previous working set if reload fails. Restart the selected test sequence when applying structural rig/profile changes so stale contact state does not affect comparisons.

## Procedural running and environment response

Use actual velocity relative to the supporting surface to select cadence and stride. Offset the leg cycles by half a stride initially. Author an asymmetric recovery path with heel lift, a passing pose, and a deliberate approach to touchdown.

For each swinging foot, predict the pelvis position at touchdown and choose a reachable landing point near the intended step. Begin with flat ground, then add a small bounded set of candidate surface queries. Reject excessive slopes, unreachable points, and obstructed placements. Ignore the player and irrelevant collision categories.

Fit the authored swing shape between the actual takeoff and planned landing points. Retain its intended recovery shape and timing while adding bounded terrain clearance. Avoid moving the target freely throughout the entire swing; define limited correction and commitment behavior.

During stance, retain a body-local surface anchor. Resolve it using the current supporting body's transform. Revalidate body/shape lifetime and changed collision geometry so moving or destroyed rubble cannot leave stale anchors. Release contacts for lift-off, jumps, invalid support, or excessive reach, then recover gracefully.

Solve legs and arms with analytic two-bone IK, stable bend directions, and reachable-distance limits. Apply bounded pelvis corrections before final limb solves. Blend desired motion before applying final contact constraints so transitions do not pull a planted foot off its surface.

Wall placements are requested by explicit movement/action modes, such as wall sliding. Mere proximity to a wall does not imply grabbing it. Weapon/grapple targets take priority over the corresponding free-arm swing.

Keep query counts bounded and avoid allocations in the per-frame/per-step animation path. Add complexity only when a visible failure justifies it.

## Revised delivery order

### 1. Rig, assets, and colored stick figure

Reviewable result: a JSON-driven stick figure attached to the actual player in
the game, plus fixed-speed playback of the accepted run for checking the rig and
curve evaluation. Include a neutral standing pose and a switch between the
existing sprites, stick figure, and a comparison overlay.

Implement this bounded set of work:

1. **Rig and motion contract.** Create versioned rig and motion assets, document
   their supported fields, and establish stable names, meters/seconds/radians,
   canonical coordinates, and the explicit pelvis-to-gameplay-body offset.
   Define bones, fixed lengths, bend directions, and future hand/weapon attachment
   points. Support the small curve vocabulary specified above. Locomotion
   configuration remains a separate asset responsibility when phase two adds it.
2. **Loading and validation.** Validate the supported hierarchy, controls, curve
   handles, phase/contact intervals, units, versions, and numerical ranges before
   accepting assets. Errors identify the file and field. Provide an explicit
   reload action that retains the previous valid assets when a replacement fails
   validation and resets animation state after a successful structural change.
3. **Pose evaluation and solving.** Add a `character_animation.zig` component with
   state keyed by player ID. Evaluate preferred controls, solve two-bone legs and
   arms with fixed lengths and stable bend directions, and handle unreachable
   targets predictably. Integrate player spawn/removal, fixed simulation updates,
   and rendering interpolation without adding cosmetic bones to Box2D.
4. **Visible game integration.** Draw the figure in each player's color, with
   distinct near/far limb shading, at the actual player location and scale. Keep
   leg facing independent of aim. Provide neutral-pose and reference-cycle
   diagnostic modes. Preserve the existing gameplay authority for movement,
   collisions, weapons, and rope behavior; action-specific skeletal posing is
   introduced in phase three.
5. **A concrete motion reference.** Convert the accepted run study's controls into
   the documented runtime motion format and adapt its reference frame to the rig.
   Use continuous curve evaluation at the reference cadence. The twelve review
   poses are comparison samples, not baked final-joint animation data. Reference
   materials are in `artifacts/animation_studies/run_v1/`; retain any data needed
   to reproduce the runtime asset in the reviewed changes.
6. **Minimal review controls.** Provide visual-mode selection, neutral/reference
   playback selection, reload, and an optional joints/targets/reach overlay.
   Reuse the existing simulation speed control for slow-motion review. Blender
   tooling, an animation editor, and coherent simulation single-step remain
   later work.

Phase one uses the run to verify the data-to-pose pipeline. Its fixed reference
cadence does not yet adapt to player speed or anchor feet to terrain. Phase two
owns that locomotion behavior, including stopping, reversals, and transition
tuning; phase three owns action and terrain adaptation.

Acceptance checks for this phase:

- Switch visual modes and inspect the figure at gameplay size and close up;
  player colors, proportions, root alignment, and both facing directions work.
- Play the reference cycle at normal speed and in slow motion; compare selected
  phases against the accepted study, allowing for the explicit rig scale/offset.
- Limb lengths remain fixed, bends stay stable, and unreachable diagnostic
  targets produce a bounded solution without invalid numbers.
- Reload an edited valid asset and observe the change; an invalid edit reports
  its cause and leaves the last valid asset set usable.
- Multiple players, death/respawn, and returning to the sprite view work without
  stale animation state or changes to movement/collision behavior.
- Focused checks cover IK invariants, curve evaluation, loop/contact boundaries,
  and malformed assets. Project formatting, build, and smoke test pass. Present
  results and any visual limitations to the user before committing.

### 2. Initial running profile and tuning

Create and tune a complete initial running profile in JSON: foot trajectories, contact intent, pelvis movement, torso lean, and arm motion. Integrate cadence/stride response and flat-ground foot planting.

Tune at normal gameplay size and in slow motion across slow/normal/fast running. Include starts, stops, reversals, and movement against a wall. The coding agent is responsible for producing a usable initial result before asking the user to tune animation.

Implementation boundary: retain the accepted run control tracks and introduce
`character_locomotion/run.json`. Consume actual fixed-step body displacement
and existing movement contacts. Plant on verified static, flat surfaces using
world-space toe anchors; defer body-local moving-support anchors, planned terrain
landings, and action-specific poses to phase three. Re-solve interpolated targets
for rendering, with stance constraints reapplied after interpolation.

### 3. Actions and terrain adaptation

Add jump, fall, landing, aiming/grappling, and wall-slide pose behavior. Add slope/step adaptation and then moving/destructible rubble, using the same control tracks and bounded corrections.

Validate transitions with the real movement controller. Keep gameplay collision behavior independent from cosmetic pose corrections.

Split this work into independently reviewed commits:

- **3A (accepted):** JSON-authored jump, fall and shared crouch/landing clips; movement-driven
  transitions, impact-scaled landing compression, foot release/reacquisition, and
  interruption/reset coverage. Extend `data.zig`, the existing character component,
  curve evaluator, IK, contact solver, diagnostics and validation script.
- **3B, carried weapon (accepted):** Standalone alien blaster, existing sprite grip
  and muzzle markers, and a grip transform driven by the solved animated hand.
- **3B, aiming (accepted):** Aim drives the gun and arm IK. Holding aim consumes
  directional input for aiming, without cancelling velocity or normal physics.
  In the air, retain pre-aim horizontal input until release or landing.
  Share muzzle placement between drawing, aim guide and release-to-fire shots.
- **3B, walls (accepted):** Anticipatory bracing, impact
  compression, sustained two-hand pushing, wall slides and wall-jump push-off.
  Reuse movement signals, surface probes, action curves, IK and shared weapon
  placement; aiming has priority over the weapon hand.
- **3B, wall-slide revision (accepted):** Raised support hand,
  outward-facing slide, one near-straight leg, one bent knee, downward toes and a ready blaster. Keep the gun in
  hand through push-off; extend the existing contact, facing and limb blending.
- **Knife artwork and wall poses (accepted):** Straight dagger
  in reverse grip, hidden tip and pooled slide debris at the blade contact.
  Ready it on approach and through wall-jump push-off; lean forward over a shared
  two-hand grip when pushing into the wall. Reuse character art, sparse action
  curves, ordinary arm IK, SVG export and particles; retain physical movement
  and gun-arm aiming priority. See
  [the wall-slide follow-up](character_animation_wall_slide.md#knife-artwork-follow-up--accepted).
- **3B, deferred:** Grappling and rope animation, with explicit control priorities.
- **Running polish (accepted):** Reshape the sparse run curves using the existing
  exporter, preserve the original regression assets, and verify foot contact,
  heel recovery and independent width/lift tuning at slow/reference/game speeds.
  Independent review and validation are complete.
- **3C, static terrain (accepted):** Finite static surface probes,
  foot height/tilt, step clearance, pelvis fitting and existing toe/knee
  constraints, with regression coverage and a dedicated terrain scene. The current
  correction adds grounded slope travel and collision-checked stair climbing up
  to the movement profile limit (0.5 m in Tower Keep).
- **3C, rubble (accepted):** Dynamic step traversal, independent body-local
  foot anchors, support-relative cadence, render interpolation, and support
  destruction/pool-reuse validation. Generic solid support includes giblets;
  anticipatory stepping and same-body blocking preserve pushing separate objects.
  Extend the existing movement, animation,
  pool and rubble owners; review and commit separately from static terrain.

### 4. Blender authoring after the setup works

Body-part gibbing, ragdolls and performance polish are accepted. The first Blender
running-profile authoring phase and timing polish are accepted by the user.
The prepared scene and workflow are documented in
[`character_authoring/README.md`](../character_authoring/README.md).

This first phase uses Blender 4.5 LTS, native target controls and planar two-bone
IK. Sparse Constant/Linear/Bezier curves export without baking. The existing
`data.zig` loader and `character_animation.zig` evaluator validate staged exports
against 121 Blender control/pose samples before an explicit `export --apply`.
The original rig is exported for validation; editing rig proportions, other
actions, and terrain simulation inside Blender remain outside this phase.

The approved running-timing preview is now applied to the scene and exported
motion: down/passing at frames 4 and 22, earlier toe-off, higher
heel recovery and a 9 cm pelvis rise/fall. The 0.6-second cycle and existing
runtime speed response are preserved. Native tests, Blender/runtime comparisons,
build and smoke checks passed; the timing review found no actionable issues.

Build a prepared Blender scene with a planar skeleton, named target controls, IK preview, useful animation layout, and a limited set of custom properties for locomotion settings.

Populate the first scene and actions from the initial JSON assets using a narrow bootstrap script. Map named controls, normalized phase, curve handles, and contact intervals to Blender controls, frame timing, curves, and markers/properties. The user should start from the tuned initial animation.

Add an exporter that writes the already-established rig/motion/locomotion JSON. Convert axes, units, control bindings, timing, and contact intervals explicitly. Export control trajectories independently of the final solved knee/elbow pose so game-side terrain adaptation remains possible.

Use authored curves directly where their meaning matches the runtime contract; sample evaluated controls where necessary. Validate an exported cycle against the editor's control positions at selected phases and against the in-game base pose. Full terrain behavior is assessed in the game.

At this stage the user can tune profiles in Blender, export, and test in the game. A live connection is optional future work, not a prerequisite.

### 5. Body artwork

Accepted and committed as `0171fd9`. Body segments use the existing named bones
and attachment points, explicit pivots, player tint and draw order. The
stick-figure overlay remains available for diagnosis.

#### 5A. Hair appearance and head anchors

Committed as `9383af0`, before hair motion: a hair-colored scalp layer and
twelve instances of one hand-authored lock SVG, including temple locks in front of the ear.
The existing art manifest defines named head-local roots, lock widths, length
ratios, rest angles and draw layers, with independent per-player hair color and
base length. Hair follows live, ragdoll and giblet heads through the existing
artwork owner. No new hair physics or rig changes are part of this commit.
See [configuration and review steps](character_animation_hair.md).

#### 5B. Hair motion

Implemented and accepted by the user for commit, including the extended side scalp.
Short preallocated chains pin to the existing named roots and deform the shared
lock texture through existing GPU sprite batches. Gravity, damping, bend limits,
resolution and simple head/torso collision are configured in the art manifest.
Fixed-step motion survives death into pooled heads, resets on reuse/teleport/reload,
and sleeps after hair settles on still heads, independently of Box2D's sleep flag.
User feedback adds three crown locks and a downward curtain over the near ear and
cheek. Near-side locks overlap the body in projection; rear locks use the obstacles.
Reduced motion transmission and relative damping soften the response, while
measured quiet motion controls sleep after the locks settle. No Box2D hair bodies
or new editor.

Validate with the existing character checks and repeated-death benchmark, then
review running, jumps, turns, wall poses and deaths in game. Environment/self-hair
collision, ponytail and loose-hair styles remain later work.

### 6. Body-part giblets, ragdolls and shared gibbing rules

Requested follow-up, planned before returning to Blender. This section records
the intended behavior and review boundaries; it does not authorize implementation
of all subphases at once. Present each concrete subphase before starting it.

#### Baseline behavior and agreed revision

Before 6A, `player.damage` subtracted a hit from health, killed at `health <= 0`,
and gibbed at the hardcoded `player.gibHealthThreshold = -5`. A player with 10 HP
therefore gibbed from a 15-damage hit. Non-gibbing death disables the live body/entity and schedules
the gravestone and respawn; there is no corpse physics. Dead players ignore damage.

`gibbing.zig` currently chooses unrelated head/leg/meat templates from
`giblets.json`, scatters them at random offsets/orientations, and uses pooled
physical bodies. Individual giblets have 1 HP and use the shared
`damage.zig` / `destruction.zig` particle-burst and pool-return behavior.
Before 6A, object health clamped to zero on destruction, losing the overkill needed
to distinguish the proposed corpse outcomes. Phase 6A preserves signed health.

The user has chosen a new threshold of **-40 HP** for both players and ragdolls.
Gibbing uses a shared weighted random selection of the actual anatomical body
parts, allowing the destruction to consume some parts rather than always dropping
the whole skeleton. A selected part becomes a giblet; an omitted part is consumed
by the destruction effect and leaves no physical body. Keep threshold and part
weights configurable through the existing data/settings loading approach. No
separate corpse rule or attack-type restriction is introduced by this revision.

#### Required death and corpse outcomes

Let `H` be health after the damage event. Keep death at exactly zero, and gib when
health reaches **-40 or lower**. For example, a player with 10 HP dies without
gibbing from a 49-damage hit (`H = -39`), but gibs from a 50-damage hit (`H = -40`).

| Post-hit health | Living player | Existing ragdoll |
| --- | --- | --- |
| `H > 0` | Continue playing | Continue simulating |
| `-40 < H <= 0` | Die and create a ragdoll with a fresh, shared 100 HP | Remove the entire ragdoll with a particle burst |
| `H <= -40` | Die and run the shared weighted body-part gibbing effect | Run the same weighted body-part gibbing effect |

The ragdoll's 100 HP belongs to the whole corpse, not to each limb. Damage to any
part routes to the same health owner through the existing physical-object damage
pipeline. After gibbing, detached parts use individual giblet damage/destruction.
Corpse damage must not award another player kill or reset the respawn timer.

Both sources provide the same gibbing inputs: anatomical part identities, current
world transforms, motion, appearance and damage impulse. For a live player these
come from its solved physics pose; for a ragdoll they come from its current
physical bodies. One selector applies the same per-part survival weights in both
cases, including separate actual left/right parts without duplicating anatomy.
Skin and fixed-color layers are selected together as one part. Exact weights are
tuning data to review in 6B; damage-scaled or impact-location weighting is not
implicitly added. The survivors scatter as giblets and consumed parts contribute
to the blood/particle effect.

#### 6A. Centralize the -40 HP gibbing rule

Completed in `aa2c27b`. The
`damage_rules.json` profile selects -40 HP, `damage.zig` owns signed subtraction
and outcome classification, and `player.damage` uses that decision. Physical
objects retain their signed remaining health and registered destruction effect.
Score, death and respawn remain in their current owners.

This phase preserves separate pellet hits and the existing direct-impact plus
explosion budget. Dead players ignore later hits, including the remainder of an
explosive projectile after a fatal direct hit. Grouping damage to several corpse
limbs and preventing the originating attack from damaging newly created corpse
parts belong to 6C; no corpse event infrastructure is added ahead of its owner.

Validate ordinary damage, exact zero, both sides of the gib threshold, repeated
hits, and agreed attack-grouping cases using the existing test entry points.
The user reviews the resulting weapon/death behavior before a separate commit.

#### 6B. Giblets from the assembled character

Completed and accepted by the user. The full-phase independent
review and corrections are complete. The blood polish adds optional grayscale
SVG overlays with severed ends and 1–2 surface stains, tinted by the existing
particle blood-color setting. Embedded arrows now detach as harmless falling
projectiles when their target is destroyed or recycled and can stick again.
Physical part appearances now live in `character_art.bodyParts`, keyed by body
ID; entities retain rendering dispatch and remove the component on destruction.
Validation includes 122 tests, build/smoke and two airborne death events after
this ownership refactor; earlier checks covered ground and Tower Keep death
benchmarks. See
[body-part giblet notes](character_body_part_giblets.md) for findings and testing.
The final readability pass also passed all 122 tests and build/smoke; the user
requested no additional independent review for that mechanical iteration.

Replace the legacy player-death templates with the anatomical parts from the
active character-art manifest. Capture the final physics pose before disabling
the player or resetting animation, preserving each part's position, orientation,
facing, player tint and fixed-color details. Start parts with inherited motion
and the hit's scatter impulse so death begins from the character on screen.

Introduce the shared weighted survivor selection described above. Select from the
parts the character actually has instead of choosing unrelated template images.
Only selected parts receive active giblet bodies; consume the remaining parts
with the existing destruction particles. Make the selector accept a pose/part
snapshot so ragdoll gibbing can use the identical behavior in 6C.

Reuse `character_art.zig` placement/layer rendering, sprite ownership, and the
existing `gibbing.zig`, pool, entity, blood and particle-destruction components.
Skin and fixed layers of a part describe one physical object. Keep colliders and
physical properties as body-part metadata, separate from motion curves, loaded
through `data.zig`. Preserve generic stepping and foot support on the parts.

Validate both facings/colors, running and airborne death poses, inherited motion,
weighted selection with repeatable random inputs, exclusion of consumed parts,
detached-part damage and pool reuse. Ensure assets remain valid across respawn,
artwork reload and level cleanup. Review and commit the part-based giblets before
adding connected corpse physics.

#### 6C. Ragdolls with shared health and destruction

Completed and accepted by the user, including independent review and corrections.
Validation passed 134 tests and build/smoke checks. Repeated Tower Keep deaths
allocate no new explosion scratch storage or particle/corpse bodies, but a
45.431 ms frame still exceeds the benchmark's 33.333 ms gate. See the
[ragdoll notes](character_ragdolls.md) for the remaining performance and respawn
limitations.

On a non-gibbing death, create the same physical body parts connected by Box2D
hinge joints with anatomical angle limits, initialized from the death pose and
motion. The normal player remains disabled for the existing respawn lifecycle.
Use a corpse component to own the body/joint group and body-to-corpse lookup;
reuse the existing damage/destruction and art owners rather than creating a
parallel damage pipeline or copying the character renderer.

Give the corpse a shared 100 HP pool and route hitscan, projectile and explosion
damage from its parts to that pool. Group explosion health damage per corpse
using the strongest valid limb sample, while physical impulses may
still act on individual parts. Use the agreed rule from 6A to select the outcome.
On gibbing, run the same weighted survivor selection as live-player gibbing.
Release the joints and transfer only selected parts to giblet ownership without
resetting their position or velocity; remove consumed parts and emit their
destruction particles. On ordinary destruction, emit the existing particle-burst
effect over the body and remove all parts and joints as one operation. No active
invisible colliders or orphan damage entries may remain.

Handle level teardown, player respawn, artwork reload and pool recycling through
the existing lifecycle boundaries. The agreed default is eight corpses, configured
in `damage_rules.json`; recycle the oldest whole corpse when full. Retain existing
gravestone and weapon presentation. Walking and
foot anchoring must continue to treat solid corpse parts as physical supports.

Validate death-to-ragdoll continuity, joint limits, shared-health damage,
multi-limb explosions, threshold equality, ragdoll-to-giblet continuity,
identical survivor selection for equivalent live/ragdoll inputs, consumed-part
cleanup, whole-corpse particle removal, score/respawn independence and cleanup. Run the
existing relevant tests and build/smoke workflow, then independently review the
phase and hand it to the user for weapon and terrain testing before committing.

## Minimal development tools and verification

Provide an animation reload command, a repeatable movement test scene, slow motion/pause, and overlays for joint positions, desired versus solved foot targets, contact state, support points, reach limits, and ground probes. Add single-step when the simulation updates can advance coherently. Defer timelines, curve editors, rig-editing UI, live parameter panels, and replay infrastructure.

Meaningful implementation checks include IK reach/bend invariants, asset validation, curve interpolation at known phases, loop/contact boundaries, and contact release when support disappears. Visually assess start/stop/reversal, jumping/landing, aiming while moving, slopes, and moving/destroyed support. Verify stable stepping under different rendering frame rates.

For coding sessions, follow the project's build-and-smoke-test skill and inspect the required runtime logs. The smoke test establishes basic execution; visual review is still needed to assess animation quality.

Success before Blender work: the game loads data-driven profiles, the stick figure has a convincing and responsive initial run, core transitions are stable, and the remaining authoring work fits the documented JSON contract.
