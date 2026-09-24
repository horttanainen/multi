# Alien skater appearance study

Status: the user selected Curb Rat (A) as the design direction. Its current
side profile has a subtle pointed nose with one visible vertical nostril slit, a
skinny muscular build and bare three-toed feet with sharp nails. The user has
approved this appearance. [Segment preparation and runtime integration](../../curb_rat_v1/README.md)
are now accepted, and the user has authorized committing the artwork.

Complete SVG drawings for a shirtless, wiry alien skater with 1990s sunglasses
and ragged shorts. The original alternatives retain their flip-flops as design
history; the current side-profile artwork uses bare alien feet:

- `a_curb_rat.svg`: smooth alien skull, black wraparound shades, dark denim and
  coral flip-flop straps.
- `b_pool_lizard.svg`: rough reptilian head, orange sports shades, baggy purple
  cut-offs and yellow straps.
- `c_orbit_punk.svg`: angular head, white frames with mirrored pink lenses,
  an earring, wallet chain and muted green straps.
- `a_curb_rat_side.svg`: the selected Curb Rat redrawn for the side-view game,
  with one visible sunglass lens and temple arm, a subtle pointed nose with one
  visible vertical slit, defined shoulders/chest/arms/calves on a skinny frame, and
  bare three-toed feet with pale sharp nails.

All three use the same stance for comparison. Skin is neutral white/grey:
`#ffffff`, `#f3f3f3`, `#b8b8b8` and `#747474`. The darker values provide shading
and depth separation. Multiply these skin colors by the player's RGB color;
clothing, accessories, teeth, nails and outlines retain their own colors. This color
separation must be preserved when preparing the eventual runtime artwork.

The editable source for each concept is its SVG. The comparison sheet and its
disposable drawing script are in `agent-temp-files/alien-design-v1/`; the sheet
includes enlarged drawings, nominal 125-pixel previews against existing game
art, and four player-tint examples. The first sheet was front-biased and remains
an appearance reference; it is not the gameplay-facing drawing.
The current side-profile review sheet and its disposable assembly script are in
`agent-temp-files/alien-side-v4/`. They reuse the maintained side-profile SVG to
show the whole character, head/muscle/foot details, both facings and small-scale
white/tinted previews. Earlier side-profile sheets are preserved in
`agent-temp-files/alien-side-v1/`, `agent-temp-files/alien-side-v2/` and
`agent-temp-files/alien-side-v3/`.
These are static appearance previews, not
captures of an integrated character. No generated bitmap artwork was used.

Appearance approval precedes preparing movable segments. These drawings are
not loaded by the game. After a design is approved, prepare joint overlaps,
pivots, color layers and draw order, then check the assembled artwork in the
existing running, kneeling, aiming and wall poses. Runtime integration is a
separate reviewable phase, reusing the current skeleton and sprite renderer.

Validation for this design pass: all SVGs parsed, the comparison sheet rendered
with macOS Quick Look, and the resulting image was visually inspected. No
runtime code changed, so build/smoke checks and an independent code review were
not needed for this appearance study.
