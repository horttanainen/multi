---
name: code-style
description: Apply this skill whenever writing new code or refactoring existing code in this project. Covers the component architecture, ID-based function design, data exposure rules, and avoidance of OOP/functional programming patterns. Trigger on any code generation, feature addition, or structural change.
---

# Code Style and Architecture

This project uses a **component architecture**: the game is made up of components like `entity`, `sprite`, `player`, `camera`, `weapon`, etc. Each component is a Zig file that owns a collection of structs and the functions that operate on them.

## IDs over pointers

Prefer passing IDs as function arguments rather than pointers to structs. Inside the component file, look up the struct from the map using the ID.

```zig
// BAD — caller holds and passes a pointer
pub fn damage(player: *Player, amount: f32) void { ... }

// GOOD — caller passes an ID, function does the lookup
pub fn damage(playerId: usize, amount: f32) void {
    const player = players.getPtr(playerId) orelse return;
    ...
}
```

This keeps ownership clear and avoids dangling pointers when maps reallocate.

There are cases where a pointer is fine — for instance when a function is only ever called from within the component file itself, or in a tight loop where the lookup has already been done. Use judgment. The goal is to avoid pointer-passing as the default interface between components.

## Maps over lists when lookup matters

Use a map (e.g. `std.AutoArrayHashMap`) when items need to be found by key. Don't use a list and iterate to find a specific item.

```zig
// BAD — list forces a linear scan to find one player
var players: []Player = ...;
for (players) |p| { if (p.id == id) ... }

// GOOD — map gives direct access by ID
pub var players: std.AutoArrayHashMapUnmanaged(usize, Player) = .{};
const player = players.getPtr(id);
```

Use a list (slice or ArrayList) only when you genuinely need to process all items or when order matters.

## Expose maps and lists directly

Don't create getters or setters just to wrap a map or list. Make them `pub` and let callers access them directly.

```zig
// BAD — unnecessary wrapper
fn getPlayers() *Players { return &players; }

// GOOD — just expose the map
pub var players: std.AutoArrayHashMapUnmanaged(usize, Player) = .{};
```

Only hide a map behind a function when access requires shared logic every time — for example, when every read or write needs to acquire a mutex, or when every write must trigger a side effect.

## No OOP or functional patterns

Don't reach for inheritance, interfaces, factory functions, monads, or other named programming patterns. If you find yourself writing a pattern, ask whether a plain function or a struct field achieves the same thing more directly.

- No vtable-style dispatch via function pointer fields on structs (unless interfacing with C APIs that require it)
- No wrapper types that exist only to add methods
- No builder/factory functions when a struct literal works
- No generic "manager" or "registry" abstractions — each component manages its own data

## Functions are flat, not nested in types

Functions belong at the file (namespace) level, not attached to structs as methods. Structs hold data; files hold behavior.

```zig
// BAD
const Player = struct {
    fn damage(self: *Player, amount: f32) void { ... }
};

// GOOD
pub fn damage(playerId: usize, amount: f32) void { ... }
```

## One component, one file

Each logical component lives in its own file. The file is the namespace. Don't split a single component across multiple files, and don't merge two unrelated components into one file.
