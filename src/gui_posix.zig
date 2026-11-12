//! pstview - PST / OST / MBOX viewer and exporter (read-only), macOS and Linux entry point.
//! The window is native (Cocoa or GTK); its content is shown by the system web view. See
//! webapp.zig for the model, gui_mac.zig / gui_gtk.zig for the platform halves. The Windows GUI is
//! gui.zig.
//!
//!   pstview [file or folder ...]      several PST/OST parts are merged into one mailbox
//!   pstview --version
//!   pstview --selftest <source>       open, list and render one message, then exit 0 / 1 (for CI)

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const shell = if (builtin.os.tag.isDarwin()) @import("gui_mac.zig") else @import("gui_gtk.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    var selftest = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("pstview {s}\n", .{build_options.version});
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
