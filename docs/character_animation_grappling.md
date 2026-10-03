# Procedural rope grip

Accepted by the user for commit after the knife phase (`dc8e623`). The character
holds the player's end of the existing rope with its non-weapon hand. The other
arm keeps its carried weapon and independent aiming.

## Pose and attachment

The rig's `grapple_hand` attachment must name the hand opposite `weapon_hand`.
Its offset is 6.5 cm along the forearm, placing the rope in the existing closed
hand's palm. The same attachment supplies the physics-space hook launch point
and the interpolated drawing endpoint. The artwork reuses `hand_grip`; no new
sprite or physics joint is required. Rope rendering precedes the procedural
character so fingers cover the end of the line.

Flying and attached hooks both drive the grip. Each animation step samples the
hook position, blends the arm toward it, and stores previous/current target and
weight for rendering. The existing aiming profile supplies hand reach (0.545 m),
raising time (0.09 s), and lowering time (0.14 s). Both arms therefore share the
current reach/raise tuning. IK uses the rig's bone lengths and bend limits.
The final reach is blended through joint angles to preserve arm lengths.
The elbow retains its world-space bend branch when aiming turns the character.

The rope takes priority over the support hand's knife. Grounded knife bracing
and pushing yield while gripping or releasing the rope. Wall-slide and wall-jump
leg poses continue, with no knife contacts or scrape particles from the occupied
hand. Releasing the rope blends the hand back into the underlying pose, after
which ordinary wall contact planning resumes.

`rope.hookPosition` checks hook/support validity and shares normal entity
interpolation for the hook's rendered endpoint. A removed support stops the grip;
explicit rope release removes the hook through the existing rope lifecycle.
Death already releases the rope and resets animation state; respawn, reload,
and teleports also reset the animation history. Rope forces and collision rules
continue through the existing rope component. Sprite view retains its legacy
arm attachment, with drawing and rope attachment sharing the same interpolated
arm transform.

## Review and testing

Run the existing checks and generate the native-pose preview:

```sh
bash scripts/character_animation_check.sh
python3 scripts/export_character_art.py --check --preview agent-temp-files/grapple-hand/preview
```

The dedicated character tests cover eight hook directions, both facings, swapped
weapon/grapple hands, palm placement, bone lengths, the unchanged gun/legs,
closed-hand artwork, live flying/attached hooks, render interpolation, support
removal, reset, knife priority, and release back to wall poses. Preview
`grapple.svg` displays three solved poses; its hair is a static artwork preview.

For user playtesting:

1. Launch the rope above and diagonally, then move/swing while it is attached.
   Check that the rope stays in the palm and the same anatomical hand holds it.
2. Aim and fire in either direction while grappling, especially behind the
   character or across vertical aim.
3. Grapple from a knife push/slide, then release next to either wall. Check
   knife/rope handoff and the return to normal movement.
4. Destroy the support, die, and respawn. Check that the old rope/grip disappears.

The independent review found two P2 issues: a partial grapple overlay was
applied twice when capturing wall-release history, and the legacy sprite arm
used a different hook sample from its rope endpoint. The fixes capture the
underlying pose before the grapple overlay and share the interpolated sprite
arm transform. Regressions exercise partial raising on both walls and a moving
hook in sprite view. All 157 character tests, 35 SVG export checks, the native
build and the five-second captured smoke run passed without warnings or errors.
Use the manual checklist above when revisiting controller feel or rendered transitions.
