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
        })
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

    exe.addIncludePath(b.path("./miniaudio/"));

    exe.addCSourceFiles(.{
        .root = b.path("./miniaudio/"),
        .files = &[_][]const u8{
            "miniaudio.c",
        },
        .flags = &[_][]const u8{
            "-DMINIAUDIO_IMPLEMENTATION",
            "-DMA_ENABLE_MP3",
        },
    });
    exe.addCSourceFiles(.{ .root = b.path("./triangle/"), .files = &[_][]const u8{
        "triangle.c",
    }, .flags = &[_][]const u8{
        "-DTRILIBRARY=true",
        "-DREAL=double",
    } });
    exe.addIncludePath(b.path("./triangle/"));

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
}
