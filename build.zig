const std = @import("std");

fn box2dBroadPhaseSource(b: *std.Build, dependency: *std.Build.Dependency) !std.Build.LazyPath {
    // Patch only the pinned dependency's pair queries, leaving the cache source
    // untouched. Dense particle bursts otherwise visit every rejected pair.
    const source = try std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        dependency.path("src/broad_phase.c").getPath(b),
        b.allocator,
        .limited(128 * 1024),
    );
    const binding = "queryContext.queryShapeIndex = (int)b2DynamicTree_GetUserData( baseTree, proxyId );";
    const query = "fatAABB, B2_DEFAULT_MASK_BITS, b2PairQueryCallback, &queryContext";
    if (std.mem.count(u8, source, binding) != 1 or std.mem.count(u8, source, query) != 3) {
        std.log.err("box2dBroadPhaseSource: dependency changed; review collision-mask patch", .{});
        return error.Box2dBroadPhaseSourceChanged;
    }
    // Positive groups force collision even when category masks exclude it.
    const mask_binding =
        \\        const b2Shape* queryShape =
        \\            b2ShapeArray_Get( &world->shapes, queryContext.queryShapeIndex );
        \\        uint64_t queryMask = queryShape->filter.groupIndex > 0
        \\            ? B2_DEFAULT_MASK_BITS : queryShape->filter.maskBits;
    ;
    const with_mask = try std.mem.replaceOwned(
        u8,
        b.allocator,
        source,
        binding,
        binding ++ "\n" ++ mask_binding,
    );
    const patched = try std.mem.replaceOwned(
        u8,
        b.allocator,
        with_mask,
        query,
        "fatAABB, queryMask, b2PairQueryCallback, &queryContext",
    );
    return b.addWriteFiles().add("box2d/broad_phase.c", patched);
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Keep game debugging intact without running the native collision solver
    // unoptimized. Override this when stepping through Box2D itself.
    const box2d_optimize = b.option(
        std.builtin.OptimizeMode,
        "box2d-optimize",
        "Box2D optimization mode (defaults to ReleaseSafe in Debug game builds)",
    ) orelse if (optimize == .Debug) .ReleaseSafe else optimize;
    const box2d_flags: []const []const u8 = if (optimize == .Debug)
        &.{ "-std=gnu17", "-UNDEBUG" }
    else
        &.{"-std=gnu17"};
    const explosion_perf = b.option(bool, "explosion-perf", "Compile explosion performance instrumentation and benchmark scenarios") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "explosion_perf", explosion_perf);

    const exe = b.addExecutable(.{
        .name = "multi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    const sdl_dep = b.dependency("SDL3", .{ .target = target, .optimize = optimize });
    const sdl = sdl_dep.artifact("SDL3");
    exe.root_module.linkLibrary(sdl);

    const sdl_image_dep = b.dependency("SDL_image", .{ .target = target, .optimize = optimize });
    const sdl_image = sdl_image_dep.artifact("SDL3_image");
    exe.root_module.linkLibrary(sdl_image);

    const sdl_ttf_dep = b.dependency("SDL_ttf", .{ .target = target, .optimize = optimize });
    const sdl_ttf = sdl_ttf_dep.artifact("SDL3_ttf");
    exe.root_module.linkLibrary(sdl_ttf);

    const box2d_source_dep = b.dependency("box2d_source", .{});
    const box2d_mod = b.createModule(.{
        .target = target,
        .optimize = box2d_optimize,
        .link_libc = true,
    });
    box2d_mod.addIncludePath(box2d_source_dep.path("include"));
    box2d_mod.addIncludePath(box2d_source_dep.path("src"));
    box2d_mod.addCSourceFile(.{
        .file = try box2dBroadPhaseSource(b, box2d_source_dep),
        .flags = box2d_flags,
    });
    box2d_mod.addCSourceFiles(.{
        .root = box2d_source_dep.path("src"),
        .flags = box2d_flags,
        .files = &.{
            "aabb.c",
            "arena_allocator.c",
            "array.c",
            "bitset.c",
            "body.c",
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
            "mover.c",
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
    const box2d_lib = b.addLibrary(.{
        .name = "box2d",
        .root_module = box2d_mod,
    });
    box2d_lib.installHeadersDirectory(box2d_source_dep.path("include"), "", .{});
    exe.root_module.linkLibrary(box2d_lib);

    const triangle_dep = b.dependency("triangle", .{ .target = target, .optimize = optimize });
    exe.root_module.linkLibrary(triangle_dep.artifact("triangle"));

    const character_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("character_animation_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    character_tests.root_module.addOptions("build_options", build_options);
    character_tests.root_module.linkLibrary(sdl);
    character_tests.root_module.linkLibrary(sdl_image);
    character_tests.root_module.linkLibrary(sdl_ttf);
    character_tests.root_module.linkLibrary(box2d_lib);
    character_tests.root_module.linkLibrary(triangle_dep.artifact("triangle"));
    const test_character = b.step("test-character-animation", "Check character assets, curves, IK, and lifecycle");
    test_character.dependOn(&b.addRunArtifact(character_tests).step);

    const music_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("music_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_music = b.step("test-music", "Check music DSP, step timing, and procedural bus rendering");
    test_music.dependOn(&b.addRunArtifact(music_tests).step);

    const music_menu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("music_menu_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    music_menu_tests.root_module.addOptions("build_options", build_options);
    music_menu_tests.root_module.linkLibrary(sdl);
    music_menu_tests.root_module.linkLibrary(sdl_image);
    music_menu_tests.root_module.linkLibrary(sdl_ttf);
    music_menu_tests.root_module.linkLibrary(box2d_lib);
    music_menu_tests.root_module.linkLibrary(triangle_dep.artifact("triangle"));
    const test_music_menu = b.step("test-music-menu", "Check live music controls, persistence and SDL audio playback");
    test_music_menu.dependOn(&b.addRunArtifact(music_menu_tests).step);

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run.dependOn(&run_cmd.step);

    const probe = b.addExecutable(.{
        .name = "music_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/music_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(probe);

    const probe_run = b.step("music-probe", "Render a direct music instrument probe to WAV");
    const probe_run_cmd = b.addRunArtifact(probe);
    if (b.args) |args| {
        probe_run_cmd.addArgs(args);
    }
    probe_run.dependOn(&probe_run_cmd.step);

    const procedural_probe = b.addExecutable(.{
        .name = "procedural_music_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/procedural_music_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(procedural_probe);

    const procedural_probe_run = b.step("procedural-music-probe", "Render a procedural music style to WAV");
    const procedural_probe_run_cmd = b.addRunArtifact(procedural_probe);
    if (b.args) |args| {
        procedural_probe_run_cmd.addArgs(args);
    }
    procedural_probe_run.dependOn(&procedural_probe_run_cmd.step);
}
