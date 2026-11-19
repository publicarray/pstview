//! pstview - PST / OST / MBOX viewer and exporter (read-only), macOS and Linux entry point.
//! The window is native (Cocoa or GTK 4, which also draws the menus, status bar and dialogs);
//! its content is shown by the system web view. See
//! webapp.zig for the model, gui_mac.zig / gui_gtk.zig for the platform halves. Windows has the
//! same page and model in gui_win.zig.
//!
//!   pstview [file or folder ...]      several PST/OST parts are merged into one mailbox
//!   pstview --version
//!   pstview --install | --uninstall   for the current user, as Help > Install / Uninstall do
//!   pstview --screenshot <png> <source>   write a picture of the window's page (Linux), then exit
//!   pstview --selftest <source>       open, list and render one message, then exit 0 / 1 (for CI)

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const setup = @import("setup.zig");
const webapp = @import("webapp.zig");
const shell = if (builtin.os.tag.isDarwin()) @import("gui_mac.zig") else @import("gui_gtk.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    var selftest = false;
    var want_png = false;
    for (args[1..]) |arg| {
        if (want_png) {
            want_png = false;
            webapp.screenshot_path = std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(init.io, arena), arg }) catch arg;
            continue;
        }
        if (std.mem.eql(u8, arg, "--screenshot")) {
            want_png = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("pstview {s}\n", .{build_options.version});
            return;
        } else if (std.mem.eql(u8, arg, "--install") or std.mem.eql(u8, arg, "--uninstall")) {
            const r = if (arg[2] == 'i') setup.install(arena, init.io, build_options.version) else setup.uninstall(arena, init.io);
            std.debug.print("{s}\n", .{r.text});
            if (!r.ok) std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, arg, "--selftest")) {
            selftest = true;
        } else if (std.mem.startsWith(u8, arg, "-psn_")) {
            // process serial number passed by older macOS launchers
        } else {
            // dialogs and exports work with absolute paths
            const abs = std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(init.io, arena), arg }) catch arg;
            try paths.append(arena, abs);
        }
    }
    const code = shell.run(init.gpa, init.io, paths.items, selftest);
    if (code != 0) std.process.exit(code);
}
