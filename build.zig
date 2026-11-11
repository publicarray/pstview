const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // GUI viewer
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "shell32", "ole32", "gdiplus", "shlwapi" }) |lib| gui_mod.linkSystemLibrary(lib, .{});
    gui_mod.addWin32ResourceFile(.{ .file = b.path("src/pstview.rc") });
    const gui = b.addExecutable(.{ .name = "pstview", .root_module = gui_mod, .win32_manifest = b.path("src/app.manifest") });
    gui.subsystem = .windows;
    b.installArtifact(gui);

    // Command-line tool
    const cli = b.addExecutable(.{
        .name = "pstx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Run pstx").dependOn(&run_cli.step);

    // Unit tests (portable modules)
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/rtfcp.zig", "src/mime.zig", "src/headers.zig", "src/mbox.zig", "src/multi.zig", "src/namemap.zig", "src/itemview.zig", "src/rtf.zig" }) |src| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
