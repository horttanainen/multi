# Multiplayer Migration Plan

**Project:** Multi - 2D Physics-Based Action Game
**Current State:** 2-player local split-screen
**Goal:** Client-server networked multiplayer (localhost → LAN)
**Date Created:** 2026-01-03
**Status:** Planning Phase

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Current Architecture Analysis](#current-architecture-analysis)
3. [Industry Research Findings](#industry-research-findings)
4. [Migration Strategy](#migration-strategy)
5. [Implementation Roadmap](#implementation-roadmap)
6. [Technical Specifications](#technical-specifications)
7. [Risk Analysis](#risk-analysis)
8. [Next Steps](#next-steps)

---

## Executive Summary

### Current State
- **Architecture:** Local split-screen multiplayer
- **Players:** Exactly 2 players hardcoded
- **Physics:** Single Box2D world, deterministic local simulation
- **Rendering:** 2 viewports, each player has their own camera
- **Input:** Direct keyboard/gamepad → player state modification
- **Network:** None - purely local

### Target State
- **Phase 1:** Localhost client-server (one process = server+client, one = client)
- **Phase 2:** LAN multiplayer with server discovery
- **Architecture:** Authoritative server with client-side prediction
- **Protocol:** UDP with custom reliability (ENet)
- **Synchronization:** Client prediction + snapshot interpolation

### Recommended Approach
**Client-Server Architecture** (not lockstep) because:
- More scalable beyond 2-4 players
- Better handles latency variance
- Industry-proven for action games
- Box2D 3.1+ has cross-platform determinism but NOT rollback determinism
- Easier anti-cheat implementation later

---

## Current Architecture Analysis

### 1. Player State Management

**File:** `src/player.zig` (525 lines)

**Player Structure:**
```zig
pub const Player = struct {
    id: usize,
    bodyId: box2d.c.b2BodyId,
    cameraId: usize,
    footSensorShapeId: box2d.c.b2ShapeId,
    leftWallSensorId: box2d.c.b2ShapeId,
    rightWallSensorId: box2d.c.b2ShapeId,
    weapons: []weapon.Weapon,
    health: f32,
    aimDirection: vec.Vec2,
    airJumpCounter: i32,
    // ... movement flags, contact counts
};

pub var players: std.AutoArrayHashMapUnmanaged(usize, Player) = .{};
```

**Critical Functions:**
- `spawn(position)` - Creates player with physics body, camera, viewport
- `moveLeft()`, `moveRight()`, `jump()` - Movement mechanics
- `aim()`, `shoot()` - Combat mechanics
- `checkSensors()` - Ground/wall detection
- `updateAllStates()` - Updates interpolation states for all players
- `updateAllAnimationStates()` - Syncs animations
- `clampAllSpeeds()` - Movement speed limiting

**For Networking:**
- Need to serialize: position, velocity, rotation, health, aimDirection, animationState
- Movement functions must become deterministic (same input → same output)
- Create `applyInputCommand()` function to process networked inputs

---

### 2. Split-Screen System

#### Camera Management (`src/camera.zig` - 195 lines)

```zig
pub const Camera = struct {
    id: usize,
    playerId: usize,        // Links to specific player
    posPx: vec.IVec2,       // Camera position in pixels
    bodyId: box2d.c.b2BodyId,
    state: ?box2d.State,
};

pub var cameras: std.AutoArrayHashMapUnmanaged(usize, Camera) = .{};
pub var activeCameraId: usize = 0;
```

**Key Functions:**
- `spawnForPlayer(playerId, position)` - Creates player-specific camera
- `followAllPlayers()` - Updates all cameras to follow their players
- `relativePosition(worldPos)` - Converts world → camera-relative coordinates
- `setActiveCamera(cameraId)` - Switches rendering context

**For Networking:**
- Client only needs ONE camera (their own player)
- Server doesn't need cameras at all (headless)
- Remove multi-camera rendering on client

#### Viewport Layout (`src/viewport.zig` - 93 lines)

```zig
pub const Viewport = struct {
    cameraId: usize,
    rect: sdl.Rect,  // Screen position and size
};

// Current layouts:
// 1 player:  Full screen (2000x1200)
// 2 players: Vertical split (1000x1200 each)
// 3-4 players: TODO (not implemented)
```

**For Networking:**
- Client uses full screen (single viewport)
- Remove viewport splitting logic on client
- Server has no viewports

---

### 3. Input System

#### Input Flow
```
input.handle() [main dispatcher in src/input.zig]
  ↓
For each controller:
  ├→ keyboard.handle(ctrl) [src/keyboard.zig]
  └→ gamepad.handle(ctrl)  [src/gamepad.zig]
    ↓
    control.executeAction(playerId, action) [src/control.zig]
    control.executeAim(playerId, direction)
    ↓
    player.moveLeft(player), player.jump(player), etc.
    [Direct state modification - NOT NETWORK READY]
```

#### Controller Abstraction (`src/controller.zig` - 87 lines)

```zig
pub const Controller = struct {
    playerId: usize,
    color: sprite.Color,
    inputType: InputType,  // .keyboard or .gamepad
    keyBindings: ?keyboard.KeyboardBindings,
    gamepadBindings: ?gamepad.GamepadBindings,
};

pub const GameAction = enum {
    move_left, move_right, jump,
    aim_left, aim_right, aim_up, aim_down,
    shoot,
};
```

#### Keyboard Bindings (`src/keyboard.zig` - 115 lines)

```zig
// Player 1: WASD + TFGH + LShift
// Player 2: IJKL + Arrow keys + RShift
```

**For Networking:**
- **Critical Issue:** Input directly modifies player state
- **Required:** Command pattern - input → command → queue → transmit → apply
- Create `InputCommand` struct (playerId, actions, aimDirection, sequenceNumber)
- Client queues commands, sends to server
- Server receives, validates, applies to simulation

---

### 4. Game Loop Structure

**Main Loop (`src/main.zig` - 173 lines):**

```
while (!shared.quitGame) {
    time.frameBegin()           // Calculate delta time

    physics.step()              // Fixed 60Hz timestep

    input.handle()              // Process keyboard/gamepad

    if (editingLevel)
        levelEditorLoop()
    else
        gameLoop()              // Game logic

    renderer.render()           // Multi-camera rendering

    time.frameEnd()             // Update timing stats
}
```

**Physics Step (`src/physics.zig` - 24 lines):**

```zig
pub fn step() !void {
    const resources = try shared.getResources();
    while (time.accumulator >= config.physics.dt) {  // 1/60 second
        entity.updateStates();
        particle.updateStates();
        player.updateAllStates();
        camera.updateState();
        box2d.c.b2World_Step(resources.worldId, config.physics.dt, 4);  // 4 substeps
        time.accumulator -= config.physics.dt;
    }
    time.alpha = time.accumulator / config.physics.dt;
}
```

**Game Logic (`gameLoop()` in main.zig):**

```
1. Check goal reached
2. Clamp player speeds
3. Process particle contacts
4. Process projectile contacts
5. Update animation states
6. Clean up entities
7. Check player sensors
8. Check goal sensor
9. Update cameras
```

**Rendering (`src/renderer.zig` - 69 lines):**

```zig
pub fn render() !void {
    sdl.renderClear(renderer);

    // Render EACH camera to its viewport
    for (camera.cameras.keys()) |cameraId| {
        renderCamera(cameraId);
    }

    sdl.renderPresent(renderer);
}

fn renderCamera(cameraId: usize) !void {
    camera.setActiveCamera(cameraId);      // Switch context
    viewport.setViewport(cameraId);        // Set SDL viewport

    background.draw();
    sensor.drawGoal();
    entity.drawAll();
    particle.drawAll();
    player.drawAllCrosshairs();
    ui.drawMode();
    ui.drawFps();
    ui.drawPlayerHealth();
}
```

**For Networking:**
- **Server:** No rendering, just simulation loop
- **Client:** Single camera, full screen viewport
- Add network message processing to main loop
- Separate simulation from rendering

---

### 5. Game State Distribution

**Current Problems:**
- State scattered across multiple modules:
  - `player.players` - Player states
  - `entity.entities` - Entity states
  - `particle.particles` - Particle states
  - `level.position`, `level.size` - Level state
  - `shared.goalReached` - Game flags
- No centralized state management
- No serialization capability

**For Networking:**
- **Required:** Centralized `GameState` struct
- Must be serializable for network transmission
- Server maintains authoritative version
- Clients receive snapshots

---

### 6. Hardcoded Assumptions

**Level Loading (`src/level.zig` - 192 lines):**

```zig
// Hardcoded 2-player spawning
const playerId1 = try player.spawn(spawnLocation);
const color1 = try controller.createControllerForPlayer(playerId1);

const p2Position = vec.IVec2{
    .x = spawnLocation.x + 10,
    .y = spawnLocation.y,
};
const playerId2 = try player.spawn(p2Position);
const color2 = try controller.createControllerForPlayer(playerId2);
```

**For Networking:**
- Server controls player spawning
- Client sends "ready" message
- Server spawns players dynamically based on connections
- No hardcoded player count

---

## Industry Research Findings

### Network Architecture Models

#### Client-Server (Authoritative Server) ✅ RECOMMENDED

**How it works:**
- Server maintains authoritative game state
- Clients send inputs to server
- Server validates inputs, updates simulation
- Server sends state snapshots to clients
- Clients predict and render

**Advantages:**
- Server has final authority (cheat prevention)
- Scales well (tested with 10+ players)
- Industry standard for competitive games
- Works with non-deterministic physics

**Disadvantages:**
- Requires server infrastructure
- More complex than peer-to-peer
- Needs latency compensation

**Use cases:**
- Counter-Strike, Overwatch, Fortnite
- Any competitive multiplayer game
- Our recommended approach

---

#### Deterministic Lockstep (Alternative)

**How it works:**
- All clients receive all player inputs
- Each client runs identical simulation
- Game only advances when ALL inputs received
- Perfect synchronization guaranteed

**Advantages:**
- Very low bandwidth (only inputs)
- Perfect synchronization
- No server authority needed
- Good for RTS games

**Disadvantages:**
- Limited to 2-4 players
- Input delay = network latency
- Requires perfect determinism
- Slowest player holds everyone back

**Box2D Determinism Status (2024):**
- ✅ Cross-platform determinism (same inputs → same outputs)
- ❌ No rollback determinism (can't perfectly reconstruct past)
- Achieved in Box2D 3.1+ through careful floating-point handling

**Verdict for our game:**
- Could work for 2-player only
- Would feel laggy (50-150ms input delay)
- Not recommended for fast-paced action

---

### Synchronization Strategies

#### Client-Side Prediction ✅ USED

**How it works:**
1. Client captures input
2. Client immediately predicts result locally
3. Client sends input to server
4. Server processes input authoritatively
5. Server sends back actual state
6. Client reconciles differences

**Implementation:**
```
Client maintains:
- Pending inputs (not yet acknowledged by server)
- Predicted local player state
- Last server-confirmed state

When server snapshot arrives:
1. Remove acknowledged inputs from pending list
2. Start from server's confirmed state
3. Re-apply remaining pending inputs
4. Result = corrected prediction
```

**Advantages:**
- 0ms perceived input latency for local player
- Server remains authoritative
- Industry standard for FPS/action games

**Complexity:**
- Medium - requires input buffering and reconciliation

**Research sources:**
- Gabriel Gambetta's client-side prediction articles
- Valve Source Engine networking documentation
- Used by: Counter-Strike, Team Fortress, Overwatch

---

#### Snapshot Interpolation ✅ USED (for remote entities)

**How it works:**
- Server sends periodic snapshots of game state (20-30 Hz)
- Client buffers recent snapshots
- Client renders interpolated state between two snapshots
- Clients render ~100ms in the past

**Advantages:**
- Simple to implement
- Handles packet loss gracefully (skip to next snapshot)
- Smooth visual movement

**Disadvantages:**
- Remote entities shown in the past
- Higher bandwidth than lockstep
- Vertical scaling limit: ~4,096 entities with 10 players

**For our game:**
- Use for remote player
- Use for physics objects (crates, debris)
- Use for particles
- Combined with client prediction for local player

---

### Network Protocol

#### UDP vs TCP

**UDP (Recommended)** ✅
- Unreliable, unordered delivery
- No head-of-line blocking
- Lower latency (no retransmission delay)
- Perfect for real-time games

**TCP (Not Recommended)** ❌
- Reliable, ordered delivery
- Head-of-line blocking adds 125-500ms on packet loss
- One lost packet stalls all subsequent data
- Not suitable for real-time action

**Solution:**
- Use UDP as transport
- Implement custom reliability layer
- Mark critical messages reliable (player join, weapon pickup)
- Mark frequent messages unreliable (position updates)

**Recommended Libraries:**
1. **ENet** (Recommended for simplicity)
   - Battle-tested, used by many indie games
   - Built-in reliability layer
   - Simple C API
   - Cross-platform

2. **GameNetworkingSockets** (Valve)
   - Very robust
   - More features
   - Heavier dependency

3. **KCP**
   - Lightweight
   - Fast
   - Minimal features

---

#### Message Serialization

**FlatBuffers** ✅ RECOMMENDED for our game

**Performance:**
- Deserialization: 0.09µs (ultra-fast, zero-copy)
- Serialization: 1048µs
- Size: Medium (slightly larger than Protobuf)

**Advantages:**
- Zero-copy deserialization = lowest possible latency
- Perfect for fast-paced action games
- Used by Cocos2d-x
- Schema evolution support

**Alternatives:**

**Protocol Buffers:**
- Smaller size (3x smaller than FlatBuffers)
- Faster serialization (708µs)
- Slower deserialization (69µs vs 0.09µs)
- Good if bandwidth is bottleneck

**Custom Binary:**
- Maximum performance
- More development time
- Harder to maintain

**Recommendation:** Start with FlatBuffers, switch to custom binary only if profiling shows it's necessary.

---

### Tick Rates

**Industry Standards for Action Games:**

```
Physics Simulation:  60 Hz (16.67ms)  [Server]
Network Send Rate:   20-30 Hz (33-50ms)
Input Send Rate:     30 Hz (33ms)      [Client → Server]
Snapshot Send Rate:  20-30 Hz          [Server → Client]
```

**Our Configuration:**
- Physics: 60Hz (matches current local game)
- Client inputs: 30Hz (responsive, not excessive)
- Server snapshots: 20Hz (balance bandwidth/smoothness)
- Interpolation buffer: 100ms (2-3 snapshots at 20Hz)

**Entity-Specific Rates:**
- Critical (players, projectiles): 30Hz
- Important (physics objects): 20Hz
- Static/slow objects: 10Hz or on-change only

---

### Latency Compensation

**1. Client-Side Prediction (Local Player)**
- Client predicts own actions immediately
- Result: 0ms perceived input latency
- Server corrects if prediction wrong

**2. Snapshot Interpolation (Remote Entities)**
- Interpolate between two received states
- Buffer 100ms of snapshots
- Result: Smooth remote player movement

**3. Lag Compensation (Server-Side)**
- Server "rewinds" game state when processing shots
- Checks hit detection at client's view time
- Accounts for client's ping
- Prevents "shooting ghosts"

**4. Input Buffering**
- Buffer 2-3 frames of input
- Smooths network jitter
- Helps with minor packet loss

---

### Physics Networking Challenges

**Box2D-Specific Issues:**

1. **Large Internal State:**
   - Contact manifolds
   - Solver state
   - Warm-starting data
   - Contact ordering can vary

2. **No Rollback Determinism:**
   - Can't save/restore full state efficiently
   - Expensive to save all internal state
   - Different from fighting game rollback (GGPO)

3. **Prediction Limitations:**
   - Full physics rollback is expensive
   - Contact ordering may differ on rollback
   - Can cause jitter

**Our Solution:**
- ✅ Client predicts LOCAL PLAYER only (simple physics)
- ✅ Remote entities use interpolation (no prediction)
- ✅ Server has final authority on all physics
- ✅ Accept minor visual inconsistencies for complex physics

**What NOT to do:**
- ❌ Full physics rollback for all entities
- ❌ Predict complex physics interactions
- ❌ Client-authoritative physics

---

### Bandwidth Estimation

**For 2 Players at 20Hz:**

```
Per Snapshot (Server → Client):
- 2 players × (pos + vel + rot + health)
  = 2 × (8 + 8 + 4 + 4) = 48 bytes
- ~10 physics objects × 24 bytes = 240 bytes
- Overhead + serialization = ~50 bytes
- Total: ~300 bytes per snapshot

Per Client Bandwidth:
- Outgoing (inputs): 30Hz × 20 bytes = 600 B/s = 4.8 Kbps
- Incoming (snapshots): 20Hz × 300 bytes = 6000 B/s = 48 Kbps
- Total: ~53 Kbps per client

This is well within modern internet capacity (even 3G has 384 Kbps+)
```

---

## Migration Strategy

### Core Principles

1. **Incremental Migration:** Each phase produces a working system
2. **Localhost First:** Test locally before adding network complexity
3. **Server Authority:** Server has final say on game state
4. **Client Prediction:** Local player feels responsive
5. **Graceful Degradation:** Can fall back to split-screen if networking fails

---

### Architecture Diagram

**Target Architecture:**

```
┌─────────────────────────────────────────┐
│           SERVER PROCESS                │
│  (Player 1 machine or dedicated)        │
├─────────────────────────────────────────┤
│                                         │
│  Network Event Loop:                    │
│  ├─ Receive client inputs (30Hz)       │
│  └─ Send snapshots (20Hz)              │
│                                         │
│  Simulation Loop (60Hz fixed):          │
│  ├─ Process queued inputs               │
│  ├─ Step Box2D physics                  │
│  ├─ Update entities/particles           │
│  ├─ Game logic (collisions, health)     │
│  └─ Generate state snapshots            │
│                                         │
│  Authoritative State:                   │
│  ├─ GameState struct                    │
│  ├─ Box2D world                         │
│  └─ All entity positions/velocities     │
│                                         │
└─────────────────────────────────────────┘
            ↕ UDP (ENet)
         Inputs ↑  Snapshots ↓
            ↕
┌─────────────────────────────────────────┐
│          CLIENT PROCESS                 │
│         (Each player)                   │
├─────────────────────────────────────────┤
│                                         │
│  Input Loop (60Hz):                     │
│  ├─ Capture keyboard/gamepad            │
│  ├─ Create InputCommand                 │
│  ├─ Predict local player state          │
│  ├─ Send to server (30Hz)              │
│  └─ Buffer unacknowledged inputs        │
│                                         │
│  Network Event Loop:                    │
│  ├─ Receive server snapshots            │
│  ├─ Reconcile local player              │
│  └─ Interpolate remote entities         │
│                                         │
│  Render Loop (vsync):                   │
│  ├─ Use predicted local player          │
│  ├─ Use interpolated remote entities    │
│  └─ Single camera, full screen          │
│                                         │
└─────────────────────────────────────────┘
```

---

### Data Flow

**Input Flow (Client → Server):**
```
1. Client captures input (WASD, aim direction)
2. Client creates InputCommand {
     playerId: 0,
     sequenceNumber: 123,
     timestamp: 1234.567,
     actions: { moveLeft: true, jump: false, ... },
     aimDirection: { x: 0.5, y: 0.8 }
   }
3. Client immediately applies to local prediction
4. Client adds to pending buffer
5. Client serializes and sends to server (UDP)
6. Server receives and queues
7. Server applies during simulation tick
8. Server includes lastAcknowledgedInput in snapshot
9. Client removes from pending buffer
```

**State Flow (Server → Client):**
```
1. Server simulates physics (60Hz)
2. Every 3 ticks, server creates snapshot (20Hz):
   ServerSnapshotMessage {
     tick: 3600,
     lastAcknowledgedInput: 123,  // per-client
     gameState: {
       players: [
         { id: 0, pos: {100, 200}, vel: {5, 0}, health: 100, ... },
         { id: 1, pos: {300, 200}, vel: {-2, 0}, health: 85, ... }
       ],
       entities: [...],
       particles: [...]
     }
   }
3. Server serializes to bytes
4. Server sends to all clients (UDP unreliable)
5. Client receives and adds to snapshot buffer
6. Client reconciles local player:
   - Remove acknowledged inputs
   - Re-predict with remaining pending inputs
7. Client interpolates remote entities:
   - Find two snapshots around (now - 100ms)
   - Lerp position/velocity between them
8. Client renders combined state
```

---

## Implementation Roadmap

### PHASE 1: Architecture Refactoring (Local - No Networking)

**Duration:** 1-2 weeks
**Goal:** Prepare codebase for networking without changing functionality

#### Step 1.1: Create Input Command System

**New file:** `src/input_command.zig`

```zig
const std = @import("std");
const vec = @import("vector.zig");

/// Represents a single frame of player input
pub const InputCommand = struct {
    playerId: usize,
    sequenceNumber: u32,      // For client-server reconciliation
    timestamp: f64,            // When input was captured
    actions: ActionSet,
    aimDirection: vec.Vec2,

    pub fn serialize(self: *const InputCommand, allocator: std.mem.Allocator) ![]u8 {
        // Simple binary format:
        // [4 bytes playerId][4 bytes seq][8 bytes timestamp]
        // [1 byte actions][8 bytes aimX][8 bytes aimY]
        var buf = try allocator.alloc(u8, 33);
        // ... pack fields into buf ...
        return buf;
    }

    pub fn deserialize(data: []const u8) !InputCommand {
        // Unpack from binary format
        // ... extract fields from data ...
        return InputCommand{ ... };
    }
};

/// Packed boolean flags for efficient transmission
pub const ActionSet = packed struct {
    moveLeft: bool,
    moveRight: bool,
    jump: bool,
    shoot: bool,
    _padding: u4 = 0,  // Pad to 1 byte
};

/// Global input queue (will be consumed each frame)
pub var inputQueue: std.ArrayList(InputCommand) = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    inputQueue = std.ArrayList(InputCommand).init(allocator);
}

pub fn deinit() void {
    inputQueue.deinit();
}

pub fn queueInput(cmd: InputCommand) !void {
    try inputQueue.append(cmd);
}

pub fn consumeInputs() []InputCommand {
    const items = inputQueue.items;
    inputQueue.clearRetainingCapacity();
    return items;
}
```

**Modify:** `src/control.zig`

```zig
// OLD (direct execution):
pub fn executeAction(playerId: usize, action: controller.GameAction) void {
    const maybePlayer = player.players.getPtr(playerId);
    if (maybePlayer) |p| {
        switch (action) {
            .move_left => player.moveLeft(p),
            .move_right => player.moveRight(p),
            .jump => player.jump(p),
            .shoot => player.shoot(p),
            else => {},
        }
    }
}

// NEW (queue for processing):
const input_command = @import("input_command.zig");

var currentSequenceNumber: u32 = 0;
var currentActionSet: input_command.ActionSet = .{
    .moveLeft = false,
    .moveRight = false,
    .jump = false,
    .shoot = false,
};
var currentAimDirection: vec.Vec2 = .{ .x = 0, .y = 0 };

pub fn executeAction(playerId: usize, action: controller.GameAction) void {
    // Update action set
    switch (action) {
        .move_left => currentActionSet.moveLeft = true,
        .move_right => currentActionSet.moveRight = true,
        .jump => currentActionSet.jump = true,
        .shoot => currentActionSet.shoot = true,
        else => {},
    }
}

pub fn executeAim(playerId: usize, direction: vec.Vec2) void {
    currentAimDirection = direction;
}

pub fn flushInputCommand(playerId: usize) !void {
    currentSequenceNumber += 1;
    const cmd = input_command.InputCommand{
        .playerId = playerId,
        .sequenceNumber = currentSequenceNumber,
        .timestamp = time.now(),
        .actions = currentActionSet,
        .aimDirection = currentAimDirection,
    };
    try input_command.queueInput(cmd);

    // Reset for next frame
    currentActionSet = .{
        .moveLeft = false,
        .moveRight = false,
        .jump = false,
        .shoot = false,
    };
}
```

**Modify:** `src/player.zig`

Add new function to apply commands deterministically:

```zig
pub fn applyInputCommand(p: *Player, cmd: input_command.InputCommand) void {
    // Apply movement
    if (cmd.actions.moveLeft) {
        moveLeft(p);
    }
    if (cmd.actions.moveRight) {
        moveRight(p);
    }
    if (cmd.actions.jump) {
        jump(p);
    }

    // Apply aim
    aim(p, cmd.aimDirection);

    // Apply shoot
    if (cmd.actions.shoot) {
        shoot(p);
    }
}
```

**Modify:** `src/main.zig`

```zig
pub fn main() !void {
    // ... existing init ...

    try input_command.init(allocator);
    defer input_command.deinit();

    // ... game loop ...
}

fn gameLoop() !void {
    // ... existing logic ...

    // NEW: Flush accumulated inputs into queue
    for (controller.controllers.keys()) |controllerId| {
        const ctrl = controller.controllers.get(controllerId);
        try control.flushInputCommand(ctrl.playerId);
    }

    // NEW: Process all queued inputs
    const inputs = input_command.consumeInputs();
    for (inputs) |cmd| {
        const maybePlayer = player.players.getPtr(cmd.playerId);
        if (maybePlayer) |p| {
            player.applyInputCommand(p, cmd);
        }
    }

    // ... rest of game loop ...
}
```

**Testing:**
- [ ] Game still plays identically
- [ ] Input feels the same
- [ ] Can print command queue to verify commands are created
- [ ] No crashes or memory leaks

---

#### Step 1.2: Centralize Game State

**New file:** `src/game_state.zig`

```zig
const std = @import("std");
const vec = @import("vector.zig");
const box2d = @import("box2d.zig");

pub const GameState = struct {
    tick: u64,
    players: []PlayerState,
    // For now, keep it simple - add entities/particles later

    pub fn init(allocator: std.mem.Allocator) !GameState {
        return GameState{
            .tick = 0,
            .players = &[_]PlayerState{},
        };
    }

    pub fn deinit(self: *GameState, allocator: std.mem.Allocator) void {
        allocator.free(self.players);
    }

    pub fn serialize(self: *const GameState, allocator: std.mem.Allocator) ![]u8 {
        // Binary format for now
        // Later: migrate to FlatBuffers
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try buf.writer().writeInt(u64, self.tick, .little);
        try buf.writer().writeInt(u32, @intCast(self.players.len), .little);

        for (self.players) |p| {
            try p.serialize(buf.writer());
        }

        return try buf.toOwnedSlice();
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !GameState {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        const tick = try reader.readInt(u64, .little);
        const playerCount = try reader.readInt(u32, .little);

        var players = try allocator.alloc(PlayerState, playerCount);
        for (players) |*p| {
            p.* = try PlayerState.deserialize(reader);
        }

        return GameState{
            .tick = tick,
            .players = players,
        };
    }
};

pub const PlayerState = struct {
    id: usize,
    position: vec.Vec2,
    velocity: vec.Vec2,
    rotation: f32,
    health: f32,
    aimDirection: vec.Vec2,
    animationState: u8,  // 0=idle, 1=run, 2=jump, etc.
    weaponIndex: usize,
    grounded: bool,

    pub fn fromPlayer(p: *const player.Player) PlayerState {
        const state = box2d.getState(p.bodyId);
        return PlayerState{
            .id = p.id,
            .position = vec.fromBox2d(state.pos),
            .velocity = vec.fromBox2d(state.linearVelocity),
            .rotation = state.rotAngle,
            .health = p.health,
            .aimDirection = p.aimDirection,
            .animationState = determineAnimationState(p),
            .weaponIndex = 0,  // TODO: get from weapon system
            .grounded = p.footContactCount > 0,
        };
    }

    fn determineAnimationState(p: *const player.Player) u8 {
        // Map current animation to numeric state
        // This is simplified - expand as needed
        if (p.footContactCount == 0) return 2; // jumping
        const vel = box2d.c.b2Body_GetLinearVelocity(p.bodyId);
        if (@abs(vel.x) > 0.1) return 1; // running
        return 0; // idle
    }

    pub fn serialize(self: *const PlayerState, writer: anytype) !void {
        try writer.writeInt(u64, self.id, .little);
        try writer.writeAll(std.mem.asBytes(&self.position));
        try writer.writeAll(std.mem.asBytes(&self.velocity));
        try writer.writeAll(std.mem.asBytes(&self.rotation));
        try writer.writeAll(std.mem.asBytes(&self.health));
        try writer.writeAll(std.mem.asBytes(&self.aimDirection));
        try writer.writeInt(u8, self.animationState, .little);
        try writer.writeInt(u64, self.weaponIndex, .little);
        try writer.writeInt(u8, if (self.grounded) 1 else 0, .little);
    }

    pub fn deserialize(reader: anytype) !PlayerState {
        return PlayerState{
            .id = try reader.readInt(u64, .little),
            .position = @bitCast(try reader.readBytesNoEof(8)),
            .velocity = @bitCast(try reader.readBytesNoEof(8)),
            .rotation = @bitCast(try reader.readBytesNoEof(4)),
            .health = @bitCast(try reader.readBytesNoEof(4)),
            .aimDirection = @bitCast(try reader.readBytesNoEof(8)),
            .animationState = try reader.readInt(u8, .little),
            .weaponIndex = try reader.readInt(u64, .little),
            .grounded = (try reader.readInt(u8, .little)) != 0,
        };
    }
};

pub var currentGameState: GameState = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    currentGameState = try GameState.init(allocator);
}

pub fn updateFromSimulation(allocator: std.mem.Allocator) !void {
    // Free old player list
    if (currentGameState.players.len > 0) {
        allocator.free(currentGameState.players);
    }

    // Capture current state from player system
    const playerCount = player.players.count();
    currentGameState.players = try allocator.alloc(PlayerState, playerCount);

    var i: usize = 0;
    var iter = player.players.iterator();
    while (iter.next()) |entry| {
        currentGameState.players[i] = PlayerState.fromPlayer(entry.value_ptr);
        i += 1;
    }

    currentGameState.tick += 1;
}
```

**Modify:** `src/main.zig`

```zig
const game_state = @import("game_state.zig");

pub fn main() !void {
    // ... init ...

    try game_state.init(allocator);

    // ... game loop ...
}

fn gameLoop() !void {
    // ... existing logic ...

    // At end of game loop:
    try game_state.updateFromSimulation(allocator);
}
```

**Testing:**
- [ ] GameState correctly mirrors player state
- [ ] Serialization round-trip works (serialize → deserialize → compare)
- [ ] No memory leaks
- [ ] Game still runs normally

---

#### Step 1.3: Separate Simulation from Rendering

**Modify:** `src/main.zig`

Extract simulation into dedicated function:

```zig
fn simulationStep() !void {
    // Fixed timestep physics
    try physics.step();

    // Process inputs
    try input.handle();

    // Flush inputs to command queue
    for (controller.controllers.keys()) |controllerId| {
        const ctrl = controller.controllers.get(controllerId);
        try control.flushInputCommand(ctrl.playerId);
    }

    // Apply commands to simulation
    const inputs = input_command.consumeInputs();
    for (inputs) |cmd| {
        const maybePlayer = player.players.getPtr(cmd.playerId);
        if (maybePlayer) |p| {
            player.applyInputCommand(p, cmd);
        }
    }

    // Game logic
    try gameLoop();

    // Update centralized state
    try game_state.updateFromSimulation(allocator);
}

pub fn main() !void {
    // ... init ...

    while (!shared.quitGame) {
        time.frameBegin();

        // SIMULATION (fixed rate)
        try simulationStep();

        // RENDERING (variable rate)
        try renderer.render();

        time.frameEnd();
    }
}
```

**Benefits:**
- Clear separation of concerns
- Easy to disable rendering for headless server
- Simulation can run at different rate than rendering

**Testing:**
- [ ] Game runs at same speed
- [ ] Physics is still deterministic
- [ ] Rendering is smooth

---

#### Step 1.4: Design Network Protocol

**New file:** `src/network/protocol.zig`

```zig
const std = @import("std");
const input_command = @import("../input_command.zig");
const game_state = @import("../game_state.zig");

pub const MessageType = enum(u8) {
    // Client → Server
    client_hello = 1,
    client_input = 2,
    client_ready = 3,
    client_disconnect = 4,

    // Server → Client
    server_welcome = 10,
    server_snapshot = 11,
    server_player_joined = 12,
    server_player_left = 13,
    server_game_start = 14,
    server_kick = 15,
};

/// Client sends this when first connecting
pub const ClientHelloMessage = struct {
    playerName: [32]u8,
    version: u32,

    pub fn serialize(self: *const ClientHelloMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 1 + 32 + 4);
        buf[0] = @intFromEnum(MessageType.client_hello);
        @memcpy(buf[1..33], &self.playerName);
        std.mem.writeInt(u32, buf[33..37], self.version, .little);
        return buf;
    }

    pub fn deserialize(data: []const u8) !ClientHelloMessage {
        if (data.len < 37) return error.InvalidMessage;
        return ClientHelloMessage{
            .playerName = data[1..33][0..32].*,
            .version = std.mem.readInt(u32, data[33..37], .little),
        };
    }
};

/// Server responds with assigned player ID
pub const ServerWelcomeMessage = struct {
    assignedPlayerId: usize,
    serverTick: u64,

    pub fn serialize(self: *const ServerWelcomeMessage, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 1 + 8 + 8);
        buf[0] = @intFromEnum(MessageType.server_welcome);
        std.mem.writeInt(u64, buf[1..9], self.assignedPlayerId, .little);
        std.mem.writeInt(u64, buf[9..17], self.serverTick, .little);
        return buf;
    }

    pub fn deserialize(data: []const u8) !ServerWelcomeMessage {
        if (data.len < 17) return error.InvalidMessage;
        return ServerWelcomeMessage{
            .assignedPlayerId = std.mem.readInt(u64, data[1..9], .little),
            .serverTick = std.mem.readInt(u64, data[9..17], .little),
        };
    }
};

/// Client sends inputs to server
pub const ClientInputMessage = struct {
    sequenceNumber: u32,
    command: input_command.InputCommand,

    pub fn serialize(self: *const ClientInputMessage, allocator: std.mem.Allocator) ![]u8 {
        const cmdBytes = try self.command.serialize(allocator);
        defer allocator.free(cmdBytes);

        var buf = try allocator.alloc(u8, 1 + 4 + cmdBytes.len);
        buf[0] = @intFromEnum(MessageType.client_input);
        std.mem.writeInt(u32, buf[1..5], self.sequenceNumber, .little);
        @memcpy(buf[5..], cmdBytes);
        return buf;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ClientInputMessage {
        _ = allocator;
        if (data.len < 5) return error.InvalidMessage;
        return ClientInputMessage{
            .sequenceNumber = std.mem.readInt(u32, data[1..5], .little),
            .command = try input_command.InputCommand.deserialize(data[5..]),
        };
    }
};

/// Server sends game state to clients
pub const ServerSnapshotMessage = struct {
    tick: u64,
    lastAcknowledgedInput: u32,  // Per-client, will be set before sending
    gameState: game_state.GameState,

    pub fn serialize(self: *const ServerSnapshotMessage, allocator: std.mem.Allocator) ![]u8 {
        const stateBytes = try self.gameState.serialize(allocator);
        defer allocator.free(stateBytes);

        var buf = try allocator.alloc(u8, 1 + 8 + 4 + stateBytes.len);
        buf[0] = @intFromEnum(MessageType.server_snapshot);
        std.mem.writeInt(u64, buf[1..9], self.tick, .little);
        std.mem.writeInt(u32, buf[9..13], self.lastAcknowledgedInput, .little);
        @memcpy(buf[13..], stateBytes);
        return buf;
    }

    pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) !ServerSnapshotMessage {
        if (data.len < 13) return error.InvalidMessage;
        return ServerSnapshotMessage{
            .tick = std.mem.readInt(u64, data[1..9], .little),
            .lastAcknowledgedInput = std.mem.readInt(u32, data[9..13], .little),
            .gameState = try game_state.GameState.deserialize(data[13..], allocator),
        };
    }
};

/// Helper to parse message type from raw bytes
pub fn parseMessageType(data: []const u8) !MessageType {
    if (data.len < 1) return error.InvalidMessage;
    return @enumFromInt(data[0]);
}
```

**Testing:**
- [ ] Write unit tests for each message type
- [ ] Verify serialize → deserialize → compare
- [ ] Test with invalid data (error handling)
- [ ] Measure serialized sizes

---

### PHASE 2: Network Foundation (Localhost)

**Duration:** 1 week
**Goal:** Basic client-server communication on same machine

#### Step 2.1: Add ENet Dependency

**Option A: Build from source**

Download ENet source and add to project:

```bash
cd /Users/horttanainen/projects/multi
mkdir -p external/enet
cd external/enet
# Download from: http://enet.bespin.org/Downloads.html
# Extract enet-1.3.18.tar.gz here
```

**Modify:** `build.zig`

```zig
const enet = b.addStaticLibrary(.{
    .name = "enet",
    .target = target,
    .optimize = optimize,
});

enet.addCSourceFiles(.{
    .files = &[_][]const u8{
        "external/enet/callbacks.c",
        "external/enet/compress.c",
        "external/enet/host.c",
        "external/enet/list.c",
        "external/enet/packet.c",
        "external/enet/peer.c",
        "external/enet/protocol.c",
        "external/enet/unix.c",  // or "win32.c" on Windows
    },
    .flags = &[_][]const u8{},
});
enet.addIncludePath(.{ .path = "external/enet/include" });
enet.linkLibC();

exe.linkLibrary(enet);
exe.addIncludePath(.{ .path = "external/enet/include" });
```

**Testing:**
- [ ] Project builds successfully
- [ ] Can include enet.h in Zig code

---

#### Step 2.2: Create Network Module

**New file:** `src/network/network.zig`

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("enet/enet.h");
});

pub const NetworkMode = enum {
    none,
    server,
    client,
};

pub const NetworkManager = struct {
    mode: NetworkMode,
    host: ?*c.ENetHost,
    serverPeer: ?*c.ENetPeer,      // For client: connection to server
    clientPeers: [4]?*c.ENetPeer,  // For server: connected clients
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, mode: NetworkMode, port: u16) !NetworkManager {
        if (c.enet_initialize() != 0) {
            return error.ENetInitFailed;
        }

        var mgr = NetworkManager{
            .mode = mode,
            .host = null,
            .serverPeer = null,
            .clientPeers = [_]?*c.ENetPeer{null} ** 4,
            .allocator = allocator,
        };

        switch (mode) {
            .server => {
                var address: c.ENetAddress = undefined;
                address.host = c.ENET_HOST_ANY;
                address.port = port;

                mgr.host = c.enet_host_create(&address, 4, 2, 0, 0);
                if (mgr.host == null) {
                    return error.ServerCreateFailed;
                }
                std.debug.print("Server listening on port {}\n", .{port});
            },
            .client => {
                mgr.host = c.enet_host_create(null, 1, 2, 0, 0);
                if (mgr.host == null) {
                    return error.ClientCreateFailed;
                }
                std.debug.print("Client initialized\n", .{});
            },
            .none => {},
        }

        return mgr;
    }

    pub fn deinit(self: *NetworkManager) void {
        if (self.host) |host| {
            c.enet_host_destroy(host);
        }
        c.enet_deinitialize();
    }

    pub fn connectToServer(self: *NetworkManager, address: []const u8, port: u16) !void {
        if (self.mode != .client) return error.NotAClient;

        var serverAddress: c.ENetAddress = undefined;
        const addressZ = try self.allocator.dupeZ(u8, address);
        defer self.allocator.free(addressZ);

        if (c.enet_address_set_host(&serverAddress, addressZ) != 0) {
            return error.InvalidAddress;
        }
        serverAddress.port = port;

        self.serverPeer = c.enet_host_connect(self.host.?, &serverAddress, 2, 0);
        if (self.serverPeer == null) {
            return error.ConnectionFailed;
        }

        std.debug.print("Connecting to {}:{}...\n", .{address, port});
    }

    pub fn sendReliable(self: *NetworkManager, peerId: ?usize, data: []const u8) !void {
        const packet = c.enet_packet_create(data.ptr, data.len, c.ENET_PACKET_FLAG_RELIABLE);
        if (packet == null) return error.PacketCreateFailed;

        switch (self.mode) {
            .client => {
                if (self.serverPeer) |peer| {
                    _ = c.enet_peer_send(peer, 0, packet);
                }
            },
            .server => {
                if (peerId) |id| {
                    if (self.clientPeers[id]) |peer| {
                        _ = c.enet_peer_send(peer, 0, packet);
                    }
                } else {
                    // Broadcast to all clients
                    c.enet_host_broadcast(self.host.?, 0, packet);
                }
            },
            .none => {},
        }
    }

    pub fn sendUnreliable(self: *NetworkManager, peerId: ?usize, data: []const u8) !void {
        const packet = c.enet_packet_create(data.ptr, data.len, 0);
        if (packet == null) return error.PacketCreateFailed;

        switch (self.mode) {
            .client => {
                if (self.serverPeer) |peer| {
                    _ = c.enet_peer_send(peer, 0, packet);
                }
            },
            .server => {
                if (peerId) |id| {
                    if (self.clientPeers[id]) |peer| {
                        _ = c.enet_peer_send(peer, 0, packet);
                    }
                } else {
                    c.enet_host_broadcast(self.host.?, 0, packet);
                }
            },
            .none => {},
        }
    }

    pub fn poll(self: *NetworkManager, timeout_ms: u32) ![]NetworkEvent {
        var events = std.ArrayList(NetworkEvent).init(self.allocator);

        var event: c.ENetEvent = undefined;
        const result = c.enet_host_service(self.host.?, &event, timeout_ms);

        if (result > 0) {
            switch (event.type) {
                c.ENET_EVENT_TYPE_CONNECT => {
                    if (self.mode == .server) {
                        // Find free slot for client
                        for (&self.clientPeers, 0..) |*slot, i| {
                            if (slot.* == null) {
                                slot.* = event.peer;
                                try events.append(.{ .connect = .{ .peerId = i } });
                                break;
                            }
                        }
                    } else {
                        try events.append(.{ .connect = .{ .peerId = 0 } });
                    }
                },
                c.ENET_EVENT_TYPE_DISCONNECT => {
                    if (self.mode == .server) {
                        for (&self.clientPeers, 0..) |*slot, i| {
                            if (slot.* == event.peer) {
                                slot.* = null;
                                try events.append(.{ .disconnect = .{ .peerId = i } });
                                break;
                            }
                        }
                    } else {
                        try events.append(.{ .disconnect = .{ .peerId = 0 } });
                    }
                },
                c.ENET_EVENT_TYPE_RECEIVE => {
                    const data = event.packet.*.data[0..event.packet.*.dataLength];
                    const dataCopy = try self.allocator.dupe(u8, data);

                    if (self.mode == .server) {
                        for (self.clientPeers, 0..) |peer, i| {
                            if (peer == event.peer) {
                                try events.append(.{ .receive = .{ .peerId = i, .data = dataCopy } });
                                break;
                            }
                        }
                    } else {
                        try events.append(.{ .receive = .{ .peerId = 0, .data = dataCopy } });
                    }

                    c.enet_packet_destroy(event.packet);
                },
                else => {},
            }
        }

        return try events.toOwnedSlice();
    }
};

pub const NetworkEvent = union(enum) {
    connect: struct { peerId: usize },
    disconnect: struct { peerId: usize },
    receive: struct { peerId: usize, data: []const u8 },
};
```

**Testing:**
- [ ] Create simple echo test (server echoes back messages)
- [ ] Test connection/disconnection
- [ ] Test reliable vs unreliable delivery
- [ ] Test broadcast

---

#### Step 2.3: Modify Main Loop for Networking

**Modify:** `src/main.zig`

```zig
const network = @import("network/network.zig");

pub var networkMode: network.NetworkMode = .none;
pub var networkManager: ?network.NetworkManager = null;

pub fn main() !void {
    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for network mode flags
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--server")) {
            networkMode = .server;
        } else if (std.mem.eql(u8, args[1], "--client")) {
            networkMode = .client;
        }
    }

    // Initialize network if needed
    if (networkMode != .none) {
        const port: u16 = 7777;
        networkManager = try network.NetworkManager.init(allocator, networkMode, port);
        std.debug.print("Network mode: {}\n", .{networkMode});
    }
    defer if (networkManager) |*nm| nm.deinit();

    // ... rest of initialization ...

    try camera.spawn(.{ .x = 0, .y = 0 });
    try level.next();
    defer level.cleanup();
    defer particle.cleanup();
    defer levelEditor.cleanup() catch |err| {
        std.debug.print("Error cleaning up created level folders: {}\n", .{err});
    };

    box2d.c.b2World_SetFrictionCallback(resources.worldId, &friction.callback);

    while (!shared.quitGame) {
        time.frameBegin();

        // Process network events
        if (networkManager) |*nm| {
            try processNetworkEvents(nm);
        }

        try physics.step();

        try input.handle();

        if (shared.editingLevel) {
            levelEditorLoop();
        } else {
            try gameLoop();
        }

        try renderer.render();

        time.frameEnd();
    }
}

fn processNetworkEvents(nm: *network.NetworkManager) !void {
    const events = try nm.poll(0);  // Non-blocking
    defer {
        for (events) |event| {
            if (event == .receive) {
                allocator.free(event.receive.data);
            }
        }
        allocator.free(events);
    }

    for (events) |event| {
        switch (event) {
            .connect => |info| {
                std.debug.print("Player {} connected\n", .{info.peerId});
            },
            .disconnect => |info| {
                std.debug.print("Player {} disconnected\n", .{info.peerId});
            },
            .receive => |info| {
                try handleNetworkMessage(info.peerId, info.data);
            },
        }
    }
}

fn handleNetworkMessage(peerId: usize, data: []const u8) !void {
    // For now, just echo back
    std.debug.print("Received {} bytes from peer {}\n", .{data.len, peerId});

    if (networkManager) |*nm| {
        try nm.sendReliable(peerId, data);
    }
}
```

**Testing:**
- [ ] Start server: `./zig-out/bin/multi --server`
- [ ] Start client: `./zig-out/bin/multi --client` (add connect logic)
- [ ] Verify connection established
- [ ] Network events are processed
- [ ] Game still runs in local mode without flags

---

#### Step 2.4: Client-Server Handshake

**New file:** `src/network/connection.zig`

```zig
const std = @import("std");
const network = @import("network.zig");
const protocol = @import("protocol.zig");

pub fn connectToServer(nm: *network.NetworkManager, address: []const u8, port: u16, playerName: []const u8) !usize {
    // Connect via ENet
    try nm.connectToServer(address, port);

    // Wait for connection event (blocking with timeout)
    const timeout_ms = 5000;
    var elapsed: u32 = 0;
    var connected = false;

    while (elapsed < timeout_ms) {
        const events = try nm.poll(100);
        defer {
            for (events) |event| {
                if (event == .receive) {
                    nm.allocator.free(event.receive.data);
                }
            }
            nm.allocator.free(events);
        }

        for (events) |event| {
            if (event == .connect) {
                connected = true;
                break;
            }
        }

        if (connected) break;
        elapsed += 100;
    }

    if (!connected) {
        return error.ConnectionTimeout;
    }

    // Send hello message
    var nameBytes: [32]u8 = [_]u8{0} ** 32;
    @memcpy(nameBytes[0..@min(playerName.len, 32)], playerName[0..@min(playerName.len, 32)]);

    const hello = protocol.ClientHelloMessage{
        .playerName = nameBytes,
        .version = 1,
    };

    const helloBytes = try hello.serialize(nm.allocator);
    defer nm.allocator.free(helloBytes);
    try nm.sendReliable(null, helloBytes);

    // Wait for welcome message
    elapsed = 0;
    while (elapsed < timeout_ms) {
        const events = try nm.poll(100);
        defer {
            for (events) |event| {
                if (event == .receive) {
                    nm.allocator.free(event.receive.data);
                }
            }
            nm.allocator.free(events);
        }

        for (events) |event| {
            if (event == .receive) {
                const msgType = try protocol.parseMessageType(event.receive.data);
                if (msgType == .server_welcome) {
                    const welcome = try protocol.ServerWelcomeMessage.deserialize(event.receive.data);
                    std.debug.print("Assigned player ID: {}\n", .{welcome.assignedPlayerId});
                    return welcome.assignedPlayerId;
                }
            }
        }

        elapsed += 100;
    }

    return error.WelcomeTimeout;
}

pub fn onClientConnected(nm: *network.NetworkManager, peerId: usize, allocator: std.mem.Allocator) !void {
    _ = nm;
    _ = peerId;
    _ = allocator;
    // Will implement in Phase 3 (server implementation)
    // For now, server just waits for hello message
}
```

**Testing:**
- [ ] Client connects and receives player ID
- [ ] Server assigns unique player IDs
- [ ] Timeout works if server unavailable
- [ ] Connection gracefully fails on error

---

### PHASE 3-6: Continued in Next Session

The remaining phases (Server Implementation, Client Implementation, Testing, LAN Migration) follow the same pattern and will be documented when we continue implementation.

**Key files still to create:**
- `src/network/server.zig` - Server game loop
- `src/network/client.zig` - Client with prediction
- `src/network/latency_simulator.zig` - Testing tools
- `src/network/discovery.zig` - LAN server browser

---

## Technical Specifications

### Network Performance Targets

```
Bandwidth per client:  < 100 Kbps
Server tick rate:      60 Hz
Network send rate:     20-30 Hz
Max players:           2-4 (initial), 8+ (future)
Target latency:        < 150ms RTT
Acceptable packet loss: < 5%
```

### Message Sizes (Estimated)

```
ClientInputMessage:     ~40 bytes
ServerSnapshotMessage:  ~300 bytes (2 players)
ClientHelloMessage:     ~40 bytes
ServerWelcomeMessage:   ~20 bytes
```

### Performance Budget

```
Server CPU per tick:  < 16ms (leave headroom)
Client prediction:    < 1ms
Serialization:        < 0.5ms
Deserialization:      < 0.1ms (with FlatBuffers)
```

---

## Risk Analysis

### High Risk Items

1. **Box2D Non-Determinism**
   - **Risk:** Physics may diverge between client prediction and server
   - **Mitigation:** Only predict simple player movement, interpolate everything else
   - **Fallback:** Remove client prediction, accept latency

2. **Network Jitter**
   - **Risk:** Packet arrival time varies, causing stutter
   - **Mitigation:** Interpolation buffer (100ms), extrapolation for missing packets
   - **Fallback:** Increase buffer size

3. **Bandwidth Constraints**
   - **Risk:** Home internet upload limited (especially server host)
   - **Mitigation:** Delta compression, entity relevance filtering
   - **Fallback:** Reduce tick rate to 15 Hz

### Medium Risk Items

4. **NAT Traversal** (Phase 6)
   - **Risk:** Players can't connect through routers
   - **Mitigation:** Port forwarding instructions, UPnP, STUN
   - **Fallback:** Dedicated server only (no player hosting)

5. **Cheating**
   - **Risk:** Client modifies game state
   - **Mitigation:** Server authority, input validation
   - **Fallback:** Trusted players only (friends)

6. **Complexity Creep**
   - **Risk:** Implementation takes longer than expected
   - **Mitigation:** Incremental phases, frequent testing
   - **Fallback:** Stop at "dumb terminal" client (Phase 4.1)

### Low Risk Items

7. **ENet Integration**
   - **Risk:** Build issues, platform compatibility
   - **Mitigation:** Well-documented library, fallback to raw UDP
   - **Likely:** Should be straightforward

---

## Next Steps

### Immediate Actions (Today/Tomorrow)

1. **Verify Box2D Version**
   ```bash
   grep -r "VERSION" box2d/include/
   # Check if we have 3.1+ for determinism
   ```

2. **Set Up Development Environment**
   - Create `docs/` directory (done)
   - Create `src/network/` directory
   - Download ENet source

3. **Create Test Plan**
   - Write test cases for Phase 1
   - Set up automated testing framework
   - Create checklist for each phase

### Week 1: Phase 1 Implementation

- [ ] Day 1-2: Input command system (Step 1.1)
- [ ] Day 3-4: Centralized game state (Step 1.2)
- [ ] Day 5: Separate simulation from rendering (Step 1.3)
- [ ] Day 6-7: Network protocol design (Step 1.4)

**Success Criteria:**
- Game still works identically in local mode
- Input queue system functional
- GameState serialization working
- Protocol documented and tested

### Week 2: Phase 2 Implementation

- [ ] Day 1: Add ENet dependency (Step 2.1)
- [ ] Day 2-3: Create network module (Step 2.2)
- [ ] Day 4: Modify main loop (Step 2.3)
- [ ] Day 5-7: Client-server handshake (Step 2.4)

**Success Criteria:**
- Can start game in --server or --client mode
- Client connects to localhost server
- Basic message exchange working

---

## Research References

### Essential Reading

1. **Valve's Source Engine Networking**
   - https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking
   - https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization

2. **Gabriel Gambetta's Articles**
   - https://www.gabrielgambetta.com/client-side-prediction-server-reconciliation.html
   - https://www.gabrielgambetta.com/client-server-game-architecture.html

3. **Gaffer on Games**
   - https://gafferongames.com/post/udp_vs_tcp/
   - https://gafferongames.com/post/snapshot_interpolation/
   - https://gafferongames.com/post/introduction_to_networked_physics/

4. **Box2D Determinism**
   - https://box2d.org/posts/2024/08/determinism/

### Tools & Libraries

- **ENet:** http://enet.bespin.org/
- **FlatBuffers:** https://github.com/google/flatbuffers
- **Valve GameNetworkingSockets:** https://github.com/ValveSoftware/GameNetworkingSockets

### Game Networking Community

- **Glenn Fiedler's Blog:** https://gafferongames.com/
- **Snapnet (open source networking):** https://github.com/benanders/snapnet
- **Game Networking Demystified Series:** https://ruoyusun.com/2019/03/28/game-networking-1.html

---

## Appendix: File Structure

```
/Users/horttanainen/projects/multi/
├── src/
│   ├── main.zig                      [MODIFY: Add network mode]
│   ├── input_command.zig             [NEW: Input abstraction]
│   ├── game_state.zig                [NEW: Centralized state]
│   ├── control.zig                   [MODIFY: Queue inputs]
│   ├── player.zig                    [MODIFY: Add applyInputCommand]
│   ├── renderer.zig                  [MODIFY: Render from GameState]
│   └── network/
│       ├── network.zig               [NEW: ENet wrapper]
│       ├── protocol.zig              [NEW: Message definitions]
│       ├── server.zig                [NEW: Server implementation]
│       ├── client.zig                [NEW: Client implementation]
│       ├── connection.zig            [NEW: Handshake logic]
│       ├── latency_simulator.zig    [NEW: Testing tools]
│       ├── debug.zig                 [NEW: Debug visualization]
│       └── discovery.zig             [NEW: LAN server browser]
├── docs/
│   └── MULTIPLAYER_MIGRATION_PLAN.md [THIS FILE]
├── external/
│   └── enet/                         [NEW: ENet source]
└── build.zig                          [MODIFY: Add ENet]
```

---

## Status Tracking

**Last Updated:** 2026-01-03
**Current Phase:** Planning Complete
**Next Milestone:** Phase 1.1 - Input Command System

**Progress:**
- [x] Architecture Analysis
- [x] Industry Research
- [x] Migration Strategy Design
- [x] Documentation
- [ ] Phase 1 Implementation
- [ ] Phase 2 Implementation
- [ ] Phase 3 Implementation
- [ ] Phase 4 Implementation
- [ ] Phase 5 Testing
- [ ] Phase 6 LAN Migration

---

## Contact for Questions

When resuming this work, key questions to address:

1. **Box2D Version?** Check if we're on 3.1+ for determinism
2. **Player Count?** Final target 2, 4, or 8 players?
3. **Server Infrastructure?** Player-hosted or dedicated server preference?
4. **Platform Priority?** macOS only or cross-platform (Windows/Linux)?
5. **Timeline?** Aggressive (1 month) or relaxed (3+ months)?

---

**End of Migration Plan**
