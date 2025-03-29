const std = @import("std");
const box2d = @import("Box2D.zig/build.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "multi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/sdl2_image/lib" });
    exe.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/sdl2/lib" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl2_image/include" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/local/opt/sdl2/include" });
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("SDL2_image");

    const zsdl = b.dependency("zsdl", .{});
    exe.root_module.addImport("zsdl2", zsdl.module("zsdl2"));
    exe.root_module.addImport("zsdl2_image", zsdl.module("zsdl2_image"));

    exe.addCSourceFiles(.{ .root = b.path("./box2d/src/"), .files = &[_][]const u8{
        "aabb.c",
        "arena_allocator.c",
        "array.c",
        "bitset.c",
        "body.c",
        "broad_phase.c",
        "constraint_graph.c",
        "contact.c",
        "contact_solver.c",
        "core.c",
        "distance.c",
        "distance_joint.c",
        "dynamic_tree.c",
        "geometry.c",
        "hull.c",
        "id_pool.c",
        "island.c",
        "joint.c",
        "manifold.c",
        "math_functions.c",
        "motor_joint.c",
        "mouse_joint.c",
        "prismatic_joint.c",
        "revolute_joint.c",
        "sensor.c",
        "shape.c",
        "solver.c",
        "solver_set.c",
        "table.c",
        "timer.c",
        "types.c",
        "weld_joint.c",
        "wheel_joint.c",
        "world.c",
    } });
    exe.addIncludePath(b.path("./box2d/include/"));

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
}
