//! The exporters checked byte for byte on every platform (part of `zig build test`, run from the
//! repository root; CI runs it on Windows, macOS and Linux). pstx has no export commands (the
//! desktop pstview exports through a save dialog), so these tests run the writers directly.

const std = @import("std");
const Io = std.Io;
const store = @import("store.zig");
const pstwrite = @import("pstwrite.zig");
const platform = @import("platform.zig");
const mime = @import("mime.zig");

const demo = "testdata/demo-mailbox";

test "PST writer: the demo mailbox gives testdata/demo.pst byte for byte" {
    // The writer is deterministic (no clock, no random numbers): the same source gives the same
    // file everywhere. testdata/demo.pst is that file; pstx's PST reading is checked on it by
    // testdata/smoke.sh. When they differ the new file is kept: if the writer was changed on
    // purpose, `cp .zig-cache/exportcheck-demo.pst testdata/demo.pst` (and check smoke.sh's output).
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    mime.charset_hook = &platform.charsetToUtf8;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try store.Store.open(gpa, io, demo);
    defer f.close();
    const out = ".zig-cache/exportcheck-demo.pst";
    const stats = try pstwrite.exportStore(gpa, io, f, out, .{ .display_name = "demo-mailbox", .uid_seed = demo }, a);
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
    const got = try Io.Dir.cwd().readFileAlloc(io, out, a, .limited(16 << 20));
    const want = try Io.Dir.cwd().readFileAlloc(io, "testdata/demo.pst", a, .limited(16 << 20));
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("the PST writer's output differs from testdata/demo.pst ({d} / {d} bytes); kept as {s}\n", .{ got.len, want.len, out });
        return error.PstOutputChanged;
    }
    Io.Dir.cwd().deleteFile(io, out) catch {};
}

test ".eml export of MBOX items: the original message, byte for byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try store.Store.open(gpa, io, demo);
    defer f.close();
    var inbox: ?u32 = null;
    for (try f.subFolders(a, f.rootFolder())) |k| {
        if (std.mem.eql(u8, (try f.folderInfo(a, k)).name, "Inbox")) inbox = k;
    }
    const msgs = try f.folderMessages(a, inbox orelse return error.NoInbox);
    // SHA-256 of each Inbox message as exported, in folder order
    const want = [_][]const u8{
        "506a4572c5067cd43752bbda0b147d0952bc857c4cb2c26ab8c02e077a9fa1d8",
        "d7e77f8c5d85915811a34029eb06ff9096e1d83acd4d600104447955e031e37e",
        "5d711381c9c1cdfbd512fe556c8d6341a79a6caac7b3c4aa5f66ae3e2c03c22d",
        "303d5bd572893741198930df4e482ba6bea800255b4643b321a1974a461e603b",
        "0bbc1b1f128060f4b528210124ff80f792baa8bd669ac2ec006e69ef79661b08",
        "b9e3f36a74167e7c102dfefc07fa2c6fab4f4362b4f4a3b99c56ab3fa8ddbb8c",
        "b1effd24756e82c05686fea3e820caaf7475afbfd36889de3905822f01074652",
        "8ecf052e801119444fdbd4a5a6156291da8c630c7760c423c683c3dc0357bef2",
    };
    try std.testing.expectEqual(want.len, msgs.len);
    for (msgs, want) |s, w| {
        const raw = (try f.rawMessage(a, s.nid)) orelse return error.NoRawMessage;
        var sum: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(raw, &sum, .{});
        try std.testing.expectEqualStrings(w, &std.fmt.bytesToHex(sum, .lower));
    }
}
