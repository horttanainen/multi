# Level Editor Tiling And Atlas Plan

**Date:** 2026-05-29
**Status:** Planning
**Priority Order:** fix tiling first, then revisit atlas copy-on-write if needed

## Summary

The current large-static-entity path uses `sprite.splitIntoTiles()` to split one logical level object into many runtime sprites and bodies. That solved an early collision-generation problem, but it now mixes rendering, atlas ownership, editor identity, and physics decomposition. This makes bugs around copied entities, mutable textures, collider caching, and selection harder to reason about.

The preferred direction is to remove **visual/runtime tiling** from level entities and replace it with better **physics decomposition**:

- One logical entity should render as one sprite.
- One logical entity may still create many Box2D shapes.
- Collision generation should handle holes/disconnected mask regions directly from the full sprite surface.
- Atlas copy-on-write should be revisited only after visual tiling is removed or reduced.

## Recent Changes Implemented Today

These changes are relevant context if related bugs appear:

- `entity.SerializableEntity` now requires stable `id` fields; `levels/theater.json` was updated accordingly.
- `level_editor.zig` now uses an in-memory `LevelDocument`, dirty state, command history, undo/redo, and runtime maps from entity IDs to Box2D body IDs.
- Editor add/paste/type-change/move/resize paths now patch affected runtime objects instead of regenerating the whole level.
- `level.zig` now exposes reusable single-entity spawn helpers used by both full level loading and incremental editor spawning.
- `entity.zig` and `sensor.zig` gained targeted remove/highlight helpers for incremental runtime cleanup.
- `gpu.zig` now grows sprite/color vertex buffers on demand instead of skipping draws after the old fixed 64K vertex limit.
- `polygon.zig` now caches triangulated collider triangles by sprite geometry; `sprite.zig` has `geometryVersion` for invalidating this cache after surface mutations.
- Current collider caching means any future polygon/tiling rewrite must update cache keys and invalidation rules deliberately.

## Phase 1: Replace Visual Tiling With Physics Decomposition

Goal: stop turning one static level entity into many rendered tile sprites just to generate physics.

Implementation steps:

1. Add a new polygon API that works on the full sprite mask:
   - Replace `polygon.triangulate()` as the static-level path with a new function such as `polygon.triangulateMask()`.
   - It should process all solid connected components, not only the largest component.
   - It should preserve holes rather than filling them.

2. Extend the Triangle wrapper to support holes:
   - `triangle.triangulateio` already has `holelist` and `numberofholes`.
   - Add a wrapper that accepts outer contours, hole points, and segment lists.
   - Keep the current simple `triangle.split()` for callers that only have one simple polygon.

3. Build mask contour extraction for full sprites:
   - Extract outer contours and hole contours from the alpha mask.
   - Simplify each contour with the existing Visvalingam simplifier.
   - Ensure winding is correct: outer contours and holes must be oriented consistently for the triangulator.
   - Generate a point inside each hole for Triangle’s `holelist`.

4. Update level static spawning:
   - Remove `sprite.splitIntoTiles()` from `level.spawnSerializableEntity()` for normal static entities.
   - Create one sprite UUID for the visual entity.
   - Create one Box2D body for the logical entity.
   - Attach all triangles/convex shapes to that body through `box2d.createPolygonShape()`.
   - Keep `Entity.shapeIds` as the list of generated shapes.

5. Update editor runtime mapping:
   - One serialized entity ID should usually map to one body ID after visual tiling removal.
   - Keep `entity_id -> []bodyId` temporarily so the editor stays compatible with any remaining multi-body cases.
   - Selection, move, resize, type-change, and delete should continue to work through the existing ID-based maps.

6. Update collider cache:
   - Cache full-sprite mask triangulation, not per-tile triangulation.
   - Include geometry version and scale in the cache key.
   - Clear or invalidate cache entries on level cleanup and geometry-changing surface updates.

Acceptance criteria:

- A static entity with holes renders once and has correct collision holes.
- A static entity with disconnected solid regions creates collision for every solid region.
- Adding many copies of the same static entity reuses cached polygon data.
- Blood/spray/damage on one entity does not mutate visual texture data on another copy.
- Moving/deleting/selecting copied static entities still operates at logical entity level.

## Phase 2: Revisit Atlas Copy-On-Write If Needed

After visual tiling is removed, retest shared texture mutation. If copied entities still affect each other visually, fix atlas ownership explicitly.

Preferred model:

- Shared source atlas regions are immutable.
- Any per-entity pixel mutation first calls an `ensurePrivateTexture(spriteUuid)` path.
- Private texture backing is owned by that sprite/entity and released during sprite cleanup.

Implementation options:

1. Simple first fix:
   - Use standalone GPU textures for mutated sprite copies.
   - Keep immutable/unmodified sprites in the atlas.
   - This avoids dynamic atlas fragmentation and is easier to validate.

2. Better long-term fix:
   - Add a mutable dynamic atlas with free-list reclamation.
   - Allocate private atlas regions for mutated sprites.
   - Reclaim private regions when sprites are destroyed.

Visual mutation classification:

- Blood/spray paint: visual-only; should not bump `geometryVersion` or regenerate colliders.
- Explosions/terrain cuts/resizing: geometry-changing; must bump `geometryVersion`, invalidate cached triangles, and regenerate colliders.

Acceptance criteria:

- Blood on one copied entity does not appear on another copied entity.
- Spray paint on one copied entity does not appear on another copied entity.
- Explosion damage changes only the hit entity’s visual surface and collider.
- Unmodified copied entities still batch through shared atlas textures.

## Test Scenarios

- Load `levels/theater.json`; verify existing static terrain, spawn, and goal still work.
- Create many copies of the same static object in the level editor; verify load/edit performance improves through polygon cache reuse.
- Use an image with a transparent hole; verify players/projectiles collide with the solid ring but pass through the hole.
- Use an image with multiple disconnected islands; verify all islands produce collision.
- Apply blood/spray to one of several copied entities; verify only the hit copy changes.
- Apply terrain damage to one copied entity; verify only that copy changes visually and physically.
- Undo/redo editor add/paste/type changes after removing visual tiling.
- Run `zig build` and `bash scripts/smoke_test.sh`.

## Notes And Risks

- The current tiling path may still be useful as a temporary fallback for pathological masks. Keep it behind a narrow fallback if the first full-mask triangulation pass fails.
- Triangle supports holes at the C API level, but our current `triangle.split()` wrapper does not expose them.
- Box2D shape creation still needs convex polygons; the output can remain many triangle shapes attached to one body.
- Polygon simplification must not erase narrow bridges or small holes too aggressively.
- The atlas bug should not be solved by endlessly growing the main atlas with every mutated entity. Use copy-on-write and private backing instead.
