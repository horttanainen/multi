---
name: zig-guard-clause
description: Apply this skill whenever generating new Zig code in this project. All special cases — null optionals, missing values, error conditions — must be handled upfront as guard clauses (early returns/continues/breaks) before the happy path. Never use if (optional) |value| { happy path } style; instead invert to handle the absent case first, then unwrap and continue. After applying this skill, always apply the zig-defensive-logging skill so that the guard clause branches get appropriate log calls.
---

# Zig Guard Clause Style

When writing Zig code in this project, always handle special cases (null, missing, error) upfront as guard clauses. The happy path should be at the top indentation level, not nested inside an `if` block.

## The pattern

**Optionals — never nest the happy path:**

```zig
// BAD
if (cameras.getPtr(id)) |cam| {
    moveCamera(cam, pos);
}

// GOOD
if (cameras.getPtr(id) == null) return;
const cam = cameras.getPtr(id).?;
moveCamera(cam, pos);
```

**When the guard should propagate an error instead of returning void:**

```zig
// BAD
if (maybeEntity) |e| {
    process(e);
}

// GOOD
const e = maybeEntity orelse return error.EntityNotFound;
process(e);
```

**Chained or nested optionals — flatten with multiple guards:**

```zig
// BAD
if (getPlayer(id)) |player| {
    if (cameras.getPtr(player.cameraId)) |cam| {
        moveCamera(cam, player.pos);
    }
}

// GOOD
if (getPlayer(id) == null) return;
const player = getPlayer(id).?;
if (cameras.getPtr(player.cameraId) == null) return;
const cam = cameras.getPtr(player.cameraId).?;
moveCamera(cam, player.pos);
```

**If/else where else is the special case — invert it:**

```zig
// BAD
if (maybeFile) |*f| {
    // 30 lines of happy path
} else {
    // special case
}

// GOOD
if (maybeFile == null) {
    // special case
    return;
}
const f = &maybeFile.?;
// 30 lines of happy path, no extra nesting
```

**Error unions — use `catch` guard or `try`:**

```zig
// BAD
if (loadLevel(path)) |level| {
    useLevel(level);
} else |err| {
    handleError(err);
}

// GOOD
const level = loadLevel(path) catch |err| {
    handleError(err);
    return;
};
useLevel(level);
```

## Choosing how to unwrap

- Use `.?` when null is truly unexpected and the guard above makes it safe
- Use `orelse return error.X` when the caller needs to know something was missing
- Use `orelse unreachable` only when the compiler cannot prove non-null but you are certain — add a comment explaining why

## After writing code with guard clauses

Always apply the **zig-defensive-logging** skill next — the guard clause branches you just wrote are prime candidates for `std.log.warn`/`std.log.err` calls.
