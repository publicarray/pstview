const std = @import("std");

/// Release version. Bump it in the commit that gets tagged; the tag must be "v" ++ this.
const release_version = "0.2.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // Version shown in Help > About and by `pstx --version`, from `git describe`: "0.2.0" for a
    // tagged build, "0.2.0-3-g98aac75" for commits after the tag ("-dirty" with local changes).
    const version = b.option([]const u8, "version", "Version string (default: from git describe)") orelse gitVersion(b);
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);

    // The exe's file version (Explorer > Properties) is the release version.
    const sv = std.SemanticVersion.parse(release_version) catch @panic("release_version is not semver");
    const rc_flags = [_][]const u8{
        b.fmt("/dPSTVIEW_VERSION_NUM={d},{d},{d},0", .{ sv.major, sv.minor, sv.patch }),
        b.fmt("/dPSTVIEW_VERSION_STR=\"{s}\"", .{version}),
    };

    // GUI viewer
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "shell32", "ole32", "gdiplus", "shlwapi" }) |lib| gui_mod.linkSystemLibrary(lib, .{});
    gui_mod.addWin32ResourceFile(.{ .file = b.path("src/pstview.rc"), .flags = &rc_flags });
    gui_mod.addOptions("build_options", opts);
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
    cli.root_module.addOptions("build_options", opts);
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

/// `git describe` without the leading "v"; the release version plus the commit id when no tag is
/// reachable (shallow CI clones of a branch), or just the release version without git.
fn gitVersion(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--match", "v*", "--always", "--dirty" }, &code, .ignore) catch return release_version;
    const d = std.mem.trim(u8, out, " \r\n");
    if (d.len == 0) return release_version;
    if (d[0] != 'v') return b.fmt("{s}+{s}", .{ release_version, d });
    const v = d[1..];
    // On a release tag the exe's file version must agree with the tag.
    if (std.mem.indexOfScalar(u8, v, '-') == null and !std.mem.eql(u8, v, release_version))
        std.process.fatal("tag v{s} does not match release_version {s} in build.zig", .{ v, release_version });
    return v;
}
