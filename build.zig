const std = @import("std");

/// Release version. Bump it in the commit that gets tagged; the tag must be "v" ++ this.
const release_version = "0.7.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // -Drelease (or --release) builds ReleaseSafe, as the published binaries are; -Doptimize=<mode>
    // picks any mode; neither gives a Debug build.
    const release = b.option(bool, "release", "Build for end users (ReleaseSafe)") orelse (b.graph.release_mode != .off);
    const optimize: std.builtin.Optimize = if (release) .ReleaseSafe else b.standardOptimizeOption(.{});

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

    const os = target.result.os.tag;

    // GUI viewer: native windows around the system web view, with the same page and model
    // (webui.html, webapp.zig) on every platform. Windows: WebView2 (gui_win.zig). macOS and
    // Linux (gui_posix.zig): Cocoa / WebKit and GTK / WebKitGTK are loaded at run time, so
    // nothing but libc is linked and every target cross-compiles. A static (musl) Linux build
    // cannot load them and gets pstx only.
    if (os == .windows) {
        const gui_mod = b.createModule(.{
            .root_source_file = b.path("src/gui_win.zig"),
            .target = target,
            .optimize = optimize,
        });
        for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "shell32", "ole32", "gdiplus", "shlwapi", "dwmapi", "uxtheme", "advapi32" }) |lib| gui_mod.linkSystemLibrary(lib, .{});
        gui_mod.addWin32ResourceFile(.{ .file = b.path("src/pstview.rc"), .flags = &rc_flags });
        gui_mod.addOptions("build_options", opts);
        const gui = b.addExecutable(.{ .name = "pstview", .root_module = gui_mod, .win32_manifest = b.path("src/app.manifest") });
        gui.subsystem = .windows;
        b.installArtifact(gui);
    } else if (os.isDarwin() or (os == .linux and target.result.abi.isGnu())) {
        const gui = b.addExecutable(.{
            .name = "pstview",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui_posix.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        gui.root_module.addOptions("build_options", opts);
        // what Help > Install puts in the applications menu (Linux; src/setup.zig)
        gui.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("design/icon-256.png") });
        gui.root_module.addAnonymousImport("desktop_entry", .{ .root_source_file = b.path("packaging/linux/pstview.desktop") });
        gui.root_module.addAnonymousImport("mime_package", .{ .root_source_file = b.path("packaging/linux/pstview-mime.xml") });
        b.installArtifact(gui);
    }

    // The web browser version (zig build web): the model as WebAssembly in a Web Worker, beside
    // the same page; zig-out/web is a static site (src/web.zig, web/).
    const web_step = b.step("web", "Build the web browser version into zig-out/web");
    const wasm = b.addExecutable(.{
        .name = "pstview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
            .optimize = if (optimize == .debug) .safe else optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.addOptions("build_options", opts);
    const web_dir: std.Build.InstallDir = .{ .custom = "web" };
    web_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = web_dir } }).step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/webui.html"), web_dir, "index.html").step);
    web_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("web"), .install_dir = web_dir, .install_subdir = "" }).step);
    for ([_][]const u8{ "icon-256.png", "icon-512.png", "icon-192.png" }) |icon|
        web_step.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("design/{s}", .{icon})), web_dir, icon).step);

    // Command-line tool
    const cli = b.addExecutable(.{
        .name = "pstx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            // macOS / Linux: local time zone and charsets come from libc (src/platform.zig)
            .link_libc = os != .windows,
        }),
    });
    cli.root_module.addOptions("build_options", opts);
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs(); // zig build run -- <args>
    b.step("run", "Run pstx").dependOn(&run_cli.step);

    // Unit tests (portable modules)
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/rtfcp.zig", "src/mime.zig", "src/headers.zig", "src/mbox.zig", "src/multi.zig", "src/namemap.zig", "src/itemview.zig", "src/render.zig", "src/export.zig", "src/pst.zig", "src/pstwrite.zig", "src/recur.zig" }) |src| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    // The exporters on the demo mailbox, byte for byte (src/exportcheck.zig): they read testdata/
    // relative to the repository root, and charsets come from libc as in pstx.
    const export_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/exportcheck.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = os != .windows,
        }),
    });
    const run_export_tests = b.addRunArtifact(export_tests);
    run_export_tests.setCwd(b.path("."));
    run_export_tests.has_side_effects = true; // (reads testdata/: never a cached result)
    test_step.dependOn(&run_export_tests.step);

    // Fuzz targets for untrusted content (src/fuzz.zig): once over the seed inputs as part of
    // `zig build test`; `zig build fuzz --fuzz` keeps mutating them, guided by coverage.
    // --fuzz=<limit> works through one target: -Dfuzz-target=<part of its name> picks it
    // ("message", "header block", "sanitiser", "RTF").
    const fuzz_target = b.option([]const u8, "fuzz-target", "Fuzz only the targets whose name contains this text");
    const fuzz_tests = b.addTest(.{
        .filters = if (fuzz_target) |f| &.{f} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    b.step("fuzz", "Run the fuzz targets (add --fuzz to keep searching)").dependOn(&run_fuzz.step);
    test_step.dependOn(&run_fuzz.step);
}

/// `git describe` without the leading "v"; the release version plus the commit id when no tag is
/// reachable (shallow CI clones of a branch), or just the release version without git.
fn gitVersion(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", b.root.toString(b.allocator) catch ".", "describe", "--tags", "--match", "v*", "--always", "--dirty" }, &code, .ignore) catch return release_version;
    const d = std.mem.trim(u8, out, " \r\n");
    if (d.len == 0) return release_version;
    if (d[0] != 'v') return b.fmt("{s}+{s}", .{ release_version, d });
    const v = d[1..];
    // On a release tag the exe's file version must agree with the tag.
    if (std.mem.indexOfScalar(u8, v, '-') == null and !std.mem.eql(u8, v, release_version))
        std.process.fatal("tag v{s} does not match release_version {s} in build.zig", .{ v, release_version });
    return v;
}
