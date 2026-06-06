# Level Editor Controller UX Research

Created: 2026-06-06

This note captures controller-first level editor patterns to guide feature placement in this project. When adding or moving level editor actions, compare the proposed location against these patterns and suggest a better location when the fit is weak.

## Core Observations

1. Live editor controls belong inside the editor.
   Controller-first editors treat editing as its own mode with its own viewport, cursor, tools, and configuration. Controls such as grid, snap, object properties, helper overlays, and editor visibility should be exposed from the level editor itself, not from the menu used to enter the editor.

2. Use editor-owned tool and palette menus.
   LittleBigPlanet uses the Popit menu for Create Mode tools, inventory, and global creation features. Dreams uses mode-specific tool menus, tweak menus, guides, and show/hide panels. These menus are part of the editor workflow rather than the normal game pause menu.

3. Put frequent actions on direct bindings.
   Frequent, reversible actions should stay close to the controller: select, place, cancel, delete, copy, paste, undo, redo, open picker, and open config. Slower or broader actions can live in menus.

4. Put object-specific actions in contextual object menus.
   Actions like tweak/properties, entity type, scale, sprite-specific settings, and future per-object snap behavior should appear when an object is selected or targeted.

5. Put editor helpers in an editor configuration or guides menu.
   Grid visibility, grid size, snap, floor/origin helpers, show/hide filters, debug overlays, lighting helpers, and measurement tools are editor helpers. They should be grouped together in the level editor config/guides area.

6. Separate creation palettes from editor settings.
   Asset and sprite selection belongs in a picker or palette, ideally with categories, recent items, and favorites. It should not compete with global editor settings such as grid and snap.

7. Keep test/play and validation explicit.
   Editors commonly expose a clear test/play action from the editor. Saving, trying the level, validating, and publishing are higher-impact actions and should be grouped separately from moment-to-moment editing tools.

8. Controller editors need fewer deep menus and clearer grouping.
   Trackmania and Trials show the tradeoff clearly: large asset libraries can be powerful, but controller menu traversal gets cumbersome. Prefer shallow groups, stable categories, and recent/favorite shortcuts over one large flat list.

## Placement Rules For This Project

- The menu used to enter the level editor should only contain entry actions, such as `Create New` and navigation back to the main menu.
- The live level editor config menu should contain level-wide editor settings: gravity, level height, camera zoom, aspect ratio, splitscreen, grid, grid size, and future snap settings.
- The sprite picker should contain creation palette actions: choose sprite, categories, recent sprites, favorites, and related placement defaults.
- Object/entity settings should move toward a contextual inspector opened from a selected entity.
- Direct controller bindings should be reserved for actions used repeatedly while looking at the level.
- When a new editor feature is introduced, explicitly answer: entry menu, editor config, palette, contextual inspector, direct binding, or test/save flow?
- If the first proposed location is not the best fit, suggest a better grouping before implementing.

## Current Recommendations

- Keep `Grid: ON/OFF` and `Grid Size (m)` only in the live level editor config menu.
- Add future `Snap: ON/OFF` and snap granularity controls next to grid settings.
- Consider renaming or splitting the in-editor config menu later if it grows: `Level Settings`, `Editor Helpers`, and `Try/Save` could become separate groups.
- Consider an on-screen controller helper that changes based on mode, selection state, and open tool.

## References

- Dreams edit mode guide, Guides/Grid Snap: https://docs.indreams.me/en-US/create/resources/edit-mode-guide/style/guides
- Dreams edit mode guide, Assembly Tools: https://docs.indreams.me/en/create/resources/edit-mode-guide/assembly/tools
- Dreams edit mode guide, Show/Hide: https://docs.indreams.me/en/create/resources/edit-mode-guide/coat/show-hide
- LittleBigPlanet Popit menu: https://littlebigplanet.fandom.com/wiki/Popit_Menu
- LittleBigPlanet controls: https://strategywiki.org/wiki/LittleBigPlanet/Controls
- LittleBigPlanet create mode hands-on discussion: https://www.gamespot.com/articles/littlebigplanet-create-hands-on/1100-6190801/
- LittleBigPlanet Karting create mode tips: https://blog.playstation.com/2012/12/21/littlebigplanet-karting-track-creation-tips-and-tricks/
- Trackmania map editor overview: https://wiki.trackmania.io/content-creation/map-editor
- Trackmania console editor note: https://news.ubisoft.com/en-gb/article/5nuH3hEk11McSpf59WJsNY/trackmania-available-now-on-playstation-and-xbox-consoles
- Trials Rising editor/object-library note: https://store.steampowered.com/news/posts/?appgroupname=Trials+Rising&appids=641080&enddate=1554974997
- Trials Fusion controller-editor criticism: https://www.digitaltrends.com/gaming/trials-fusion-review/
