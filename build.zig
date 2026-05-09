const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "multi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();

    const sdl_dep = b.dependency("SDL3", .{ .target = target, .optimize = optimize });
    const sdl = sdl_dep.artifact("SDL3");
    exe.linkLibrary(sdl);

    const sdl_image_dep = b.dependency("SDL_image", .{ .target = target, .optimize = optimize });
    const sdl_image = sdl_image_dep.artifact("SDL3_image");
    exe.linkLibrary(sdl_image);

    const sdl_ttf_dep = b.dependency("SDL_ttf", .{ .target = target, .optimize = optimize });
    const sdl_ttf = sdl_ttf_dep.artifact("SDL3_ttf");
    exe.linkLibrary(sdl_ttf);

    const box2d_dep = b.dependency("box2d", .{ .target = target, .optimize = optimize });
    exe.linkLibrary(box2d_dep.artifact("box2d"));

    const triangle_dep = b.dependency("triangle", .{ .target = target, .optimize = optimize });
    exe.linkLibrary(triangle_dep.artifact("triangle"));

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
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
