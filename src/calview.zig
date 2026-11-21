//! The calendar view's data: an item's appointment fields, and its occurrences in a time range
//! (a recurring series expanded with src/recur.zig). Timed occurrences are in UTC; all-day ones
//! are dates, so that they stay on their day whatever the viewer's time zone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
const nm = @import("namemap.zig");
const recur = @import("recur.zig");

pub const Appt = struct {
    nid: u32,
    subject: []const u8,
    location: []const u8,
    /// Unix seconds (UTC).
    start: i64,
    end: i64,
    all_day: bool,
    recurring: bool,
    pattern: ?recur.Pattern = null,
    tz: ?recur.TimeZone = null,
};

pub const Occurrence = struct {
    /// Unix seconds (UTC); for all-day items, midnight UTC of the first day.
    start: i64,
    end: i64,
    all_day: bool,
    /// All-day items: first day and the day after the last, as days since 1601-01-01.
    day0: i64 = 0,
    day1: i64 = 0,
    subject: []const u8,
    location: []const u8,
    recurring: bool,
    /// A changed instance of a series.
    exception: bool = false,
};

fn named(m: *const pst.Message, map: nm.NameMap, dispid: u32) ?pst.Prop {
    const id = map.find(nm.PSETID_Appointment, dispid) orelse return null;
    return m.pc.find(id);
}

fn timeOf(p: ?pst.Prop) ?i64 {
    const v = p orelse return null;
    if (v.ptype != pst.PT.systime or v.data.len < 8) return null;
    return pst.filetimeToUnix(pst.rd64(v.data, 0));
}

fn flagOf(p: ?pst.Prop) bool {
    const v = p orelse return false;
    return (pst.propToInt(v.ptype, v.data) orelse 0) != 0;
}

/// The appointment fields of a calendar item, or null when it has no start time.
pub fn load(a: Allocator, m: *const pst.Message) ?Appt {
    const node = m.node orelse return null;
    const map = node.pst.nameMap();
    const start = timeOf(named(m, map, 0x820D)) orelse return null;
    const end = timeOf(named(m, map, 0x820E)) orelse start;
    var appt: Appt = .{
        .nid = m.nid,
        .subject = m.subject(a) catch "",
        .location = blk: {
            const p = named(m, map, 0x8208) orelse break :blk "";
            break :blk std.mem.trim(u8, pst.propToString(a, p.ptype, p.data) catch "", " \r\n\t");
        },
        .start = start,
        .end = @max(end, start),
        .all_day = flagOf(named(m, map, 0x8215)),
        .recurring = flagOf(named(m, map, 0x8223)),
    };
    if (named(m, map, 0x8216)) |p| if (p.ptype == pst.PT.binary) {
        appt.recurring = true;
        appt.pattern = recur.parse(a, p.data) catch null;
    };
    if (named(m, map, 0x8233)) |p| if (p.ptype == pst.PT.binary) {
        appt.tz = recur.TimeZone.parse(p.data);
    };
    return appt;
}

const day_s: i64 = 86400;
const days_1601_to_1970: i64 = 134774;
const epoch_min: i64 = 194074560;

/// The date of an all-day item from its stored start: midnight in the time zone it was made in.
/// That is the morning (UTC) of the same day west of Greenwich, and the afternoon or evening of
/// the day before east of it.
pub fn allDayDate(unix: i64) i64 {
    const tod = @mod(unix, day_s);
    return @divFloor(unix, day_s) + @as(i64, if (tod >= 12 * 3600) 1 else 0) + days_1601_to_1970;
}

fn dayStart(day: i64) i64 {
    return (day - days_1601_to_1970) * day_s;
}

/// Occurrences of `appt` that overlap [from, to) (Unix seconds; all-day items by their dates,
/// with a day's margin on each side for the viewer's time zone).
pub fn occurrences(a: Allocator, appt: Appt, from: i64, to: i64, out: *std.ArrayList(Occurrence)) !void {
    const base: Occurrence = .{ .start = appt.start, .end = appt.end, .all_day = appt.all_day, .subject = appt.subject, .location = appt.location, .recurring = appt.recurring };
    expanded: {
        const p = appt.pattern orelse break :expanded;
        const from_day = @divFloor(@divFloor(from, 60) + epoch_min, recur.min_per_day) - 2;
        const to_day = @divFloor(@divFloor(to, 60) + epoch_min, recur.min_per_day) + 2;
        const list = recur.expand(a, p, from_day, to_day) catch break :expanded;
        // without a time zone: the offset between the series' first local start and its UTC start
        const first_local = @as(i64, p.start_date) + p.start_offset;
        const offset = first_local - (@divFloor(appt.start, 60) + epoch_min);
        for (list) |o| {
            var occ = base;
            occ.exception = o.exception != null;
            if (o.exception) |i| {
                const e = p.exceptions[i];
                if (e.subject) |s| occ.subject = s;
                if (e.location) |l| occ.location = l;
            }
            if (appt.all_day) {
                occ.day0 = @divFloor(o.start, recur.min_per_day);
                occ.day1 = @max(occ.day0 + 1, @divFloor(o.end + recur.min_per_day - 1, recur.min_per_day));
                occ.start = dayStart(occ.day0);
                occ.end = dayStart(occ.day1);
            } else {
                occ.start = if (appt.tz) |tz| tz.toUnix(o.start) else recur.fixedToUnix(o.start, offset);
                occ.end = if (appt.tz) |tz| tz.toUnix(o.end) else recur.fixedToUnix(o.end, offset);
            }
            if (occ.end < from - day_s or occ.start >= to + day_s) continue;
            try out.append(a, occ);
        }
        return;
    }
    // a single item, or a series that cannot be expanded (shown at its first start)
    var occ = base;
    if (appt.all_day) {
        occ.day0 = allDayDate(appt.start);
        occ.day1 = @max(occ.day0 + 1, allDayDate(appt.end));
        occ.start = dayStart(occ.day0);
        occ.end = dayStart(occ.day1);
    }
    if (occ.end < from - day_s or occ.start >= to + day_s) return;
    try out.append(a, occ);
}

test "a recurring all-day series stays on its dates, the moved instance too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // every April 19 ([MS-OXOCAL] 4.1.1.5, the 2012 instance moved to April 21), as an all-day series
    var p = try recur.parse(a, &recur.example_yearly);
    p.start_offset = 0;
    p.end_offset = 1440;
    for (p.exceptions) |*e| {
        e.start = @divFloor(e.start, recur.min_per_day) * recur.min_per_day;
        e.end = e.start + recur.min_per_day;
    }
    const appt: Appt = .{ .nid = 1, .subject = "Birthday", .location = "", .start = 0, .end = 0, .all_day = true, .recurring = true, .pattern = p, .tz = recur.TimeZone.parse(&recur.example_tz) };
    const year = struct {
        fn of(y: i64) i64 {
            return (recur.dayOf(y, 1, 1) - days_1601_to_1970) * day_s;
        }
    }.of;
    var out: std.ArrayList(Occurrence) = .empty;
    try occurrences(a, appt, year(2012), year(2014), &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(recur.dayOf(2012, 4, 21), out.items[0].day0);
    try std.testing.expectEqual(recur.dayOf(2012, 4, 22), out.items[0].day1);
    try std.testing.expect(out.items[0].exception);
    try std.testing.expectEqual(recur.dayOf(2013, 4, 19), out.items[1].day0);
    try std.testing.expectEqual(recur.dayOf(2013, 4, 20), out.items[1].day1);
    try std.testing.expect(out.items[1].all_day);
}
