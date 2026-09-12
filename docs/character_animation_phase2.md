# Character animation: phase two review

Status: phase two accepted by the user, including the profile rename to
`run.json`; independent review, corrections and validation complete.

## Result and scope

Stick-figure playback now follows the character's actual horizontal movement.
The accepted run curves still supply the pose; a separate locomotion profile
controls how the cycle responds to speed and how feet meet flat ground.
Sprites remain the default visual selection.

The animation reads body displacement after each physics step, along with the
existing movement component's fresh grounding result. Holding movement against a
wall therefore settles the character instead of running on the spot. Direction
follows actual displacement, independently of aiming. Starts, stops and reversals
blend control targets before IK; a stopped swing settles into a standing pose.
The last few millimeters of an idle foothold are retained once planted.
The foot links ease through a facing change in world space, preserving their
lengths and retaining valid contacts. The heel turns over the toe instead of
mirroring across the ankle in one frame.

At steady speed, stride scale is `clamp(sqrt(speed / reference_speed), min, max)`.
Cadence is `speed / (reference_speed * cycle_seconds * stride_scale)` cycles per
second. The reference clip is 3.2 m/s and 0.6 seconds; the game can reach 9 m/s.
Once the configured stride limit is reached, additional speed increases cadence.
Bob, foot lift, torso lean and arm swing have their own speed intensity, so slow
steps can cover ground with smaller vertical movements. All response settings
use simulation seconds and continue to work with the existing slow-motion toggle.

During authored stance intervals, a reachable toe can acquire a world-space
anchor on a verified flat static surface. The authored foot angle still produces
toe-off rotation. The system queries the existing Box2D world with the existing
foot-sensor collision mask, excludes moving supports, and checks the anchor every
step. Lift-off, missing support, excessive correction or exhausted leg reach
release the anchor; its remaining correction decays into the authored swing.
Queries at the sole ends prevent transition targets from entering a real flat
surface. Ledges are not treated as infinitely extended ground planes.

Rendering interpolates the previous/current control targets at the same fraction
as the physics body and solves the bones again. A toe planted across both samples
is constrained again after interpolation, preserving contact during foot rotation.
Cached sole support heights also constrain interpolation through toe-off; render
code makes no ground queries. Toe-lock eligibility uses the transformed heel
geometry, so a rig with a lower heel rests on that heel instead of reporting a
toe lock and subsequently lifting the toe. Initial poses receive the same ground
correction before previous/current samples are established.
There are no animation-owned physics bodies, gameplay forces, or per-step allocations.

## JSON tuning and Blender compatibility

`character_locomotion/run.json` is loaded through `data.zig` with the rig and
motion. All three files must parse and validate before replacement. Failed reload
retains the complete previous asset set, pose and contacts. Successful reload,
respawn, and diagnostic playback changes clear transient animation state.

The profile has schema version 1, stable `id`, `rig_id`, and `motion_id` strings,
and explicit `distance_unit: "meters"` and `time_unit: "seconds"`. It requires a
looping motion with a positive reference speed. Blender can eventually export
these settings as custom properties alongside the existing control curves;
live editing and Blender integration remain later work.

| Field | Meaning |
| --- | --- |
| `stop_speed_mps` | Displacement dead zone; phase freezes below this speed. |
| `full_run_speed_mps` | Speed at which bob, foot lift, lean and arm swing reach full intensity. |
| `start_seconds`, `stop_seconds` | Exponential response time constants; about 63% of a change per time constant. |
| `turn_seconds` | Response time for foot orientation and decay time for control offsets across a facing change. |
| `stride_min`, `stride_max` | Dimensionless bounds on the reference stride scale. |
| `release_seconds` | Decay time for a released foot's remaining positional correction. |
| `plant_distance_m` | Maximum vertical distance from the preferred toe to a new foothold. |
| `max_anchor_error_m` | Maximum distance between the preferred toe and an existing anchor. |
| `flat_height_tolerance_m` | Height tolerance for short surface verification rays. |

Response times accept 0.01–2 seconds; distance limits accept 0.001–0.5 m;
stride bounds accept `0.1 <= min <= max <= 2`. The stop threshold must be at least
0.001 m/s and less than the full-intensity speed, which cannot exceed 100 m/s.
Existing JSON shape/number validation reports unknown, missing or nonfinite fields.

## Build and test

```sh
bash scripts/character_animation_check.sh
zig build run -- --character-animation
```

The validation script formats, runs native tests, builds, and runs the game for
five seconds. It verifies the success marker, capture, and absence of warnings or
errors. Logs and `preview.png` are under `artifacts/character_animation/`.
The native tests also export `locomotion_samples.json`: exact solved world-space
joints from a deterministic stand/run/reverse/stop/slow-run sequence at 60 Hz.
These samples use the production solver and Box2D flat-ground queries.

Press **§**, then:

| Key | Action |
| --- | --- |
| P | Cycle movement-driven playback, neutral standing, and continuous reference run. |
| D | Toggle joints/targets, green rings at actual planted anchors, and speed/stride/contact status. |
| Z | Toggle close-up zoom. |
| S | Toggle quarter-speed simulation. |
| R | Reload all three character JSON files. |
| V | Cycle sprites, stick figure and overlay. |

`--character-animation-reference` selects the continuous reference run at startup.
`--character-animation-neutral` selects neutral standing.

Manual review: run on a flat platform at normal speed and quarter speed; inspect
touchdown and toe-off, abrupt stops, direction reversals, and pushing into a wall.
Check two players, death/respawn and a valid/invalid profile reload. Start with
normal gameplay scale, then use zoom and diagnostics to inspect details.

## Limits and independent review

Planting in this phase is limited to static surfaces whose normal is nearly
vertical (within about 2.6 degrees), verified near the controller's contact height.
Moving rubble, slopes, steps and action-specific jump/fall/landing poses remain
phase three. Unsupported movement blends toward neutral as a temporary fallback.
Facing changes preserve target positions, but the planar rig's knee/elbow bend
side mirrors when facing switches; this is not a 3D turning animation.
Weapons and grappling still use the existing sprite anchors.

The independent reviewer inspected all nine phase files, applicable skills, and
the existing loading, menu, movement, physics, IK and player lifecycle components.
It found three actionable issues, all P2, in `src/character_animation.zig`:

| Finding | Correction and verification |
| --- | --- |
| Facing preserved ankle targets but snapped toes by about 30 cm and discarded anchors. | Ease the actual foot links through the direction change and retain valid anchors. Reversal tests check toes and heels, including opposite-direction starts from idle, as well as the original control targets. |
| Separate ankle/angle interpolation let a released toe dip about 4.43 mm below the floor. | Retain support heights from fixed-step queries and apply sole clearance after render interpolation. Tests check both sole ends at five interpolation fractions throughout running, braking and reversal sequences. |
| Toe locking assumed a horizontal heel rest offset; a valid heel 1 cm lower broke the lock and clearance invariants. | Check transformed heel geometry before accepting a toe lock, release a lock displaced by clearance correction, and initialize corrected pose samples. A tilted-heel asset regression checks standing, turning, running, bone lengths and intermediate-frame clearance. |

There were no rejected or unresolved review findings, or additional actionable
ownership, tooling-reuse or skill-compliance findings. The implementing agent
applied the corrections and extended the checks; there was no recursive review pass.
The implementing agent also corrected an issue found during visual inspection:
sole clearance on a free foot could block the next contact after a slow restart.
Only displacement of an existing lock now blocks that stance, and the reversal
sequence checks prompt contact acquisition after restarting at 0.5 m/s.

All 25 native tests, the build, and the final five-second smoke/capture pass after
corrections. The success marker was logged with no warnings, errors or crashes.
Logs and the final capture are in `artifacts/character_animation/`; the contact
diagnostics also received a separate successful smoke/capture during implementation.
The phase was handed to the user for interactive gameplay, two-player and manual
reload/death/respawn review, and the user subsequently accepted the changes.
