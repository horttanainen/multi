const std = @import("std");

const box2d = @import("box2d.zig");
const config = @import("config.zig");
const conv = @import("conversion.zig");
const data = @import("data.zig");
const gibbing = @import("gibbing.zig");
const particle = @import("particle.zig");
const perf = @import("perf.zig");
const player = @import("player.zig");
const projectile = @import("projectile.zig");
const state = @import("state.zig");
const tex = @import("texture.zig");
const vec = @import("vector.zig");

pub const Scenario = enum {
    air_explosion,
    air_explosion_no_visual,
    air_death,
    ground_explosion,
    ground_explosion_no_visual,
    ground_death,
};

pub const Options = struct {
    enabled: bool = false,
    scenario: Scenario = .ground_death,
    event_count: u32 = 3,
};

const CounterSnapshot = struct {
    particle_bodies: u64,
    giblet_bodies: u64,
    giblet_recycles: u64,
    texture_migrations: u64,
    texture_migration_bytes: u64,
};

const maximumGroundEvents: u32 = 3;
const warmupFrameCount: u32 = 30;
const betweenEventFrameCount: u32 = 30;
const benchmarkLevelPath = "levels/perf_explosion_ground.json";

pub var options: Options = .{};

var framesUntilTrigger: u32 = warmupFrameCount;
var eventIndex: u32 = 0;
var waitingForCapture = false;
var eventCounters: CounterSnapshot = undefined;
var triggerCounters: CounterSnapshot = undefined;
var eventTriggerUs: u64 = 0;

fn scenarioFromName(name: []const u8) !Scenario {
    if (std.mem.eql(u8, name, "air-explosion")) return .air_explosion;
    if (std.mem.eql(u8, name, "air-explosion-no-visual")) return .air_explosion_no_visual;
    if (std.mem.eql(u8, name, "air-death")) return .air_death;
    if (std.mem.eql(u8, name, "ground-explosion")) return .ground_explosion;
    if (std.mem.eql(u8, name, "ground-explosion-no-visual")) return .ground_explosion_no_visual;
    if (std.mem.eql(u8, name, "ground-death")) return .ground_death;

    std.log.err("explosion_benchmark.scenarioFromName: unknown scenario '{s}'", .{name});
    return error.InvalidExplosionBenchmarkScenario;
}

fn scenarioName(scenario: Scenario) []const u8 {
    return switch (scenario) {
        .air_explosion => "air-explosion",
        .air_explosion_no_visual => "air-explosion-no-visual",
        .air_death => "air-death",
        .ground_explosion => "ground-explosion",
        .ground_explosion_no_visual => "ground-explosion-no-visual",
        .ground_death => "ground-death",
    };
}

fn optionValue(args: []const []const u8, optionIndex: usize, optionName: []const u8) ![]const u8 {
    if (optionIndex + 1 >= args.len) {
        std.log.err("explosion_benchmark.optionValue: option '{s}' requires a value", .{optionName});
        return error.MissingExplosionBenchmarkOptionValue;
    }
    return args[optionIndex + 1];
}

pub fn configure(args: []const []const u8) !void {
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--explosion-benchmark")) {
            const value = try optionValue(args, index, arg);
            options.scenario = try scenarioFromName(value);
            options.enabled = true;
            index += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--events")) {
            const value = try optionValue(args, index, arg);
            options.event_count = std.fmt.parseUnsigned(u32, value, 10) catch |err| {
                std.log.err("explosion_benchmark.configure: invalid event count '{s}': {}", .{ value, err });
                return error.InvalidExplosionBenchmarkEventCount;
            };
            index += 2;
            continue;
        }
        index += 1;
    }

    if (!options.enabled) return;
    if (comptime !config.perf.explosion) {
        std.log.err("explosion_benchmark.configure: benchmark requires -Dexplosion-perf=true", .{});
        return error.ExplosionPerformanceInstrumentationDisabled;
    }
    if (options.event_count == 0) {
        std.log.err("explosion_benchmark.configure: event count must be positive", .{});
        return error.InvalidExplosionBenchmarkEventCount;
    }
    if (scenarioUsesGround(options.scenario) and options.event_count > maximumGroundEvents) {
        std.log.err("explosion_benchmark.configure: ground scenarios support at most {d} non-overlapping events", .{maximumGroundEvents});
        return error.TooManyExplosionBenchmarkEvents;
    }

    std.log.info(
        "perf.benchmark_config scenario={s} events={d} warmup_frames={d}",
        .{ scenarioName(options.scenario), options.event_count, warmupFrameCount },
    );
}

fn scenarioUsesGround(scenario: Scenario) bool {
    return scenario == .ground_explosion or scenario == .ground_explosion_no_visual or scenario == .ground_death;
}

fn scenarioDamagesPlayer(scenario: Scenario) bool {
    return scenario == .air_death or scenario == .ground_death;
}

fn scenarioUsesVisual(scenario: Scenario) bool {
    return scenario != .air_explosion_no_visual and scenario != .ground_explosion_no_visual;
}

pub fn levelPath() ?[]const u8 {
    if (!options.enabled) return null;
    return benchmarkLevelPath;
}

fn counterSnapshot() CounterSnapshot {
    return .{
        .particle_bodies = particle.bodyCreationCount,
        .giblet_bodies = gibbing.pooledBodyCreationCount,
        .giblet_recycles = gibbing.poolRecycleCount,
        .texture_migrations = tex.fullMigrationCount,
        .texture_migration_bytes = tex.fullMigrationBytes,
    };
}

fn groundTarget(event: u32) vec.Vec2 {
    const imagePixelX: i32 = 350 + @as(i32, @intCast(event)) * 500;
    const imagePixelY: i32 = 2000;
    const imageCenter: i32 = 1024;
    const terrainScale: i32 = 2;
    return conv.pixel2M(.{
        .x = (imagePixelX - imageCenter) * terrainScale,
        .y = (imagePixelY - imageCenter) * terrainScale,
    });
}

fn eventTarget() vec.Vec2 {
    if (!scenarioUsesGround(options.scenario)) {
        return .{ .x = 0, .y = -35 };
    }
    return groundTarget(eventIndex);
}

fn positionPlayer(playerId: usize, bodyPosition: vec.Vec2) !void {
    const benchmarkPlayer = player.players.get(playerId) orelse {
        std.log.err("explosion_benchmark.positionPlayer: player {d} is missing", .{playerId});
        return error.ExplosionBenchmarkPlayerMissing;
    };
    if (!box2d.c.b2Body_IsValid(benchmarkPlayer.bodyId)) {
        std.log.err("explosion_benchmark.positionPlayer: player {d} body is invalid", .{playerId});
        return error.ExplosionBenchmarkPlayerBodyInvalid;
    }

    box2d.c.b2Body_SetTransform(
        benchmarkPlayer.bodyId,
        vec.toBox2d(bodyPosition),
        box2d.c.b2Body_GetRotation(benchmarkPlayer.bodyId),
    );
    box2d.c.b2Body_SetLinearVelocity(benchmarkPlayer.bodyId, box2d.c.b2Vec2_zero);
    box2d.c.b2Body_SetAngularVelocity(benchmarkPlayer.bodyId, 0);
}

fn prepareVictim(victimId: usize, attackerId: usize, maximumDamage: f32) !void {
    const victim = player.players.getPtr(victimId) orelse {
        std.log.err("explosion_benchmark.prepareVictim: victim player {d} is missing", .{victimId});
        return error.ExplosionBenchmarkPlayerMissing;
    };
    const guaranteedGibHealth = maximumDamage + player.gibHealthThreshold - 1.0;
    if (victim.health <= guaranteedGibHealth) return;

    const setupDamage = victim.health - guaranteedGibHealth;
    const setupResult = try player.damage(victimId, setupDamage, attackerId);
    if (!setupResult.applied or setupResult.fatal) {
        std.log.err("explosion_benchmark.prepareVictim: failed to prepare victim {d} for gibbing", .{victimId});
        return error.ExplosionBenchmarkVictimPreparationFailed;
    }
}

fn triggerEvent() !void {
    const attackerId: usize = 0;
    const victimId: usize = 1;
    const victim = player.players.get(victimId) orelse {
        std.log.err("explosion_benchmark.triggerEvent: victim player {d} is missing", .{victimId});
        return error.ExplosionBenchmarkPlayerMissing;
    };
    if (victim.isDead) return;

    var explosion = try data.createExplosionFrom("missile_explosion");
    if (!scenarioDamagesPlayer(options.scenario)) explosion.damagePlayers = false;
    if (!scenarioUsesVisual(options.scenario)) explosion.visual = null;

    const target = eventTarget();
    const victimBodyPosition = vec.subtract(target, player.centerOffset);
    try positionPlayer(victimId, victimBodyPosition);
    try positionPlayer(attackerId, vec.add(victimBodyPosition, .{ .x = -6, .y = 0 }));

    if (scenarioDamagesPlayer(options.scenario)) {
        try prepareVictim(victimId, attackerId, explosion.maximumDamage);
    }

    eventCounters = counterSnapshot();
    const triggerStart = perf.begin(.explosion);
    if (scenarioDamagesPlayer(options.scenario)) {
        try projectile.explodeAtDirectPlayer(target, explosion, attackerId, victimId);
    } else {
        try projectile.explodeAt(target, explosion, attackerId);
    }
    eventTriggerUs = perf.elapsedUs(triggerStart);
    triggerCounters = counterSnapshot();
    waitingForCapture = true;

    std.log.info(
        "perf.benchmark_event_begin scenario={s} event={d} cold={} target_x={d:.3} target_y={d:.3} trigger_us={d}",
        .{ scenarioName(options.scenario), eventIndex + 1, eventIndex == 0, target.x, target.y, eventTriggerUs },
    );
}

fn reportCompletedEvent() void {
    const counters = counterSnapshot();
    std.log.info(
        "perf.benchmark_event_end scenario={s} event={d} cold={} trigger_us={d} trigger_particle_bodies_created={d} trigger_giblet_bodies_created={d} trigger_giblet_pool_recycles={d} capture_particle_bodies_created={d} capture_giblet_bodies_created={d} capture_giblet_pool_recycles={d} texture_migrations={d} texture_migration_bytes={d}",
        .{
            scenarioName(options.scenario),
            eventIndex + 1,
            eventIndex == 0,
            eventTriggerUs,
            triggerCounters.particle_bodies - eventCounters.particle_bodies,
            triggerCounters.giblet_bodies - eventCounters.giblet_bodies,
            triggerCounters.giblet_recycles - eventCounters.giblet_recycles,
            counters.particle_bodies - eventCounters.particle_bodies,
            counters.giblet_bodies - eventCounters.giblet_bodies,
            counters.giblet_recycles - eventCounters.giblet_recycles,
            counters.texture_migrations - eventCounters.texture_migrations,
            counters.texture_migration_bytes - eventCounters.texture_migration_bytes,
        },
    );
}

pub fn update() !void {
    if (!options.enabled) return;

    if (waitingForCapture) {
        if (projectile.shouldCollectPerfFrameLog() or perf.playerDeathCaptureActive()) return;

        reportCompletedEvent();
        waitingForCapture = false;
        eventIndex += 1;
        if (eventIndex >= options.event_count) {
            std.log.info("perf.benchmark_complete scenario={s} events={d}", .{ scenarioName(options.scenario), eventIndex });
            state.quitGame = true;
            return;
        }
        framesUntilTrigger = betweenEventFrameCount;
        return;
    }

    if (framesUntilTrigger > 0) {
        framesUntilTrigger -= 1;
        return;
    }

    try triggerEvent();
}
