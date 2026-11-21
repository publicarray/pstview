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

// ---------------------------------------------------------------- testdata/calendar.pst

const pst = @import("pst.zig");
const namemap = @import("namemap.zig");
const recur = @import("recur.zig");

/// The fixture's appointments: one of each kind, the recurring ones with the recurrence and time
/// zone examples of [MS-OXOCAL] 4.1 (Outlook's own data, not made by pstview), so the calendar
/// view is tested on what Outlook writes. Times in the props are UTC; the series are in Pacific time.
pub const calendar_fixture = struct {
    const A = namemap.PSETID_Appointment;
    // named properties of the items, as the name map of the new file will have them
    const location = 0x8000;
    const start = 0x8001;
    const end = 0x8002;
    const all_day = 0x8003;
    const recurring = 0x8004;
    const recur_blob = 0x8005;
    const tz = 0x8006;
    const names = [_]namemap.Named{
        .{ .id = location, .guid = A, .dispid = 0x8208 },
        .{ .id = start, .guid = A, .dispid = 0x820D },
        .{ .id = end, .guid = A, .dispid = 0x820E },
        .{ .id = all_day, .guid = A, .dispid = 0x8215 },
        .{ .id = recurring, .guid = A, .dispid = 0x8223 },
        .{ .id = recur_blob, .guid = A, .dispid = 0x8216 },
        .{ .id = tz, .guid = A, .dispid = 0x8233 },
    };

    fn text(a: std.mem.Allocator, id: u16, s: []const u8) !pst.Prop {
        const w = try std.unicode.utf8ToUtf16LeAlloc(a, s);
        return .{ .id = id, .ptype = pst.PT.unicode, .data = std.mem.sliceAsBytes(w) };
    }
    fn time(a: std.mem.Allocator, id: u16, unix: i64) !pst.Prop {
        const b = try a.alloc(u8, 8);
        std.mem.writeInt(u64, b[0..8], @intCast((unix + 11644473600) * 10_000_000), .little);
        return .{ .id = id, .ptype = pst.PT.systime, .data = b };
    }
    fn flag(a: std.mem.Allocator, id: u16, v: bool) !pst.Prop {
        const b = try a.alloc(u8, 2);
        b[0] = @intFromBool(v);
        b[1] = 0;
        return .{ .id = id, .ptype = pst.PT.boolean, .data = b };
    }
    fn bin(id: u16, b: []const u8) pst.Prop {
        return .{ .id = id, .ptype = pst.PT.binary, .data = b };
    }

    /// Unix seconds of a UTC date and time.
    fn utc(y: i64, m: u8, d: u8, hh: i64, mm: i64) i64 {
        return (recur.dayOf(y, m, d) - recur.dayOf(1970, 1, 1)) * 86400 + hh * 3600 + mm * 60;
    }

    fn item(a: std.mem.Allocator, subject: []const u8, where: []const u8, s: i64, e: i64, whole_day: bool, blob: ?[]const u8) ![]const pst.Prop {
        var p: std.ArrayList(pst.Prop) = .empty;
        try p.append(a, try text(a, 0x001A, "IPM.Appointment"));
        try p.append(a, try text(a, 0x0037, subject));
        try p.append(a, try time(a, 0x0039, s));
        try p.append(a, try text(a, location, where));
        try p.append(a, try time(a, start, s));
        try p.append(a, try time(a, end, e));
        try p.append(a, try flag(a, all_day, whole_day));
        try p.append(a, try flag(a, recurring, blob != null));
        if (blob) |b| {
            try p.append(a, bin(recur_blob, b));
            try p.append(a, bin(tz, &recur.example_tz));
        }
        return p.items;
    }

    pub fn extra(a: std.mem.Allocator) !pstwrite.Extra {
        const items = [_][]const pst.Prop{
            // 4.1.1.2: Mon/Thu/Fri 10:00-10:30 PDT from 2007-03-26, 12 times, 2007-04-16 moved to 11:00
            try item(a, "Simple Recurrence", "34/4639", utc(2007, 3, 26, 17, 0), utc(2007, 3, 26, 17, 30), false, &recur.example_weekly_exc),
            // 4.1.1.3: every 3 days 08:00-08:30 PDT, 2011-04-07 to 05-04, two deleted
            try item(a, "Every three days", "Room 1", utc(2011, 4, 7, 15, 0), utc(2011, 4, 7, 15, 30), false, &recur.example_daily),
            // 4.1.1.4: third weekend day every 3 months 14:00-17:00, from 2008-02-09 (PST)
            try item(a, "Quarterly weekend", "Hall", utc(2008, 2, 9, 22, 0), utc(2008, 2, 10, 1, 0), false, &recur.example_month_nth),
            // 4.1.1.5: every April 19 08:00-08:30 PDT from 2011, no end
            try item(a, "Every April 19", "", utc(2011, 4, 19, 15, 0), utc(2011, 4, 19, 15, 30), false, &recur.example_yearly),
            // 4.1.1.6: Hebrew lunar calendar (shown once, at its start)
            try item(a, "Hebrew calendar", "", utc(2011, 4, 7, 15, 0), utc(2011, 4, 7, 15, 30), false, &recur.example_hebrew),
            // single appointments
            try item(a, "Planning meeting", "Room 2", utc(2008, 5, 20, 16, 0), utc(2008, 5, 20, 17, 30), false, null),
            try item(a, "Company holiday", "", utc(2008, 5, 23, 7, 0), utc(2008, 5, 24, 7, 0), true, null),
        };
        return .{ .name = "Calendar", .class = "IPF.Appointment", .names = .{ .entries = @constCast(&names) }, .items = try a.dupe([]const pst.Prop, &items) };
    }
};

test "PST writer: a calendar folder gives testdata/calendar.pst byte for byte" {
    // The calendar view's test mailbox: the Drafts of the demo mailbox and a Calendar folder of
    // `calendar_fixture`. As with demo.pst, a changed file is kept to copy over when intended:
    // `cp .zig-cache/exportcheck-calendar.pst testdata/calendar.pst`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    mime.charset_hook = &platform.charsetToUtf8;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try store.Store.open(gpa, io, demo ++ "/Drafts.mbox");
    defer f.close();
    const out = ".zig-cache/exportcheck-calendar.pst";
    const stats = try pstwrite.exportStore(gpa, io, f, out, .{ .display_name = "calendar", .uid_seed = "testdata/calendar", .extra = try calendar_fixture.extra(a) }, a);
    try std.testing.expectEqual(@as(usize, 0), stats.failed);
    const got = try Io.Dir.cwd().readFileAlloc(io, out, a, .limited(16 << 20));
    const want = Io.Dir.cwd().readFileAlloc(io, "testdata/calendar.pst", a, .limited(16 << 20)) catch &.{};
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("the PST writer's output differs from testdata/calendar.pst ({d} / {d} bytes); kept as {s}\n", .{ got.len, want.len, out });
        return error.PstOutputChanged;
    }
    Io.Dir.cwd().deleteFile(io, out) catch {};
}
