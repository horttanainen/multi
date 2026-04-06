const std = @import("std");

var session_seed: u64 = 0;
var reset_counter: u64 = 0;
var initialized: bool = false;
var fixed_seed_enabled: bool = false;
var fixed_seed_value: u64 = 0;

fn splitmix64(v: u64) u64 {
    var x = v +% 0x9E37_79B9_7F4A_7C15;
    x = (x ^ (x >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    x = (x ^ (x >> 27)) *% 0x94D0_49BB_1331_11EB;
    return x ^ (x >> 31);
}

fn normalizeFixedSeed(seed: u64) u64 {
    if (seed != 0) return seed;
    std.log.warn("music.entropy: fixed seed was zero, using fallback", .{});
    return 0xD1CE_BA5E_A11E_E001;
}

fn initRandomSessionSeed() void {
    session_seed = std.crypto.random.int(u64);
    if (session_seed == 0) {
        const ts: i64 = std.time.milliTimestamp();
        session_seed = @as(u64, @bitCast(ts));
        if (session_seed == 0) {
            // Keep zero as a reserved "invalid" value.
            session_seed = 0xD1CE_BA5E_A11E_E001;
        }
        std.log.warn("music.entropy: random seed was zero, using timestamp fallback", .{});
    }

    initialized = true;
    std.log.info("music.entropy: initialized session entropy", .{});
}

fn initFixedSessionSeed() void {
    session_seed = normalizeFixedSeed(fixed_seed_value);
    initialized = true;
    std.log.info("music.entropy: fixed seed mode enabled (seed=0x{x})", .{session_seed});
}

fn ensureInit() void {
    if (initialized) return;

    if (fixed_seed_enabled) {
        initFixedSessionSeed();
        return;
    }

    initRandomSessionSeed();
}

pub fn configureFixedSeed(enabled: bool, seed: u64) bool {
    if (fixed_seed_enabled == enabled and fixed_seed_value == seed) return false;

    fixed_seed_enabled = enabled;
    fixed_seed_value = seed;
    reset_counter = 0;
    initialized = false;

    if (fixed_seed_enabled) {
        initFixedSessionSeed();
        return true;
    }

    initRandomSessionSeed();
    return true;
}

pub fn nextSeed(namespace_tag: u32, cue_tag: u32) u32 {
    ensureInit();
    reset_counter +%= 1;

    const mixed = splitmix64(
        session_seed ^
            (@as(u64, namespace_tag) << 32) ^
            @as(u64, cue_tag) ^
            (reset_counter *% 0x9E37_79B9),
    );

    const seed: u32 = @truncate(mixed ^ (mixed >> 32));
    if (seed != 0) return seed;
    return 0xA341_316C;
}
