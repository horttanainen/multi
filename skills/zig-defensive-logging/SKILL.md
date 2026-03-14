---
name: zig-defensive-logging
description: Apply this skill whenever generating new Zig code in this project. When writing any branch that handles an unexpected or error condition — such as a null check that shouldn't normally be null, an empty slice that should have entries, a missing entity or camera, or any other "this shouldn't happen but we must handle it" case — always add a std.log.warn or std.log.err call before returning. This ensures unexpected runtime conditions leave a trace for debugging. Use this skill for all new Zig code written in this codebase.
---

# Zig Defensive Logging

When generating Zig code in this project, always add a log call in branches that handle unexpected conditions before returning early or returning null/void.

## The pattern

Two kinds of branches:

1. **Expected / normal control flow** — no log needed. Example: a menu closing because the user pressed escape, iterating an empty list as a valid state, etc.

2. **Unexpected / defensive branches** — always log. These are guards that exist because the type system requires handling the null/empty case, but in practice hitting them would indicate something went wrong. Always add a log here.

```zig
// BAD — silent unexpected return
fn followSharedCamera() void {
    const values = player.players.values();
    if (values.len == 0) return;
    ...
}

// GOOD — unexpected condition is logged
fn followSharedCamera() void {
    const values = player.players.values();
    if (values.len == 0) {
        std.log.warn("followSharedCamera: no players found, skipping", .{});
        return;
    }
    ...
}
```

```zig
// BAD
const entity = entity_map.get(id) orelse return null;

// GOOD
const entity = entity_map.get(id) orelse {
    std.log.warn("getPlayerEntity: entity {d} not found", .{id});
    return null;
};
```

## Log level guidance

- `std.log.warn` — something unexpected happened but the game can continue
- `std.log.err` — something that should never happen and likely indicates a bug

## Message format

Include the function name and a short description of what was unexpectedly missing or wrong:

```
"functionName: what was unexpectedly null/empty/missing"
```

If you have a relevant ID or value, include it:

```zig
std.log.warn("spawnEnemy: body {d} has no entity, skipping spawn", .{bodyId});
```

## What NOT to log

- Normal `else` branches in game logic (e.g. "player is on ground, do nothing")
- Explicit early exits that are part of expected control flow
- Cases where null/empty is a routine possibility the caller handles
