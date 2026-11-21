//! Recurring appointments ([MS-OXOCAL] 2.2.1.44): the AppointmentRecurrencePattern of
//! PidLidAppointmentRecur, expanded to the occurrences that fall in a range of days, and the
//! time zone of PidLidTimeZoneStruct (2.2.1.39) to turn their local times into UTC.
//!
//! Times in the pattern are minutes since midnight, January 1, 1601, in the series' own time zone
//! ("local minutes" here). Gregorian calendars only: other calendar types (Hijri, Hebrew, ...)
//! are reported as unsupported, and the caller shows the series at its first start.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const min_per_day: i64 = 1440;
/// Minutes between 1601-01-01 and 1970-01-01.
const unix_epoch_min: i64 = 194074560;
/// EndDate of a series without an end.
const no_end_date: u32 = 0x5AE980DF;

pub const Error = error{ Truncated, Unsupported, Invalid, OutOfMemory };

pub const Exception = struct {
    start: i64,
    end: i64,
    /// The start the instance had in the series (its date is in the deleted list).
    original: i64,
    subject: ?[]const u8 = null,
    location: ?[]const u8 = null,
};

pub const Pattern = struct {
    freq: u16,
    ptype: u16,
    calendar: u16,
    first_datetime: u32,
    period: u32,
    /// Week / MonthNth: day mask (bit 0 Sunday); Month / MonthEnd: day of the month.
    specific: u32 = 0,
    /// MonthNth: 1..4, 5 = last.
    nth: u32 = 0,
    end_type: u32,
    occurrences: u32,
    first_dow: u32,
    deleted: []const u32,
    modified: []const u32,
    start_date: u32,
    end_date: u32,
    start_offset: u32,
    end_offset: u32,
    exceptions: []Exception,

    pub fn endless(self: Pattern) bool {
        return self.end_type != 0x2021 and self.end_type != 0x2022 or self.end_date == no_end_date;
    }
};

const Reader = struct {
    b: []const u8,
    i: usize = 0,
    fn u16_(r: *Reader) Error!u16 {
        if (r.b.len - r.i < 2) return error.Truncated;
        defer r.i += 2;
        return std.mem.readInt(u16, r.b[r.i..][0..2], .little);
    }
    fn u32_(r: *Reader) Error!u32 {
        if (r.b.len - r.i < 4) return error.Truncated;
        defer r.i += 4;
        return std.mem.readInt(u32, r.b[r.i..][0..4], .little);
    }
    fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (r.b.len - r.i < n) return error.Truncated;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
    fn dates(r: *Reader, a: Allocator, n: u32) Error![]u32 {
        if (n > (r.b.len - r.i) / 4) return error.Truncated;
        const out = try a.alloc(u32, n);
        for (out) |*d| d.* = try r.u32_();
        return out;
    }
};

fn latin1(a: Allocator, b: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (b) |c| {
        if (c < 0x80) try out.append(a, c) else {
            try out.append(a, 0xC0 | (c >> 6));
            try out.append(a, 0x80 | (c & 0x3F));
        }
    }
    return out.items;
}

fn utf16le(a: Allocator, b: []const u8) Error![]const u8 {
    const n = b.len / 2;
    const units = try a.alloc(u16, n);
    for (units, 0..) |*u, k| u.* = std.mem.readInt(u16, b[k * 2 ..][0..2], .little);
    return std.unicode.utf16LeToUtf8Alloc(a, units) catch latin1(a, b);
}

/// Parse an AppointmentRecurrencePattern. Exception subjects / locations are UTF-8.
pub fn parse(a: Allocator, blob: []const u8) Error!Pattern {
    var r: Reader = .{ .b = blob };
    _ = try r.u16_(); // ReaderVersion 0x3004
    _ = try r.u16_(); // WriterVersion
    var p: Pattern = .{
        .freq = try r.u16_(),
        .ptype = try r.u16_(),
        .calendar = try r.u16_(),
        .first_datetime = try r.u32_(),
        .period = try r.u32_(),
        .end_type = 0,
        .occurrences = 0,
        .first_dow = 0,
        .deleted = &.{},
        .modified = &.{},
        .start_date = 0,
        .end_date = 0,
        .start_offset = 0,
        .end_offset = 0,
        .exceptions = &.{},
    };
    _ = try r.u32_(); // SlidingFlag
    switch (p.ptype) {
        0x0 => {},
        0x1 => p.specific = try r.u32_(),
        0x2, 0x4, 0xA, 0xC => p.specific = try r.u32_(),
        0x3, 0xB => {
            p.specific = try r.u32_();
            p.nth = try r.u32_();
        },
        else => return error.Invalid,
    }
    p.end_type = try r.u32_();
    p.occurrences = try r.u32_();
    p.first_dow = try r.u32_();
    p.deleted = try r.dates(a, try r.u32_());
    p.modified = try r.dates(a, try r.u32_());
    p.start_date = try r.u32_();
    p.end_date = try r.u32_();
    _ = try r.u32_(); // ReaderVersion2 0x3006
    const writer2 = try r.u32_();
    p.start_offset = try r.u32_();
    p.end_offset = try r.u32_();
    const count = try r.u16_();
    if (count > (r.b.len - r.i) / 14) return error.Truncated;
    const ex = try a.alloc(Exception, count);
    const flags = try a.alloc(u16, count);
    for (ex, flags) |*e, *fl| {
        e.* = .{ .start = try r.u32_(), .end = try r.u32_(), .original = try r.u32_() };
        fl.* = try r.u16_();
        if (fl.* & 0x0001 != 0) {
            _ = try r.u16_();
            const n = try r.u16_();
            e.subject = try latin1(a, try r.bytes(n));
        }
        if (fl.* & 0x0002 != 0) _ = try r.u32_(); // MeetingType
        if (fl.* & 0x0004 != 0) _ = try r.u32_(); // ReminderDelta
        if (fl.* & 0x0008 != 0) _ = try r.u32_(); // ReminderSet
        if (fl.* & 0x0010 != 0) {
            _ = try r.u16_();
            const n = try r.u16_();
            e.location = try latin1(a, try r.bytes(n));
        }
        if (fl.* & 0x0020 != 0) _ = try r.u32_(); // BusyStatus
        if (fl.* & 0x0040 != 0) _ = try r.u32_(); // Attachment
        if (fl.* & 0x0080 != 0) _ = try r.u32_(); // SubType
        if (fl.* & 0x0100 != 0) _ = try r.u32_(); // AppointmentColor
    }
    p.exceptions = ex;
    // The Unicode subjects and locations come after; the pattern is usable without them.
    extended: {
        const rb1 = r.u32_() catch break :extended;
        _ = r.bytes(rb1) catch break :extended;
        for (ex, flags) |*e, fl| {
            if (writer2 >= 0x3009) {
                const n = r.u32_() catch break :extended;
                _ = r.bytes(n) catch break :extended;
            }
            const ee1 = r.u32_() catch break :extended;
            _ = r.bytes(ee1) catch break :extended;
            if (fl & 0x0011 == 0) continue;
            _ = r.bytes(12) catch break :extended; // start, end, original start
            if (fl & 0x0001 != 0) {
                const n = r.u16_() catch break :extended;
                e.subject = utf16le(a, r.bytes(@as(usize, n) * 2) catch break :extended) catch e.subject;
            }
            if (fl & 0x0010 != 0) {
                const n = r.u16_() catch break :extended;
                e.location = utf16le(a, r.bytes(@as(usize, n) * 2) catch break :extended) catch e.location;
            }
            const ee2 = r.u32_() catch break :extended;
            _ = r.bytes(ee2) catch break :extended;
        }
    }
    if (p.period == 0) return error.Invalid;
    return p;
}

// ---------------------------------------------------------------- dates (days since 1601-01-01)

pub const Civil = struct { y: i64, m: u8, d: u8 };

/// Days since 1970-01-01 of a Gregorian date (Howard Hinnant's algorithm).
fn daysFromCivil(y_: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_ - 1 else y_;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z_: i64) Civil {
    const z = z_ + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

const days_1601_to_1970: i64 = 134774;

pub fn civil(day: i64) Civil {
    return civilFromDays(day - days_1601_to_1970);
}
pub fn dayOf(y: i64, m: u8, d: u8) i64 {
    return daysFromCivil(y, m, d) + days_1601_to_1970;
}
/// 0 = Sunday (1601-01-01 was a Monday).
pub fn weekday(day: i64) u3 {
    return @intCast(@mod(day + 1, 7));
}
fn daysInMonth(y: i64, m: u8) u8 {
    return switch (m) {
        4, 6, 9, 11 => 30,
        2 => if (@mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0)) 29 else 28,
        else => 31,
    };
}
fn monthIndex(day: i64) i64 {
    const c = civil(day);
    return (c.y - 1601) * 12 + c.m - 1;
}

/// The day a monthly pattern falls on in month `mi` (months since January 1601), or null.
fn dayInMonth(p: Pattern, mi: i64) ?i64 {
    const y = 1601 + @divFloor(mi, 12);
    const m: u8 = @intCast(@mod(mi, 12) + 1);
    const dim = daysInMonth(y, m);
    const first = dayOf(y, m, 1);
    switch (p.ptype) {
        0x2 => return first + @min(@max(p.specific, 1), dim) - 1,
        0x4 => return first + dim - 1,
        0x3 => {
            const mask = p.specific & 0x7F;
            if (mask == 0) return null;
            if (p.nth >= 5) {
                var k: i64 = dim - 1;
                while (k >= 0) : (k -= 1) if (mask & (@as(u32, 1) << weekday(first + k)) != 0) return first + k;
                return null;
            }
            var seen: u32 = 0;
            var k: i64 = 0;
            while (k < dim) : (k += 1) if (mask & (@as(u32, 1) << weekday(first + k)) != 0) {
                seen += 1;
                if (seen == p.nth) return first + k;
            };
            return null;
        },
        else => return null,
    }
}

pub const Occurrence = struct {
    /// Local minutes since 1601.
    start: i64,
    end: i64,
    /// Index into `exceptions` for a modified instance.
    exception: ?usize = null,
};

fn contains(list: []const u32, day: i64) bool {
    for (list) |d| if (@divFloor(@as(i64, d), min_per_day) == day) return true;
    return false;
}

/// The occurrences of the series that start on days in [from_day, to_day): the instances of the
/// pattern without the deleted ones, and the modified ones at their new times.
pub fn expand(a: Allocator, p: Pattern, from_day: i64, to_day: i64) Error![]Occurrence {
    switch (p.calendar) {
        0, 1, 2, 9, 10, 11, 12 => {},
        else => return error.Unsupported,
    }
    if (p.ptype >= 0xA) return error.Unsupported;
    var out: std.ArrayList(Occurrence) = .empty;
    const start_day = @divFloor(@as(i64, p.start_date), min_per_day);
    const end_day: i64 = if (p.endless()) std.math.maxInt(i64) else @divFloor(@as(i64, p.end_date), min_per_day);
    const count_limit: u64 = if (p.end_type == 0x2022 and p.end_date != no_end_date) p.occurrences else std.math.maxInt(u64);
    const dur = @as(i64, p.end_offset) - @as(i64, p.start_offset);

    var count: u64 = 0;
    var steps: u32 = 0;
    const State = struct {
        fn emit(o: *std.ArrayList(Occurrence), al: Allocator, pp: Pattern, day: i64, f: i64, t: i64, d: i64) Error!void {
            if (day < f or day >= t or contains(pp.deleted, day)) return;
            const s = day * min_per_day + pp.start_offset;
            try o.append(al, .{ .start = s, .end = s + d });
        }
    };
    switch (p.ptype) {
        0x0 => { // every n days
            const pd = @max(@divFloor(@as(i64, p.period), min_per_day), 1);
            var day = start_day;
            while (day <= end_day and day < to_day and count < count_limit and steps < 200000) : (day += pd) {
                steps += 1;
                count += 1;
                try State.emit(&out, a, p, day, from_day, to_day, dur);
            }
        },
        0x1 => { // every n weeks, on the days of the mask
            const mask = p.specific & 0x7F;
            if (mask == 0) return error.Invalid;
            const fdow: i64 = p.first_dow % 7;
            var ws = start_day - @mod(@as(i64, weekday(start_day)) - fdow, 7);
            const span = @as(i64, p.period) * 7;
            // the first valid week ([MS-OXOCAL] 2.2.1.44.1.2)
            const off = @mod(ws * min_per_day - p.first_datetime, span * min_per_day);
            if (off != 0) ws = ws - @divFloor(off, min_per_day) + span;
            outer: while (ws <= end_day and ws < to_day and steps < 200000) : (ws += span) {
                var k: i64 = 0;
                while (k < 7) : (k += 1) {
                    steps += 1;
                    const day = ws + k;
                    if (day < start_day or mask & (@as(u32, 1) << weekday(day)) == 0) continue;
                    if (day > end_day or count >= count_limit) break :outer;
                    count += 1;
                    try State.emit(&out, a, p, day, from_day, to_day, dur);
                }
            }
        },
        0x2, 0x3, 0x4 => { // every n months (yearly: every 12)
            const fdt_month = monthIndex(@divFloor(@as(i64, p.first_datetime), min_per_day));
            var mi = monthIndex(start_day);
            const off = @mod(mi - fdt_month, @as(i64, p.period));
            if (off != 0) mi = mi - off + p.period;
            while (steps < 200000) : (mi += p.period) {
                steps += 1;
                const day = dayInMonth(p, mi) orelse continue;
                if (day < start_day) continue;
                if (day > end_day or day >= to_day or count >= count_limit) break;
                count += 1;
                try State.emit(&out, a, p, day, from_day, to_day, dur);
            }
        },
        else => return error.Unsupported,
    }
    // modified instances, at their new times
    for (p.exceptions, 0..) |e, i| {
        const day = @divFloor(e.start, min_per_day);
        if (day < from_day or day >= to_day) continue;
        try out.append(a, .{ .start = e.start, .end = e.end, .exception = i });
    }
    std.mem.sort(Occurrence, out.items, {}, struct {
        fn lt(_: void, x: Occurrence, y: Occurrence) bool {
            return x.start < y.start;
        }
    }.lt);
    return out.items;
}

/// The pattern in words, e.g. "every week on Monday, Thursday, Friday, 10:00-10:30 (series time),
/// from 2007-03-26, 12 times".
pub fn describe(a: Allocator, p: Pattern) Error![]const u8 {
    const days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const nths = [_][]const u8{ "", "first", "second", "third", "fourth", "last" };
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    var out: std.ArrayList(u8) = .empty;
    const mask_words = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), mask: u32, names: []const []const u8) Error!void {
            if (mask & 0x7F == 0x3E) return o.appendSlice(al, "weekday");
            if (mask & 0x7F == 0x41) return o.appendSlice(al, "weekend day");
            if (mask & 0x7F == 0x7F) return o.appendSlice(al, "day");
            var n: usize = 0;
            for (names, 0..) |d, k| if (mask & (@as(u32, 1) << @intCast(k)) != 0) {
                if (n > 0) try o.appendSlice(al, ", ");
                try o.appendSlice(al, d);
                n += 1;
            };
        }
    }.f;
    const start = civil(@divFloor(@as(i64, p.start_date), min_per_day));
    const yearly = p.freq == 0x200D or p.period == 12 and p.ptype != 0 and p.ptype != 1;
    switch (p.ptype) {
        0x0 => {
            const n = @divFloor(p.period, @as(u32, @intCast(min_per_day)));
            if (n <= 1) try out.appendSlice(a, "every day") else try out.print(a, "every {d} days", .{n});
        },
        0x1 => {
            if (p.period <= 1) try out.appendSlice(a, "every week on ") else try out.print(a, "every {d} weeks on ", .{p.period});
            try mask_words(a, &out, p.specific, &days);
        },
        0x2, 0x4, 0x3 => {
            if (yearly) try out.appendSlice(a, "every year on ") else if (p.period <= 1) try out.appendSlice(a, "every month on ") else try out.print(a, "every {d} months on ", .{p.period});
            switch (p.ptype) {
                0x2 => try out.print(a, "day {d}", .{p.specific}),
                0x4 => try out.appendSlice(a, "the last day"),
                else => {
                    try out.print(a, "the {s} ", .{nths[@min(p.nth, 5)]});
                    try mask_words(a, &out, p.specific, &days);
                },
            }
            if (yearly) try out.print(a, " of {s}", .{months[start.m - 1]});
        },
        else => try out.appendSlice(a, "recurring (calendar not supported)"),
    }
    if (p.calendar > 2 and p.calendar < 9 or p.calendar > 12) try out.appendSlice(a, " (non-Gregorian calendar)");
    if (p.end_offset != p.start_offset) try out.print(a, ", {d:0>2}:{d:0>2}-{d:0>2}:{d:0>2}", .{ p.start_offset / 60, p.start_offset % 60, (p.end_offset / 60) % 24, p.end_offset % 60 });
    try out.print(a, ", from {d}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(start.y)), start.m, start.d });
    if (p.endless()) {
        try out.appendSlice(a, ", no end");
    } else if (p.end_type == 0x2022) {
        try out.print(a, ", {d} times", .{p.occurrences});
    } else {
        const e = civil(@divFloor(@as(i64, p.end_date), min_per_day));
        try out.print(a, " until {d}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(e.y)), e.m, e.d });
    }
    const deleted = p.deleted.len - @min(p.deleted.len, p.modified.len);
    if (p.modified.len > 0) try out.print(a, "; {d} changed", .{p.modified.len});
    if (deleted > 0) try out.print(a, "; {d} deleted", .{deleted});
    return out.items;
}

// ---------------------------------------------------------------- time zone

const SysTime = struct { year: u16, month: u16, dow: u16, day: u16, hour: u16, minute: u16 };

pub const TimeZone = struct {
    bias: i32,
    standard_bias: i32,
    daylight_bias: i32,
    standard: SysTime,
    daylight: SysTime,

    /// PidLidTimeZoneStruct (48 bytes).
    pub fn parse(b: []const u8) ?TimeZone {
        if (b.len < 48) return null;
        const i32_ = struct {
            fn f(x: []const u8, o: usize) i32 {
                return std.mem.readInt(i32, x[o..][0..4], .little);
            }
        }.f;
        const st = struct {
            fn f(x: []const u8, o: usize) SysTime {
                const w = struct {
                    fn g(y: []const u8, q: usize) u16 {
                        return std.mem.readInt(u16, y[q..][0..2], .little);
                    }
                }.g;
                return .{ .year = w(x, o), .month = w(x, o + 2), .dow = w(x, o + 4), .day = w(x, o + 6), .hour = w(x, o + 8), .minute = w(x, o + 10) };
            }
        }.f;
        return .{ .bias = i32_(b, 0), .standard_bias = i32_(b, 4), .daylight_bias = i32_(b, 8), .standard = st(b, 14), .daylight = st(b, 32) };
    }

    /// Local minutes of the transition `t` in year `y`.
    fn transition(t: SysTime, y: i64) i64 {
        const m: u8 = @intCast(@min(@max(t.month, 1), 12));
        const yy: i64 = if (t.year != 0) t.year else y;
        var day: i64 = undefined;
        if (t.year != 0) {
            day = dayOf(yy, m, @intCast(@min(@max(t.day, 1), daysInMonth(yy, m))));
        } else {
            // the wDay-th wDayOfWeek of the month, 5 = the last
            const first = dayOf(yy, m, 1);
            const dim = daysInMonth(yy, m);
            day = first + @mod(@as(i64, t.dow) - weekday(first), 7) + (@as(i64, @max(t.day, 1)) - 1) * 7;
            while (day >= first + dim) day -= 7;
        }
        return day * min_per_day + @as(i64, t.hour) * 60 + t.minute;
    }

    pub fn isDaylight(self: TimeZone, local: i64) bool {
        if (self.daylight.month == 0 or self.standard.month == 0) return false;
        const y = civil(@divFloor(local, min_per_day)).y;
        const ds = transition(self.daylight, y);
        const ss = transition(self.standard, y);
        return if (ds < ss) local >= ds and local < ss else local >= ds or local < ss;
    }

    /// Local minutes (since 1601) to Unix seconds.
    pub fn toUnix(self: TimeZone, local: i64) i64 {
        const bias: i64 = @as(i64, self.bias) + (if (self.isDaylight(local)) self.daylight_bias else self.standard_bias);
        return (local + bias - unix_epoch_min) * 60;
    }
};

/// Minutes since 1601 (UTC) to Unix seconds, for a fixed offset (minutes east of UTC).
pub fn fixedToUnix(local: i64, offset_min: i64) i64 {
    return (local - offset_min - unix_epoch_min) * 60;
}

// ---------------------------------------------------------------- tests ([MS-OXOCAL] 4.1.1)

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

pub const example_weekly = hex("043004300B2001000000C0210000010000000000000032000000222000000C0000000000000000000000000000008020BC0C20ADBC0C0630000009300000580200007602000000000000000000000000");
pub const example_weekly_exc = hex("043004300B2001000000C0210000010000000000000032000000222000000C0000000000000001000000A096BC0C01000000A096BC0C8020BC0C20ADBC0C0630000009300000580200007602000001003499BC0C5299BC0CF898BC0C11002200210053696D706C6520526563757272656E6365207769746820657863657074696F6E73080007003334" ++
    "2F3431343100000000040000000000000000000000" ++ "3499BC0C5299BC0CF898BC0C2100530069006D0070006C0065002000" ++ "52006500630075007200720065006E006300650020007700690074006800200065007800630065007000740069006F006E0073000700330034002F0034003100340031000000000000000000");
pub const example_daily = hex("043004300A2000000000A0050000E010000000000000212000000A0000000000000002000000A0C1DC0C80D2DC0C00000000207EDC0C0016DD0C0630000009300000E0010000FE01000000000000000000000000");
pub const example_month_nth = hex("043004300C200300000060AE000003000000000000004100000003000000222000000A00000000000000020000006028C50C4028C70C02000000002EC50C4028C70C8028C30C6027D50C063000000930000048030000FC03000002004831C50CFC31C50CA82BC50C0000882BC70C3C2CC70C882BC70C10000D000C006E6577206C6F636174696F6E00000000040000000000000000000000040000000000000000000000882BC70C3C2CC70C882BC70C0C006E006500770020006C006F0063006100740069006F006E000000000000000000");
pub const example_yearly = hex("043004300D200200000040FA01000C0000000000000013000000232000000A000000000000000100000060CCE40C01000000A0D7E40CA0C1DC0CDF80E95A0630000009300000E0010000FE010000010080D9E40C9ED9E40C40CEE40C00000000000004000000000000000000000000000000");
pub const example_hebrew = hex("043004300D200200080080750A000C0000000000000003000000232000000A0000000000000001000000207EDC0C01000000207EDC0C6074C40CDF80E95A0630000009300000E0010000FE01000001000080DC0C1E80DC0C0080DC0C24023C000000010000000000000004000000000000000000000000000000");
/// [MS-OXOCAL] 4.1.5: Pacific time (UTC-8, daylight from the 2nd Sunday of March to the 1st Sunday of November).
pub const example_tz = hex("E001000000000000C4FFFFFF000000000B00000001000200000000000000000000000300000002000200000000000000");

const Ymd = struct { i64, u8, u8, u16 }; // date and start time (hhmm), local

fn expectOccurrences(p: Pattern, from: Ymd, to: Ymd, want: []const Ymd) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try expand(arena.allocator(), p, dayOf(from[0], from[1], from[2]), dayOf(to[0], to[1], to[2]));
    errdefer for (got) |o| {
        const c = civil(@divFloor(o.start, min_per_day));
        std.debug.print("  got {d}-{d}-{d} {d}\n", .{ c.y, c.m, c.d, @mod(o.start, min_per_day) });
    };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, o| {
        try testing.expectEqual(dayOf(w[0], w[1], w[2]) * min_per_day + @divFloor(w[3], 100) * 60 + @mod(w[3], 100), o.start);
    }
}

test "weekly: Monday, Thursday and Friday, 12 occurrences (4.1.1.1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_weekly);
    try testing.expectEqual(@as(u32, 0x32), p.specific);
    try expectOccurrences(p, .{ 2007, 1, 1, 0 }, .{ 2008, 1, 1, 0 }, &.{
        .{ 2007, 3, 26, 1000 }, .{ 2007, 3, 29, 1000 }, .{ 2007, 3, 30, 1000 }, .{ 2007, 4, 2, 1000 },
        .{ 2007, 4, 5, 1000 },  .{ 2007, 4, 6, 1000 },  .{ 2007, 4, 9, 1000 },  .{ 2007, 4, 12, 1000 },
        .{ 2007, 4, 13, 1000 }, .{ 2007, 4, 16, 1000 }, .{ 2007, 4, 19, 1000 }, .{ 2007, 4, 20, 1000 },
    });
    // the last one is the series' own EndDate
    try testing.expectEqual(dayOf(2007, 4, 20), @divFloor(@as(i64, p.end_date), min_per_day));
    // a range inside the series
    try expectOccurrences(p, .{ 2007, 4, 9, 0 }, .{ 2007, 4, 13, 0 }, &.{ .{ 2007, 4, 9, 1000 }, .{ 2007, 4, 12, 1000 } });
}

test "weekly with a moved instance and a new subject and location (4.1.1.2)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_weekly_exc);
    try testing.expectEqual(@as(usize, 1), p.exceptions.len);
    try testing.expectEqualStrings("Simple Recurrence with exceptions", p.exceptions[0].subject.?);
    try testing.expectEqualStrings("34/4141", p.exceptions[0].location.?);
    try expectOccurrences(p, .{ 2007, 4, 15, 0 }, .{ 2007, 4, 18, 0 }, &.{.{ 2007, 4, 16, 1100 }});
    const occ = try expand(arena.allocator(), p, dayOf(2007, 4, 16), dayOf(2007, 4, 17));
    try testing.expectEqual(@as(?usize, 0), occ[0].exception);
    try testing.expectEqual(occ[0].start + 30, occ[0].end);
}

test "every three days, two instances deleted (4.1.1.3)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_daily);
    try expectOccurrences(p, .{ 2011, 1, 1, 0 }, .{ 2012, 1, 1, 0 }, &.{
        .{ 2011, 4, 7, 800 },  .{ 2011, 4, 10, 800 }, .{ 2011, 4, 13, 800 }, .{ 2011, 4, 16, 800 },
        .{ 2011, 4, 25, 800 }, .{ 2011, 4, 28, 800 }, .{ 2011, 5, 1, 800 },  .{ 2011, 5, 4, 800 },
    });
}

test "third weekend day every 3 months, 10 occurrences, one moved, one relocated (4.1.1.4)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_month_nth);
    try testing.expectEqual(@as(u32, 0x41), p.specific);
    try testing.expectEqual(@as(u32, 3), p.nth);
    try expectOccurrences(p, .{ 2008, 1, 1, 0 }, .{ 2011, 1, 1, 0 }, &.{
        .{ 2008, 2, 9, 1400 }, .{ 2008, 5, 11, 1400 }, .{ 2008, 8, 9, 1400 }, .{ 2008, 11, 8, 1400 },
        .{ 2009, 2, 8, 1400 }, .{ 2009, 5, 9, 1400 },  .{ 2009, 8, 8, 1400 }, .{ 2009, 11, 8, 1400 },
        .{ 2010, 2, 13, 1400 }, .{ 2010, 5, 8, 1400 },
    });
    try testing.expectEqual(dayOf(2010, 5, 8), @divFloor(@as(i64, p.end_date), min_per_day));
    try testing.expectEqualStrings("new location", p.exceptions[1].location.?);
}

test "every April 19 without end, 2012 moved to April 21 (4.1.1.5)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_yearly);
    try testing.expect(p.endless());
    try expectOccurrences(p, .{ 2010, 1, 1, 0 }, .{ 2016, 1, 1, 0 }, &.{
        .{ 2011, 4, 19, 800 }, .{ 2012, 4, 21, 800 }, .{ 2013, 4, 19, 800 }, .{ 2014, 4, 19, 800 }, .{ 2015, 4, 19, 800 },
    });
    // far in the future, only what is asked for
    try expectOccurrences(p, .{ 2400, 1, 1, 0 }, .{ 2401, 1, 1, 0 }, &.{.{ 2400, 4, 19, 800 }});
}

test "Hebrew lunar calendar: parsed, not expanded (4.1.1.6)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parse(arena.allocator(), &example_hebrew);
    try testing.expectEqual(@as(u16, 8), p.calendar);
    try testing.expectError(error.Unsupported, expand(arena.allocator(), p, 0, dayOf(3000, 1, 1)));
}

test "damaged patterns are errors, never crashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var k: usize = 0;
    while (k < example_month_nth.len) : (k += 1) _ = parse(arena.allocator(), example_month_nth[0..k]) catch continue;
    var bad = example_weekly;
    bad[38] = 0xFF; // DeletedInstanceCount: far more than the blob holds
    try testing.expectError(error.Truncated, parse(arena.allocator(), &bad));
}

test "time zone: Pacific, daylight saving per date (4.1.5)" {
    const tz = TimeZone.parse(&example_tz).?;
    try testing.expectEqual(@as(i32, 480), tz.bias);
    // 2008-08-09 14:00 PDT = 21:00 UTC; 2008-11-08 14:00 PST = 22:00 UTC
    try testing.expectEqual(@as(i64, 1218315600), tz.toUnix(dayOf(2008, 8, 9) * min_per_day + 14 * 60));
    try testing.expectEqual(@as(i64, 1226181600), tz.toUnix(dayOf(2008, 11, 8) * min_per_day + 14 * 60));
    // transitions: 2nd Sunday of March 2007 (March 11), 1st Sunday of November 2008 (November 2)
    try testing.expect(!tz.isDaylight(dayOf(2007, 3, 11) * min_per_day + 60));
    try testing.expect(tz.isDaylight(dayOf(2007, 3, 11) * min_per_day + 180));
    try testing.expect(tz.isDaylight(dayOf(2008, 11, 2) * min_per_day + 60));
    try testing.expect(!tz.isDaylight(dayOf(2008, 11, 2) * min_per_day + 180));
}

test "patterns in words" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("every week on Monday, Thursday, Friday, 10:00-10:30, from 2007-03-26, 12 times", try describe(a, try parse(a, &example_weekly)));
    try testing.expectEqualStrings("every 3 days, 08:00-08:30, from 2011-04-07 until 2011-05-04; 2 deleted", try describe(a, try parse(a, &example_daily)));
    try testing.expectEqualStrings("every 3 months on the third weekend day, 14:00-17:00, from 2008-02-09, 10 times; 2 changed", try describe(a, try parse(a, &example_month_nth)));
    try testing.expectEqualStrings("every year on day 19 of April, 08:00-08:30, from 2011-04-19, no end; 1 changed", try describe(a, try parse(a, &example_yearly)));
}

test "calendar arithmetic" {
    try testing.expectEqual(@as(i64, 0), dayOf(1601, 1, 1));
    try testing.expectEqual(@as(u3, 1), weekday(0)); // a Monday
    try testing.expectEqual(@as(u3, 1), weekday(dayOf(2007, 3, 26)));
    const c = civil(dayOf(2024, 2, 29));
    try testing.expectEqual(Civil{ .y = 2024, .m = 2, .d = 29 }, c);
    try testing.expectEqual(days_1601_to_1970, dayOf(1970, 1, 1));
}
