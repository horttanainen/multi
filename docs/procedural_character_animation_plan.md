# Procedural Character Animation Plan

Status: Phase one accepted by the user on 2026-09-12, including the compact Bezier
control tracks; full independent review and corrections completed. The exact
dense run JSON remains as a regression reference.
Next step: agree on the phase-two plan before implementing it.
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

Keep limb identities and movement facing separate from aim direction. Aiming behind the player must not instantly mirror planted feet or flip knee bend directions.

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

Use three logically distinct asset types, with stable IDs and explicit schema versions:

| Asset | Contents |
| --- | --- |
| Rig | Named joints/bones, hierarchy, reference offsets, lengths, bend conventions, limits, and named attachment points. |
| Motion clip | Named control tracks, reference cycle duration/speed, looping policy, contact intervals, and optional named phase cues. |
| Locomotion profile | Clip references, speed-to-cadence/stride relationships, transition settings, ground-query rules, and limits on procedural adjustments. |

Proposed locations are `character_rigs/`, `character_motions/`, and `character_locomotion/`. Create real assets during implementation, once the minimal loader and first pose work together.

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

### 3. Actions and terrain adaptation

Add jump, fall, landing, aiming/grappling, and wall-slide pose behavior. Add slope/step adaptation and then moving/destructible rubble, using the same control tracks and bounded corrections.

Validate transitions with the real movement controller. Keep gameplay collision behavior independent from cosmetic pose corrections.

### 4. Blender authoring after the setup works

Build a prepared Blender scene with a planar skeleton, named target controls, IK preview, useful animation layout, and a limited set of custom properties for locomotion settings.

Populate the first scene and actions from the initial JSON assets using a narrow bootstrap script. Map named controls, normalized phase, curve handles, and contact intervals to Blender controls, frame timing, curves, and markers/properties. The user should start from the tuned initial animation.

Add an exporter that writes the already-established rig/motion/locomotion JSON. Convert axes, units, control bindings, timing, and contact intervals explicitly. Export control trajectories independently of the final solved knee/elbow pose so game-side terrain adaptation remains possible.

Use authored curves directly where their meaning matches the runtime contract; sample evaluated controls where necessary. Validate an exported cycle against the editor's control positions at selected phases and against the in-game base pose. Full terrain behavior is assessed in the game.

At this stage the user can tune profiles in Blender, export, and test in the game. A live connection is optional future work, not a prerequisite.

### 5. Body artwork

Attach body segments to the existing named bones and attachment points, with explicit pivots and draw order. Keep the stick-figure view as a diagnostic overlay. Add mesh deformation only if the chosen artwork needs it.

## Minimal development tools and verification

Provide an animation reload command, a repeatable movement test scene, slow motion/pause, and overlays for joint positions, desired versus solved foot targets, contact state, support points, reach limits, and ground probes. Add single-step when the simulation updates can advance coherently. Defer timelines, curve editors, rig-editing UI, live parameter panels, and replay infrastructure.

Meaningful implementation checks include IK reach/bend invariants, asset validation, curve interpolation at known phases, loop/contact boundaries, and contact release when support disappears. Visually assess start/stop/reversal, jumping/landing, aiming while moving, slopes, and moving/destroyed support. Verify stable stepping under different rendering frame rates.

For coding sessions, follow the project's build-and-smoke-test skill and inspect the required runtime logs. The smoke test establishes basic execution; visual review is still needed to assess animation quality.

Success before Blender work: the game loads data-driven profiles, the stick figure has a convincing and responsive initial run, core transitions are stable, and the remaining authoring work fits the documented JSON contract.
