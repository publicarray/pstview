//! Calendar, contact, task, note and journal fields of an item, as label/value rows for the
//! preview, the message window, the HTML view and `pstx show`. Most of these fields are named
//! properties, resolved through the PST's name-to-id map ([MS-OXPROPS] property ids).

const std = @import("std");
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
const nm = @import("namemap.zig");
const recur = @import("recur.zig");

pub const Row = struct { label: []const u8, value: []const u8 };
pub const TimeFmt = *const fn (buf: []u8, t: ?i64) []const u8;

const Rows = struct {
    a: Allocator,
    m: *const pst.Message,
    map: nm.NameMap,
    fmt: TimeFmt,
    list: std.ArrayList(Row) = .empty,

    fn add(self: *Rows, label: []const u8, value: []const u8) void {
        if (value.len == 0) return;
        self.list.append(self.a, .{ .label = label, .value = value }) catch {};
    }
    fn named(self: *Rows, g: nm.Guid, dispid: u32) ?pst.Prop {
        const id = self.map.find(g, dispid) orelse return null;
        return self.m.pc.find(id);
    }
    fn tagged(self: *Rows, id: u16) ?pst.Prop {
        return self.m.pc.find(id);
    }
    fn str(self: *Rows, p: ?pst.Prop) []const u8 {
        const v = p orelse return "";
        return std.mem.trim(u8, pst.propToString(self.a, v.ptype, v.data) catch "", " \r\n\t");
    }
    fn int(_: *Rows, p: ?pst.Prop) ?i64 {
        const v = p orelse return null;
        return pst.propToInt(v.ptype, v.data);
    }
    fn flag(self: *Rows, p: ?pst.Prop) bool {
        return (self.int(p) orelse 0) != 0;
    }
    fn time(self: *Rows, p: ?pst.Prop) []const u8 {
        const v = p orelse return "";
        if (v.ptype != pst.PT.systime or v.data.len < 8) return "";
        const t = pst.filetimeToUnix(pst.rd64(v.data, 0)) orelse return "";
        const buf = self.a.alloc(u8, 96) catch return "";
        return self.fmt(buf, t);
    }
    fn addStr(self: *Rows, label: []const u8, p: ?pst.Prop) void {
        self.add(label, self.str(p));
    }
    fn addTime(self: *Rows, label: []const u8, p: ?pst.Prop) void {
        self.add(label, self.time(p));
    }
    fn pick(self: *Rows, label: []const u8, p: ?pst.Prop, names: []const []const u8) void {
        const v = self.int(p) orelse return;
        if (v < 0 or v >= names.len) {
            self.add(label, std.fmt.allocPrint(self.a, "{d}", .{v}) catch "");
        } else self.add(label, names[@intCast(v)]);
    }
    fn minutes(self: *Rows, label: []const u8, p: ?pst.Prop) void {
        const v = self.int(p) orelse return;
        const h = @divTrunc(v, 60);
        const mi = @mod(v, 60);
        self.add(label, (if (h > 0 and mi > 0) std.fmt.allocPrint(self.a, "{d} h {d} min", .{ h, mi }) else if (h > 0) std.fmt.allocPrint(self.a, "{d} h", .{h}) else std.fmt.allocPrint(self.a, "{d} min", .{mi})) catch "");
    }
    fn recipients(self: *Rows, label: []const u8, kind: i64) void {
        var out: std.ArrayList(u8) = .empty;
        for (self.m.recipients) |r| if (r.kind == kind) {
            if (out.items.len > 0) out.appendSlice(self.a, "; ") catch {};
            out.print(self.a, "{s}{s}{s}{s}", .{ r.name, if (r.email.len > 0) " <" else "", r.email, if (r.email.len > 0) ">" else "" }) catch {};
        };
        self.add(label, out.items);
    }
};

/// Item-type specific rows (empty for plain e-mail apart from the common fields).
pub fn rows(a: Allocator, m: *const pst.Message, fmt_time: TimeFmt) []Row {
    var r: Rows = .{ .a = a, .m = m, .map = if (m.node) |n| n.pst.nameMap() else .{}, .fmt = fmt_time };
    const cls = m.pc.string(a, pst.Tag.message_class) catch "";
    const ic = std.ascii.startsWithIgnoreCase;
    if (ic(cls, "IPM.Appointment") or ic(cls, "IPM.Schedule.Meeting")) {
        appointment(&r, cls);
    } else if (ic(cls, "IPM.Contact")) {
        contact(&r);
    } else if (ic(cls, "IPM.DistList")) {
        r.addStr("List name", r.tagged(0x3001));
        r.recipients("Members", 1);
    } else if (ic(cls, "IPM.Task")) {
        task(&r);
    } else if (ic(cls, "IPM.StickyNote")) {
        r.pick("Note colour", r.named(nm.PSETID_Note, 0x8B00), &.{ "Blue", "Green", "Pink", "Yellow", "White" });
    } else if (ic(cls, "IPM.Activity")) {
        r.addStr("Journal type", r.named(nm.PSETID_Log, 0x8712));
        if (r.list.items.len == 0) r.addStr("Journal type", r.named(nm.PSETID_Log, 0x8700));
        r.addTime("Start", r.named(nm.PSETID_Log, 0x8706));
        r.addTime("End", r.named(nm.PSETID_Log, 0x8708));
        r.minutes("Duration", r.named(nm.PSETID_Log, 0x8707));
    }
    common(&r);
    return r.list.items;
}

fn appointment(r: *Rows, cls: []const u8) void {
    const A = nm.PSETID_Appointment;
    const all_day = r.flag(r.named(A, 0x8215));
    r.addTime("Start", r.named(A, 0x820D));
    r.addTime("End", r.named(A, 0x820E));
    if (all_day) r.add("All-day event", "yes");
    r.minutes("Duration", r.named(A, 0x8213));
    r.addStr("Location", r.named(A, 0x8208));
    if (r.flag(r.named(A, 0x8223))) {
        var pattern = r.str(r.named(A, 0x8232));
        if (pattern.len == 0) if (r.named(A, 0x8216)) |blob| {
            if (recur.parse(r.a, blob.data)) |p| pattern = recur.describe(r.a, p) catch "" else |_| {}
        };
        r.add("Recurrence", if (pattern.len > 0) pattern else "recurring (pattern not described)");
    }
    r.addStr("Time zone", r.named(A, 0x8234));
    r.pick("Show as", r.named(A, 0x8205), &.{ "Free", "Tentative", "Busy", "Out of office", "Working elsewhere" });
    if (r.int(r.named(A, 0x8217))) |st| if (st & 1 != 0) {
        r.add("Meeting", if (st & 4 != 0) "cancelled" else if (st & 2 != 0) "received (attendee copy)" else "organised by the mailbox owner");
    };
    r.pick("Response", r.named(A, 0x8218), &.{ "None", "Organiser", "Tentative", "Accepted", "Declined", "Not responded" });
    if (std.ascii.findIgnoreCase(cls, "Meeting") != null or r.m.recipients.len > 0) {
        const org = r.m.senderName(r.a) catch "";
        r.add("Organiser", org);
        r.recipients("Required", 1);
        r.recipients("Optional", 2);
        r.recipients("Resources", 3);
    }
}

fn contact(r: *Rows) void {
    const C = nm.PSETID_Address;
    r.addStr("Full name", r.tagged(0x3001));
    r.addStr("File as", r.named(C, 0x8005));
    var name: std.ArrayList(u8) = .empty;
    for ([_]u16{ 0x3A45, 0x3A06, 0x3A44, 0x3A11, 0x3A05 }) |id| {
        const s = r.str(r.tagged(id));
        if (s.len == 0) continue;
        if (name.items.len > 0) name.append(r.a, ' ') catch {};
        name.appendSlice(r.a, s) catch {};
    }
    r.add("Name", name.items);
    r.addStr("Nickname", r.tagged(0x3A4F));
    r.addStr("Company", r.tagged(0x3A16));
    r.addStr("Job title", r.tagged(0x3A17));
    r.addStr("Department", r.tagged(0x3A18));
    r.addStr("Office", r.tagged(0x3A19));
    r.addStr("Manager", r.tagged(0x3A4E));
    r.addStr("Assistant", r.tagged(0x3A30));
    for ([_]struct { []const u8, u32, u32 }{ .{ "E-mail", 0x8080, 0x8083 }, .{ "E-mail 2", 0x8090, 0x8093 }, .{ "E-mail 3", 0x80A0, 0x80A3 } }) |e| {
        const disp = r.str(r.named(C, e[1]));
        const addr = r.str(r.named(C, e[2]));
        if (addr.len == 0) continue;
        r.add(e[0], if (disp.len > 0 and !std.mem.eql(u8, disp, addr)) std.fmt.allocPrint(r.a, "{s} <{s}>", .{ disp, addr }) catch addr else addr);
    }
    const phones = [_]struct { []const u8, u16 }{
        .{ "Business phone", 0x3A08 },  .{ "Business phone 2", 0x3A1B }, .{ "Mobile", 0x3A1C },      .{ "Home phone", 0x3A09 },
        .{ "Primary phone", 0x3A1A },   .{ "Business fax", 0x3A24 },     .{ "Home fax", 0x3A25 },    .{ "Pager", 0x3A21 },
        .{ "Assistant phone", 0x3A2E }, .{ "Car phone", 0x3A1E },        .{ "Other phone", 0x3A1F },
    };
    for (phones) |p| r.addStr(p[0], r.tagged(p[1]));
    r.addStr("Business address", r.named(C, 0x801B));
    r.addStr("Home address", r.named(C, 0x801A));
    r.addStr("Other address", r.named(C, 0x801C));
    if (r.named(C, 0x801B) == null) {
        var addr: std.ArrayList(u8) = .empty;
        for ([_]u16{ 0x3A29, 0x3A27, 0x3A28, 0x3A2A, 0x3A26 }) |id| {
            const s = r.str(r.tagged(id));
            if (s.len == 0) continue;
            if (addr.items.len > 0) addr.appendSlice(r.a, ", ") catch {};
            addr.appendSlice(r.a, s) catch {};
        }
        r.add("Address", addr.items);
    }
    r.addStr("Web page", r.tagged(0x3A51));
    r.addStr("Personal web page", r.tagged(0x3A50));
    r.addStr("IM address", r.named(C, 0x8062));
    r.addTime("Birthday", r.tagged(0x3A42));
    r.addTime("Anniversary", r.tagged(0x3A41));
    r.addStr("Spouse / partner", r.tagged(0x3A48));
}

fn task(r: *Rows) void {
    const T = nm.PSETID_Task;
    r.pick("Status", r.named(T, 0x8101), &.{ "Not started", "In progress", "Completed", "Waiting on someone else", "Deferred" });
    if (r.named(T, 0x8102)) |p| if (p.ptype == pst.PT.float64 and p.data.len >= 8) {
        const v: f64 = @bitCast(pst.rd64(p.data, 0));
        r.add("% complete", std.fmt.allocPrint(r.a, "{d:.0}%", .{v * 100}) catch "");
    };
    r.addTime("Start", r.named(T, 0x8104));
    r.addTime("Due", r.named(T, 0x8105));
    r.addTime("Completed", r.named(T, 0x810F));
    r.addStr("Owner", r.named(T, 0x811F));
    r.addStr("Assigned by", r.named(T, 0x8121));
}

fn common(r: *Rows) void {
    if (r.map.findName(nm.PS_PUBLIC_STRINGS, "Keywords")) |id| if (r.m.pc.find(id)) |p| {
        r.add("Categories", multiString(r.a, p));
    };
    if (r.int(r.tagged(0x0017))) |imp| if (imp != 1) r.add("Importance", if (imp == 0) "Low" else "High");
    r.pick("Sensitivity", r.tagged(0x0036), &.{ "", "Personal", "Private", "Confidential" });
    if (r.int(r.tagged(0x1090))) |fs| if (fs != 0) {
        const req = r.str(r.named(nm.PSETID_Common, 0x8530));
        r.add("Follow-up flag", if (fs == 1) "completed" else if (req.len > 0) req else "flagged");
        r.addTime("Flag completed", r.tagged(0x1091));
    };
    if (r.flag(r.named(nm.PSETID_Common, 0x8503))) {
        const t = r.time(r.named(nm.PSETID_Common, 0x8502));
        r.add("Reminder", if (t.len > 0) t else "set");
    }
}

/// PT_MV_UNICODE / PT_MV_STRING8 as "a; b; c" (count, offsets, then the strings).
pub fn multiString(a: Allocator, p: pst.Prop) []const u8 {
    const d = p.data;
    if (d.len < 4) return "";
    const n = pst.rd32(d, 0);
    if (n == 0 or 4 + @as(usize, n) * 4 > d.len) return "";
    var out: std.ArrayList(u8) = .empty;
    for (0..n) |i| {
        const s: usize = pst.rd32(d, 4 + i * 4);
        const e: usize = if (i + 1 < n) pst.rd32(d, 4 + (i + 1) * 4) else d.len;
        if (s > e or e > d.len) break;
        const v = if (p.ptype == pst.PT.mv_flag | pst.PT.unicode) pst.utf16ToUtf8(a, d[s..e]) catch "" else pst.latin1ToUtf8(a, d[s..e]) catch "";
        if (out.items.len > 0) out.appendSlice(a, "; ") catch {};
        out.appendSlice(a, v) catch {};
    }
    return out.items;
}

// ================================================================ tests

const testing = std.testing;

test "multi-value strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // count 2, offsets 12 and 16, "Ab" "C" in UTF-16LE
    const d = [_]u8{ 2, 0, 0, 0, 12, 0, 0, 0, 16, 0, 0, 0, 'A', 0, 'b', 0, 'C', 0 };
    try testing.expectEqualStrings("Ab; C", multiString(arena.allocator(), .{ .id = 0x8000, .ptype = 0x101F, .data = &d }));
}
