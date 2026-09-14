# Running animation polish

Status: accepted by the user; validation and independent review are complete.
Crouching polish is the next phase to plan, before terrain adaptation.

## Motion

The foot follows an asymmetric loop: it touches down close beneath the pelvis,
travels backwards along the ground, rolls onto the toe as the leg extends, folds
high behind the hips, then unfolds forwards and sweeps back into touchdown.
The forward knee and compact heel recovery happen together. The source preserves
the accepted pelvis bounce, torso lean and arm swing.

At the reference speed, the touchdown ankle is 0.05 m ahead of the root instead
of 0.30 m. The planted toe moves backwards at the reference travel speed, with
the existing 36% contact interval. The heel comes within 0.22 m of the animated
pelvis during recovery while the knee advances at least 0.25 m ahead of it.
These are visual tuning choices for our rig, not human anatomical standards.

The runtime asset is `character_motions/run_reference.json`: 171 keys across 13
named control tracks, interpolated with the existing Bézier evaluator. The schema,
rig and asset IDs are unchanged. Loading, IK, contact planning, speed response,
landing/crouch blending and rendering use the existing implementation.

`tests/fixtures/character_run_polish_source.json` is the sparse authoring source
for `python3 scripts/export_character_run.py`. The exporter now reads touchdown,
reference speed, cycle duration and contact duration from that source instead of
duplicating them as constants. It writes only the runtime run JSON; rebuilding
the phase-one rig would remove attachments added since that phase. The current
rig remains its own maintained asset.

The original source, twelve reference poses and dense JSON remain intact.
`tests/fixtures/character_run_reference_v1.json` also preserves the previous
compact run. Its legacy comparisons still verify the original curve conversion;
gameplay tests load the polished motion.

## Flexibility for different speeds and Blender

The current runtime already separates horizontal toe-path scaling from motion
intensity. `stride_min`/`stride_max` limit width; `full_run_speed_mps` determines
when foot lift, foot rotation, pelvis bounce, lean and arm swing reach full
strength. Cadence follows actual distance travelled and the selected stride.
This phase tests that lowering intensity reduces lift without reducing width or
changing cadence, and shortening stride reduces width without reducing lift.

The existing profile reaches full intensity at 1.8 m/s, so 3.2 and 9 m/s share
the full recovery height; higher speeds currently increase width up to its cap
and then cadence. This phase preserves that tuning. A richer speed response can
later give heel tuck/lift, forward reach, rearward reach and contact timing their
own responses. It should not uniformly scale the entire loop.

The separate X/Y/angle tracks and explicit contact intervals remain compatible
with the planned Blender export. No editor or speed-specific baked frame lists
are introduced. Future asymmetric reach changes must also preserve the stance
travel/cadence relationship so a planted foot stays in place.

Research supports leaving these controls independent: [Fukuchi et al. (2017)](https://pmc.ncbi.nlm.nih.gov/articles/PMC5426356/)
measured increasing peak hip/knee flexion and stride length across 2.5, 3.5 and
4.5 m/s. [Dorn et al. (2012)](https://journals.biologists.com/jeb/article/215/11/1944/10883/Muscular-strategy-shift-in-human-running)
describe changes in contact duration and stride-length/frequency strategies as
speed increases. A higher, tighter recovery is an animation inference from those
joint changes; neither paper supplies a universal foot-loop scaling formula.
Stride distance in the world is also different from loop width relative to the
hips. The user's [foot-path image](https://i.redd.it/2cn8lj32av3f1.jpeg) and
[running video](https://www.youtube.com/shorts/OSNqs7u57b8) guide the visual shape.

## Validation and review

Run `bash scripts/character_animation_check.sh` for formatting, native tests,
build and the five-second game smoke test. The native checks cover the new
touchdown/push-off/recovery relationship, continuous reach and sole clearance,
speed tuning, planted feet and render interpolation, starts/stops/reversals,
landing/crouch, aiming and the accepted wall poses.

The landing regression compares foot paths before per-foot anchor corrections
while compression is active. Different pelvis heights can legitimately retain
or release different anchors when the extended leg reaches its limit. It still
checks actual planted contacts, floor clearance, continued stepping and lowering
of the hips, including the transition back to running.

Native review exports under `artifacts/character_animation/`:

- `run_polish_poses.json`: 360 samples of the reference clip through the actual
  runtime curve evaluator and IK, in the authored root frame.
- `run_speed_samples.json`: solved world-space poses at 0.5, 3.2 and 9 m/s,
  sampled after settling on the native test's Box2D floor.
- `locomotion_samples.json`: the existing start/run/reverse/stop sequence.

Validation completed: 57/57 native tests passed; the game built and logged the
capture and five-second success markers without warnings, errors or panics.
Re-exporting reproduced the runtime motion byte-for-byte and preserved the rig
and archives. The archived compact motion matches baseline `69025ee` exactly.
The exact reference sheet (`run_polish.png`) and grounded speed comparison
(`run_speed_comparison.png`) were visually inspected; both derive from native
solver exports, without image generation.

The independent reviewer found no actionable issues. It reviewed the complete
phase diff and new fixtures, applicable skills, exporter ownership, reuse of
`data.zig` and the existing solver/locomotion pipeline, regression coverage and
validation logs. Only the six foot tracks changed in the runtime asset; the
pelvis, torso, hands, metadata and contacts match the accepted baseline.

Before that review, implementation checks caught two issues in existing tooling
and tests: exporting the initial rig would remove its newer holster attachment,
and a non-finite-value test depended on replacing the old touchdown number.
The exporter now leaves the rig alone; the test mutates the JSON field
structurally. The landing comparison was updated to account for legitimate
anchor-release differences at the longer rearward reach, as described above.

For manual acceptance, run `zig build run -- --character-animation`. Use **§**,
then **Z** for close view and **§**, then **S** for slow motion. Run both ways,
accelerate, reverse and stop. Check the heel folding close behind the hips while
the knee advances, the rearward toe push and the return beneath the body. Also
jump and keep moving on landing, crouch-run, aim and leave a wall slide to assess
the changed run's transitions. These checks remain useful when tuning later phases.

Terrain, speed-specific clip blending, Blender tooling, grappling and rope
animation remain later phases.
