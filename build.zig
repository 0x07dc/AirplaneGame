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
    // wayland-scanner generated xdg-shell + xdg-decoration + xdg-toplevel-icon glue
    mod.addCSourceFile(.{ .file = b.path("src/c/xdg-shell-protocol.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path("src/c/xdg-decoration-protocol.c"), .flags = &.{} });
    mod.addCSourceFile(.{ .file = b.path("src/c/xdg-toplevel-icon-v1-protocol.c"), .flags = &.{} });
    mod.addIncludePath(b.path("src/c"));
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("vulkan", .{});
    mod.linkSystemLibrary("asound", .{});

    // ---- Shaders: GLSL -> SPIR-V via glslc OR precompiled SPIR-V ----
    const use_precompiled_shaders = b.option(bool, "use-precompiled-shaders", "Use precompiled SPIR-V shaders from shaders/*.spv instead of invoking glslc") orelse false;
    const shaders = [_][]const u8{ "mesh.vert", "mesh.frag" };
    if (use_precompiled_shaders) {
        inline for (shaders) |name| {
            mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = b.path("shaders/" ++ name ++ ".spv") });
        }
    } else {
        inline for (shaders) |name| {
            const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-O" });
            cmd.addFileArg(b.path("shaders/" ++ name));
            cmd.addArg("-o");
            const spv = cmd.addOutputFileArg(name ++ ".spv");
            mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
        }
    }

    const exe = b.addExecutable(.{ .name = "airplane_game", .root_module = mod });
    b.installArtifact(exe);

    // ---- Desktop Integration (Applications, Metainfo, Icons) ----
    b.installFile("dist/common/io.github._0x07dc.AirplaneGame.desktop", "share/applications/io.github._0x07dc.AirplaneGame.desktop");
    b.installFile("dist/common/io.github._0x07dc.AirplaneGame.metainfo.xml", "share/metainfo/io.github._0x07dc.AirplaneGame.metainfo.xml");
    b.installFile("dist/common/icons/scalable/io.github._0x07dc.AirplaneGame.svg", "share/icons/hicolor/scalable/apps/io.github._0x07dc.AirplaneGame.svg");
    b.installFile("dist/common/icons/64x64/io.github._0x07dc.AirplaneGame.png", "share/icons/hicolor/64x64/apps/io.github._0x07dc.AirplaneGame.png");
    b.installFile("dist/common/icons/128x128/io.github._0x07dc.AirplaneGame.png", "share/icons/hicolor/128x128/apps/io.github._0x07dc.AirplaneGame.png");
    b.installFile("dist/common/icons/256x256/io.github._0x07dc.AirplaneGame.png", "share/icons/hicolor/256x256/apps/io.github._0x07dc.AirplaneGame.png");
    b.installFile("dist/common/icons/512x512/io.github._0x07dc.AirplaneGame.png", "share/icons/hicolor/512x512/apps/io.github._0x07dc.AirplaneGame.png");

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the game").dependOn(&run.step);
}
