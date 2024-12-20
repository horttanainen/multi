const Build = @import("std").Build;
const box2d = @import("Box2D.zig/build.zig");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "multi",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();

    const sdl_dep = b.dependency("sdl", .{
        .optimize = optimize,
        .target = target,
    });
    exe.linkLibrary(sdl_dep.artifact("SDL2"));

    const zsdl = b.dependency("zsdl", .{});
    exe.root_module.addImport("zsdl2", zsdl.module("zsdl2"));

    const box2dModule = try box2d.addModule(b, "Box2D.zig", .{
        .optimize = optimize,
        .target = target,
    });
    exe.root_module.addImport("box2d", box2dModule);

    b.installArtifact(exe);

    const run = b.step("run", "Run the game");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
}
