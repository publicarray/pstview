//! PST named-property map (NID 0x61, [MS-PST] 2.4.7) and the item fields that use it.
//!
//! Properties 0x8000-0xFFFE are "named": their meaning is (property-set GUID, numeric dispid or
//! string name), and each PST assigns its own ids. Calendar, contact, task, note and journal
//! fields are almost all named properties, so this map is what makes those items readable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
pub const pst_mod = pst;

pub const Guid = [16]u8;

/// GUID in the binary (little-endian Data1..Data3) layout used inside PST/MSG files.
fn guid(comptime s: []const u8) Guid {
    @setEvalBranchQuota(10_000);
    var g: Guid = undefined;
    const d1 = std.fmt.parseInt(u32, s[0..8], 16) catch unreachable;
    const d2 = std.fmt.parseInt(u16, s[9..13], 16) catch unreachable;
    const d3 = std.fmt.parseInt(u16, s[14..18], 16) catch unreachable;
    std.mem.writeInt(u32, g[0..4], d1, .little);
    std.mem.writeInt(u16, g[4..6], d2, .little);
    std.mem.writeInt(u16, g[6..8], d3, .little);
    const rest = s[19..23] ++ s[24..36];
    for (0..8) |i| g[8 + i] = std.fmt.parseInt(u8, rest[i * 2 .. i * 2 + 2], 16) catch unreachable;
    return g;
}

pub const PS_MAPI = guid("00020328-0000-0000-C000-000000000046");
pub const PS_PUBLIC_STRINGS = guid("00020329-0000-0000-C000-000000000046");
pub const PS_INTERNET_HEADERS = guid("00020386-0000-0000-C000-000000000046");
pub const PSETID_Appointment = guid("00062002-0000-0000-C000-000000000046");
pub const PSETID_Task = guid("00062003-0000-0000-C000-000000000046");
pub const PSETID_Address = guid("00062004-0000-0000-C000-000000000046");
pub const PSETID_Common = guid("00062008-0000-0000-C000-000000000046");
pub const PSETID_Log = guid("0006200A-0000-0000-C000-000000000046");
pub const PSETID_Note = guid("0006200E-0000-0000-C000-000000000046");
pub const PSETID_Meeting = guid("6ED8DA90-450B-101B-98DA-00AA003F1305");

pub fn guidName(g: Guid) []const u8 {
    const names = [_]struct { Guid, []const u8 }{
        .{ PS_MAPI, "PS_MAPI" },                         .{ PS_PUBLIC_STRINGS, "PS_PUBLIC_STRINGS" },
        .{ PS_INTERNET_HEADERS, "PS_INTERNET_HEADERS" }, .{ PSETID_Appointment, "PSETID_Appointment" },
        .{ PSETID_Task, "PSETID_Task" },                 .{ PSETID_Address, "PSETID_Address" },
        .{ PSETID_Common, "PSETID_Common" },             .{ PSETID_Log, "PSETID_Log" },
        .{ PSETID_Note, "PSETID_Note" },                 .{ PSETID_Meeting, "PSETID_Meeting" },
    };
    for (names) |n| if (std.mem.eql(u8, &n[0], &g)) return n[1];
    return "";
}

pub const Named = struct {
    id: u16,
    guid: Guid,
    /// numeric dispid, or null for a string-named property
    dispid: ?u32,
    name: []const u8 = "",
};

pub const NameMap = struct {
    entries: []Named = &.{},

    /// Load the map of one PST (an empty map if the file has none).
    pub fn load(a: Allocator, f: *pst.Pst) NameMap {
        var n = f.node(pst.NID.name_to_id_map) catch return .{};
        const pc = pst.PropContext.load(a, &n) catch return .{};
        const guids = pc.bytes(0x0002) orelse &.{};
        const stream = pc.bytes(0x0003) orelse return .{};
        const strings = pc.bytes(0x0004) orelse &.{};
        var out: std.ArrayList(Named) = .empty;
        var i: usize = 0;
        while (i + 8 <= stream.len) : (i += 8) {
            const prop_or_off = pst.rd32(stream, i);
            const wguid = pst.rd16(stream, i + 4);
            const idx = pst.rd16(stream, i + 6);
            const is_string = (wguid & 1) != 0;
            const gi = wguid >> 1;
            const g: Guid = switch (gi) {
                1 => PS_MAPI,
                2 => PS_PUBLIC_STRINGS,
                else => blk: {
                    if (gi < 3) break :blk [_]u8{0} ** 16;
                    const o = (@as(usize, gi) - 3) * 16;
                    if (o + 16 > guids.len) break :blk [_]u8{0} ** 16;
                    break :blk guids[o..][0..16].*;
                },
            };
            var e: Named = .{ .id = @intCast(@min(0x8000 + @as(u32, idx), 0xFFFF)), .guid = g, .dispid = if (is_string) null else prop_or_off };
            if (is_string and prop_or_off + 4 <= strings.len) {
                const len = pst.rd32(strings, prop_or_off);
                const s = prop_or_off + 4;
                if (s + len <= strings.len) e.name = pst.utf16ToUtf8(a, strings[s .. s + len]) catch "";
            }
            out.append(a, e) catch break;
        }
        return .{ .entries = out.items };
    }

    pub fn find(self: NameMap, g: Guid, dispid: u32) ?u16 {
        for (self.entries) |e| if (e.dispid != null and e.dispid.? == dispid and std.mem.eql(u8, &e.guid, &g)) return e.id;
        return null;
    }

    pub fn findName(self: NameMap, g: Guid, name: []const u8) ?u16 {
        for (self.entries) |e| if (e.dispid == null and std.ascii.eqlIgnoreCase(e.name, name) and std.mem.eql(u8, &e.guid, &g)) return e.id;
        return null;
    }

    pub fn describe(self: NameMap, id: u16) ?Named {
        for (self.entries) |e| if (e.id == id) return e;
        return null;
    }
};

// ================================================================ tests

const testing = std.testing;

test "GUIDs use the binary (little-endian) layout" {
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0x20, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 }, &PSETID_Appointment);
    try testing.expectEqualStrings("PSETID_Task", guidName(PSETID_Task));
}

test "lookups by dispid and by name" {
    const map: NameMap = .{ .entries = @constCast(&[_]Named{
        .{ .id = 0x8004, .guid = PSETID_Appointment, .dispid = 0x820D },
        .{ .id = 0x80A0, .guid = PS_PUBLIC_STRINGS, .dispid = null, .name = "Keywords" },
    }) };
    try testing.expectEqual(@as(?u16, 0x8004), map.find(PSETID_Appointment, 0x820D));
    try testing.expectEqual(@as(?u16, null), map.find(PSETID_Task, 0x820D));
    try testing.expectEqual(@as(?u16, 0x80A0), map.findName(PS_PUBLIC_STRINGS, "keywords"));
}
