//! Help > Install / Default apps / Uninstall, for the current user and without administrator
//! rights, on every platform:
//!
//!   Windows  install.zig: %LOCALAPPDATA%\Programs\pstview, Start menu, file handlers, Settings > Apps.
//!   Linux    ~/.local/bin (pstview, pstx), a menu entry, the icon and the PST / OST file type
//!            under ~/.local/share; `xdg-mime` makes pstview the default.
//!   macOS    a copy of pstview.app in ~/Applications, registered with Launch Services.
//!
//! Nothing is written until the user asks for it. `pstview --install` / `--uninstall` do the same
//! from a terminal (macOS, Linux).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const os = builtin.os.tag;
const impl = if (os == .windows) windows else if (os.isDarwin()) macos else linux;

pub const Info = struct {
    /// This copy can be installed (or can replace the installed one).
    available: bool = false,
    installed: bool = false,
    /// The running program is the installed copy.
    running_installed: bool = false,
    /// Offer to install when the program starts (a portable copy, not declined for good).
    offer: bool = false,
    /// One line for Help > About.
    about: []const u8 = "",
    install_text: []const u8 = "",
    uninstall_text: []const u8 = "",
    defaults_label: []const u8 = "Choose default apps\u{2026}",
};

pub const Result = struct {
    ok: bool = true,
    /// Shown to the user; empty: nothing to say.
    text: []const u8 = "",
    /// To be opened by the shell (a settings page).
    url: []const u8 = "",
    /// The program should close (its own files are being removed).
    quit: bool = false,
};

fn failed(a: Allocator, comptime fmt: []const u8, args: anytype) Result {
    return .{ .ok = false, .text = std.fmt.allocPrint(a, fmt, args) catch "Out of memory." };
}

pub fn info(a: Allocator, io: Io) Info {
    return impl.info(a, io) catch .{};
}

pub fn install(a: Allocator, io: Io, version: []const u8) Result {
    return impl.install(a, io, version) catch |e| failed(a, "Install failed: {s}", .{@errorName(e)});
}

pub fn uninstall(a: Allocator, io: Io) Result {
    return impl.uninstall(a, io) catch |e| failed(a, "Uninstall failed: {s}", .{@errorName(e)});
}

/// Make pstview the default for mailbox files, or open the place where the user chooses.
pub fn defaults(a: Allocator, io: Io) Result {
    return impl.defaults(a, io) catch |e| failed(a, "That did not work: {s}", .{@errorName(e)});
}

/// "Don't offer this again" on the first-run offer.
pub fn dismissOffer(a: Allocator, io: Io) void {
    impl.dismissOffer(a, io);
}

// ================================================================ Windows

const windows = struct {
    const inst = @import("install.zig");

    fn info(a: Allocator, _: Io) !Info {
        const l = try inst.defaultLayout(a);
        const installed = inst.isInstalled(a, l);
        const running = inst.runningInstalled(a, l);
        const self = inst.selfPath(a) catch "";
        return .{
            .available = !running,
            .installed = installed,
            .running_installed = running,
            .offer = !running and !installed and !inst.promptDismissed(a),
            .about = if (running)
                try std.fmt.allocPrint(a, "Installed for this user in {s}", .{l.dir})
            else
                try std.fmt.allocPrint(a, "Portable copy: {s}", .{std.fs.path.dirname(self) orelse self}),
            .install_text = if (installed)
                try std.fmt.allocPrint(a, "Replaces the copy installed in {s} with this version. File handlers and the Start menu entry are refreshed.", .{l.dir})
            else
                try std.fmt.allocPrint(a, "pstview is running as a portable app. Installing copies it to {s}, adds it to the Start menu and lets Explorer open .pst, .ost and .mbox files with it. No administrator rights are needed; uninstall any time from Settings > Apps.\n\nThe portable copy keeps working either way - nothing is written to this PC unless you install.", .{l.dir}),
            .uninstall_text = try std.fmt.allocPrint(a, "Removes pstview from {s}, its Start menu entry, its file handlers and its entry in Settings > Apps.\n\nMailbox files, exports and reports are not touched.", .{l.dir}),
        };
    }

    fn install(a: Allocator, io: Io, version: []const u8) !Result {
        const l = try inst.defaultLayout(a);
        inst.install(a, io, l, version) catch |e| return switch (e) {
            error.CopyFailed => failed(a, "pstview could not be copied to {s}.\n\nIf the installed copy is running, close it and try again.", .{l.dir}),
            error.InstallDir => failed(a, "The folder {s} could not be created.", .{l.dir}),
            else => failed(a, "Install failed: {s}", .{@errorName(e)}),
        };
        return .{ .text = "pstview is installed.\n\nStart it from the Start menu. Explorer now offers pstview under \"Open with\" for .pst, .ost, .mbox and .mbx files; to make it the default, use Help > Choose default apps (Windows asks you to confirm there).\n\nThis portable copy is no longer needed and can be deleted." };
    }

    fn uninstall(a: Allocator, _: Io) !Result {
        const l = try inst.defaultLayout(a);
        return switch (try inst.uninstall(a, l)) {
            .after_exit => .{ .text = "pstview has been uninstalled for this user and closes now.", .quit = true },
            .removed => .{ .text = "pstview has been uninstalled for this user." },
        };
    }

    fn defaults(_: Allocator, _: Io) !Result {
        return .{ .url = "ms-settings:defaultapps?registeredAppUser=pstview" };
    }

    fn dismissOffer(a: Allocator, _: Io) void {
        inst.dismissPrompt(a);
    }
};

// ================================================================ macOS and Linux: shared helpers

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Run a helper program; false when it is missing or fails.
fn runTool(a: Allocator, io: Io, argv: []const []const u8) bool {
    const r = std.process.run(a, io, .{ .argv = argv }) catch return false;
    return r.term.success();
}

fn remove(io: Io, path: []const u8) void {
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

// ================================================================ Linux

const linux = struct {
    const mime_types = [_][]const u8{ "application/vnd.ms-outlook-pst", "application/mbox" };
    /// shared-mime-info knows *.mbox; the Outlook data files get a type of their own.
    const mime_package =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
        \\  <mime-type type="application/vnd.ms-outlook-pst">
        \\    <comment>Outlook data file</comment>
        \\    <glob pattern="*.pst"/>
        \\    <glob pattern="*.ost"/>
        \\    <magic priority="60"><match type="string" offset="0" value="!BDN"/></magic>
        \\  </mime-type>
        \\  <mime-type type="application/mbox">
        \\    <glob pattern="*.mbox"/>
        \\    <glob pattern="*.mbx"/>
        \\  </mime-type>
        \\</mime-info>
        \\
    ;

    const Paths = struct {
        bin: []const u8,
        exe: []const u8,
        pstx: []const u8,
        apps: []const u8,
        desktop: []const u8,
        icons: []const u8,
        icon: []const u8,
        mime: []const u8,
        mime_dir: []const u8,
        mime_pkg: []const u8,
    };

    fn paths(a: Allocator) !Paths {
        const home = env("HOME") orelse return error.NoHomeFolder;
        const data = env("XDG_DATA_HOME") orelse try std.fs.path.join(a, &.{ home, ".local", "share" });
        const bin = try std.fs.path.join(a, &.{ home, ".local", "bin" });
        const apps = try std.fs.path.join(a, &.{ data, "applications" });
        const icons = try std.fs.path.join(a, &.{ data, "icons", "hicolor", "256x256", "apps" });
        const mime = try std.fs.path.join(a, &.{ data, "mime" });
        const mime_dir = try std.fs.path.join(a, &.{ mime, "packages" });
        return .{
            .bin = bin,
            .exe = try std.fs.path.join(a, &.{ bin, "pstview" }),
            .pstx = try std.fs.path.join(a, &.{ bin, "pstx" }),
            .apps = apps,
            .desktop = try std.fs.path.join(a, &.{ apps, "pstview.desktop" }),
            .icons = icons,
            .icon = try std.fs.path.join(a, &.{ icons, "pstview.png" }),
            .mime = mime,
            .mime_dir = mime_dir,
            .mime_pkg = try std.fs.path.join(a, &.{ mime_dir, "pstview.xml" }),
        };
    }

    fn info(a: Allocator, io: Io) !Info {
        const p = try paths(a);
        const self = try std.process.executablePathAlloc(io, a);
        const installed = exists(io, p.exe) and exists(io, p.desktop);
        const running = std.mem.eql(u8, self, p.exe);
        return .{
            .available = !running,
            .installed = installed,
            .running_installed = running,
            .about = if (running)
                try std.fmt.allocPrint(a, "Installed for this user in {s}", .{p.bin})
            else
                try std.fmt.allocPrint(a, "Portable copy: {s}", .{std.fs.path.dirname(self) orelse self}),
            .install_text = try std.fmt.allocPrint(a, "{s} pstview and pstx {s} {s}, and adds a menu entry, the icon and the PST / OST file type under {s}. No root rights are needed.\n\nThe portable copy keeps working either way - nothing is written to this computer unless you install.", .{ if (installed) "Replaces" else "Copies", if (installed) "in" else "to", p.bin, std.fs.path.dirname(p.apps) orelse p.apps }),
            .uninstall_text = try std.fmt.allocPrint(a, "Removes pstview and pstx from {s}, the menu entry, the icon and the file type.\n\nMailbox files, exports and reports are not touched.", .{p.bin}),
            .defaults_label = "Make pstview the default for PST / OST / MBOX files",
        };
    }

    fn install(a: Allocator, io: Io, _: []const u8) !Result {
        const p = try paths(a);
        const cwd = Io.Dir.cwd();
        const self = try std.process.executablePathAlloc(io, a);
        for ([_][]const u8{ p.bin, p.apps, p.icons, p.mime_dir }) |d| cwd.createDirPath(io, d) catch return failed(a, "The folder {s} could not be created.", .{d});
        if (!std.mem.eql(u8, self, p.exe)) cwd.copyFile(self, cwd, p.exe, io, .{}) catch return failed(a, "pstview could not be copied to {s}.", .{p.bin});
        // pstx travels with pstview in the release archive
        const pstx = try std.fs.path.join(a, &.{ std.fs.path.dirname(self) orelse ".", "pstx" });
        if (exists(io, pstx) and !std.mem.eql(u8, pstx, p.pstx)) cwd.copyFile(pstx, cwd, p.pstx, io, .{}) catch {};
        try cwd.writeFile(io, .{ .sub_path = p.icon, .data = @embedFile("icon_png") });
        try cwd.writeFile(io, .{ .sub_path = p.mime_pkg, .data = mime_package });
        // the menu entry starts the installed copy by its full path (~/.local/bin may not be on PATH)
        const entry = try std.mem.replaceOwned(u8, a, @embedFile("desktop_entry"), "Exec=pstview", try std.fmt.allocPrint(a, "Exec=\"{s}\"", .{p.exe}));
        try cwd.writeFile(io, .{ .sub_path = p.desktop, .data = entry });
        _ = runTool(a, io, &.{ "update-mime-database", p.mime });
        _ = runTool(a, io, &.{ "update-desktop-database", p.apps });
        return .{ .text = try std.fmt.allocPrint(a, "pstview is installed in {s}, with an entry in the applications menu.\n\nFile managers now offer pstview under \"Open with\" for .pst, .ost and .mbox files; Help > Make pstview the default sets it as their default.\n\nThis portable copy is no longer needed and can be deleted.", .{p.bin}) };
    }

    fn uninstall(a: Allocator, io: Io) !Result {
        const p = try paths(a);
        for ([_][]const u8{ p.exe, p.pstx, p.desktop, p.icon, p.mime_pkg }) |f| remove(io, f);
        _ = runTool(a, io, &.{ "update-mime-database", p.mime });
        _ = runTool(a, io, &.{ "update-desktop-database", p.apps });
        return .{ .text = "pstview has been uninstalled for this user." };
    }

    fn defaults(a: Allocator, io: Io) !Result {
        const p = try paths(a);
        if (!exists(io, p.desktop)) return failed(a, "Install pstview first (Help > Install pstview for this user).", .{});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "xdg-mime", "default", "pstview.desktop" });
        try argv.appendSlice(a, &mime_types);
        if (!runTool(a, io, argv.items)) return failed(a, "xdg-mime could not set the default (is xdg-utils installed?).\n\nIn your file manager: right-click a mailbox file > Open with > pstview > set as default.", .{});
        return .{ .text = "pstview now opens .pst, .ost and .mbox files by default." };
    }

    fn dismissOffer(_: Allocator, _: Io) void {}
};

// ================================================================ macOS

const macos = struct {
    const lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";

    /// The .app bundle the running program is in (…/pstview.app/Contents/MacOS/pstview), if any.
    fn bundle(a: Allocator, io: Io) !?[]const u8 {
        const self = try std.process.executablePathAlloc(io, a);
        const macos_dir = std.fs.path.dirname(self) orelse return null;
        const contents = std.fs.path.dirname(macos_dir) orelse return null;
        const app = std.fs.path.dirname(contents) orelse return null;
        if (!std.mem.eql(u8, std.fs.path.basename(macos_dir), "MacOS") or !std.mem.endsWith(u8, app, ".app")) return null;
        return app;
    }

    fn target(a: Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ env("HOME") orelse return error.NoHomeFolder, "Applications", "pstview.app" });
    }

    fn info(a: Allocator, io: Io) !Info {
        const dest = try target(a);
        const from = try bundle(a, io);
        const running = from != null and std.mem.eql(u8, from.?, dest);
        const installed = exists(io, try std.fs.path.join(a, &.{ dest, "Contents", "MacOS", "pstview" }));
        return .{
            .available = from != null and !running,
            .installed = installed,
            .running_installed = running,
            .about = if (running) "Installed for this user in ~/Applications" else if (from) |f| try std.fmt.allocPrint(a, "Portable copy: {s}", .{f}) else "Run from the command line (not from pstview.app)",
            .install_text = try std.fmt.allocPrint(a, "{s} pstview.app {s} ~/Applications (Launchpad and Spotlight find it there) and registers it for .pst, .ost and .mbox files. No administrator rights are needed.\n\nThis copy keeps working either way.", .{ if (installed) "Replaces" else "Copies", if (installed) "in" else "to" }),
            .uninstall_text = "Removes pstview.app from ~/Applications.\n\nMailbox files, exports and reports are not touched.",
            .defaults_label = "Make pstview the default for mailbox files\u{2026}",
        };
    }

    fn install(a: Allocator, io: Io, _: []const u8) !Result {
        const from = (try bundle(a, io)) orelse return failed(a, "This copy runs outside pstview.app, so there is no app to install. Start pstview.app from the release archive and choose Install there.", .{});
        const dest = try target(a);
        if (std.mem.eql(u8, from, dest)) return .{ .text = "This is already the installed copy." };
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, std.fs.path.dirname(dest).?) catch return failed(a, "~/Applications could not be created.", .{});
        cwd.deleteTree(io, dest) catch {};
        if (!runTool(a, io, &.{ "/bin/cp", "-R", from, dest })) return failed(a, "pstview.app could not be copied to ~/Applications.", .{});
        _ = runTool(a, io, &.{ lsregister, "-f", dest });
        return .{ .text = "pstview is installed in ~/Applications.\n\nFinder now offers pstview under \"Open With\" for .pst, .ost and .mbox files.\n\nThis copy is no longer needed and can be deleted." };
    }

    fn uninstall(a: Allocator, io: Io) !Result {
        const dest = try target(a);
        const from = try bundle(a, io);
        const running = from != null and std.mem.eql(u8, from.?, dest);
        _ = runTool(a, io, &.{ lsregister, "-u", dest });
        Io.Dir.cwd().deleteTree(io, dest) catch return failed(a, "pstview.app could not be removed from ~/Applications.", .{});
        return if (running) .{ .text = "pstview has been uninstalled for this user and closes now.", .quit = true } else .{ .text = "pstview has been uninstalled for this user." };
    }

    fn defaults(_: Allocator, _: Io) !Result {
        return .{ .text = "macOS sets the default app per file type in Finder:\n\n1. Select a .pst, .ost or .mbox file and choose File > Get Info.\n2. Under \"Open with\", pick pstview.\n3. Click \"Change All\u{2026}\"." };
    }

    fn dismissOffer(_: Allocator, _: Io) void {}
};
