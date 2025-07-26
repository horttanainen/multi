const std = @import("std");

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

    if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("SDL2_image");
        exe.linkSystemLibrary("SDL2_ttf");
    } else {
        const sdl_dep = b.dependency("SDL", .{ .target = target, .optimize = optimize });
        const sdl = sdl_dep.artifact("SDL2");
        exe.linkLibrary(sdl);

        const sdl_image_dep = b.dependency("SDL_image", .{ .target = target, .optimize = optimize });
        const sdl_image = sdl_image_dep.artifact("SDL2_image");
        exe.linkLibrary(sdl_image);

        const sdl_ttf_dep = b.dependency("SDL_ttf", .{ .target = target, .optimize = optimize });
        const sdl_ttf = sdl_ttf_dep.artifact("SDL2_ttf");
        exe.linkLibrary(sdl_ttf);
    }

    const zsdl = b.dependency("zsdl", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zsdl", zsdl.module("zsdl2"));
    exe.root_module.addImport("zsdl_image", zsdl.module("zsdl2_image"));
    exe.root_module.addImport("zsdl_ttf", zsdl.module("zsdl2_ttf"));

    exe.addCSourceFiles(.{
        .root = b.path("./box2d/src/"),
        .files = &[_][]const u8{
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
        },
    });
    exe.addIncludePath(b.path("./box2d/include/"));

    exe.addCSourceFiles(.{
        .root = b.path("./triangle/"),
        .files = &[_][]const u8{
            "triangle.c",
        },
    });
    exe.addIncludePath(b.path("./triangle/"));

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
}
