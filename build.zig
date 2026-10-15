const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- C interop (Wayland + Vulkan headers) ----
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c/c.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.addIncludePath(b.path("src/c"));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("c", tc.createModule());
    // wayland-scanner generated xdg-shell glue
    mod.addCSourceFile(.{ .file = b.path("src/c/xdg-shell-protocol.c"), .flags = &.{} });
    mod.addIncludePath(b.path("src/c"));
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("vulkan", .{});

    // ---- Shaders: GLSL -> SPIR-V via glslc ----
    const shaders = [_][]const u8{ "mesh.vert", "mesh.frag" };
    inline for (shaders) |name| {
        const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O" });
        cmd.addFileArg(b.path("shaders/" ++ name));
        cmd.addArg("-o");
        const spv = cmd.addOutputFileArg(name ++ ".spv");
        mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
    }

    const exe = b.addExecutable(.{ .name = "airplane_game", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the game").dependOn(&run.step);
}
