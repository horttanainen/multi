// Headless authoring boundary check: reuse the actual JSON loader and pose evaluator.
const std = @import("std");
const animation = @import("src/character_animation.zig");
const data = @import("src/data.zig");
const fs = @import("src/fs.zig");
const runtime = @import("src/runtime.zig");
const vec = @import("src/vector.zig");
const control_count = std.meta.fields(animation.Control).len;
const joint_count = std.meta.fields(animation.Joint).len;

const Sample = struct {
    phase: f64,
    controls: []const struct { control: animation.Control, value: f32 },
    joints: []const struct { joint: animation.Joint, position: vec.Vec2 },
};

pub fn main(init: std.process.Init) !void {
    runtime.init(init.io);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const args = try init.minimal.args.toSlice(memory);
    if (args.len != 2) {
        std.log.err("Usage: zig build check-character-export -- <export-directory>", .{});
        return error.InvalidArguments;
    }
    var detail: animation.Diagnostic = .{};
    const files = data.parseCharacterAnimationData(
        memory,
        try readExport(memory, args[1], "humanoid.json"),
        try readExport(memory, args[1], "run_reference.json"),
        try readExport(memory, args[1], "run.json"),
        @embedFile("character_actions/airborne.json"),
        @embedFile("character_actions/aiming.json"),
        @embedFile("character_actions/walls.json"),
        &detail,
    ) catch |err| {
        std.log.err("character export JSON: {s}: {s}", .{ detail.file, detail.message[0..detail.length] });
        return err;
    };
    var set = animation.prepareAssets(files, &detail) catch |err| {
        std.log.err("character export validation: {s}: {s}", .{ detail.file, detail.message[0..detail.length] });
        return err;
    };
    defer set.arena.deinit();
    const samples_json = try readExport(memory, args[1], "samples.json");
    const samples = try std.json.parseFromSlice([]const Sample, memory, samples_json, .{});
    defer samples.deinit();
    if (samples.value.len < 2) {
        std.log.err("character export: missing Blender comparison samples", .{});
        return error.MissingSamples;
    }
    var maximum_joint_error: f32 = 0;
    for (samples.value) |sample| {
        if (!std.math.isFinite(sample.phase) or sample.phase < 0 or sample.phase > 1) {
            std.log.err("character export: invalid sample phase {d}", .{sample.phase});
            return error.InvalidPhase;
        }
        if (sample.controls.len != control_count or sample.joints.len != joint_count) {
            std.log.err("character export: phase {d} needs every named control and joint", .{sample.phase});
            return error.IncompleteSample;
        }
        var seen_controls: [control_count]bool = @splat(false);
        var seen_joints: [joint_count]bool = @splat(false);
        const phase = animation.clipPhase(set.motion, sample.phase);
        for (sample.controls) |expected| {
            const index = @intFromEnum(expected.control);
            if (seen_controls[index]) {
                std.log.err("character export: duplicate control {s}", .{@tagName(expected.control)});
                return error.DuplicateControl;
            }
            seen_controls[index] = true;
            const actual = animation.evaluateTrack(set.motion.tracks[index], phase);
            if (!std.math.isFinite(expected.value) or @abs(actual - expected.value) > 0.00002) {
                std.log.err("character export: {s} phase {d:.4}: Blender {d}, runtime {d}", .{
                    @tagName(expected.control), sample.phase, expected.value, actual,
                });
                return error.ControlMismatch;
            }
        }
        const pose = animation.evaluatePose(&set, sample.phase, .run);
        for (sample.joints) |expected| {
            const index = @intFromEnum(expected.joint);
            if (seen_joints[index]) {
                std.log.err("character export: duplicate joint {s}", .{@tagName(expected.joint)});
                return error.DuplicateJoint;
            }
            seen_joints[index] = true;
            const actual = pose.joints[index];
            const distance = vec.magnitude(vec.subtract(actual, expected.position));
            maximum_joint_error = @max(maximum_joint_error, distance);
            if (!std.math.isFinite(distance) or distance > 0.003) {
                std.log.err("character export: {s} phase {d:.4}: Blender ({d}, {d}), runtime ({d}, {d})", .{
                    @tagName(expected.joint), sample.phase, expected.position.x,
                    expected.position.y,      actual.x,     actual.y,
                });
                return error.PoseMismatch;
            }
        }
    }
    std.log.info("Character export: {d} Blender samples agree with runtime; max joint error {d:.6} m", .{
        samples.value.len, maximum_joint_error,
    });
}

fn readExport(memory: std.mem.Allocator, directory: []const u8, filename: []const u8) ![]u8 {
    const path = try std.fs.path.join(memory, &.{ directory, filename });
    return fs.readFileAlloc(path, memory, 16 * 1024 * 1024) catch |err| {
        std.log.err("character export: cannot read {s}: {s}", .{ path, @errorName(err) });
        return err;
    };
}
