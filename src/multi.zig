//! Several PST/OST files opened as one mailbox - typically a mailbox backup exported
//! as a set of PST parts.
//!
//! The folder trees of all parts are merged by folder path (case-insensitive): "Inbox" in part 1
//! and "Inbox" in part 2 become one folder listing the items of both. Every list entry names the
//! part file it came from, and items that occur in more than one part (same subject, sender and
//! times) are flagged as duplicates rather than hidden. Message ids encode the part and the
//! item's node index, so they are stable between runs. Each part stays a separate read-only PST.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");

const Member = struct { part: u16, nid: u32 };

const Folder = struct {
    name: []const u8,
    parent: u32,
    children: std.ArrayList(u32) = .empty,
    members: std.ArrayList(Member) = .empty,
    count: i64 = 0,
};

pub const Part = struct { path: []const u8, name: []const u8, file: *pst.Pst };

/// Message id layout: part (7 bits) | node index (25 bits); the NID type is always "normal
/// message" for items listed in contents tables. Anything else goes through a lookup table.
const part_bits = 7;
const index_bits = 32 - part_bits;
const max_parts = (1 << part_bits) - 1; // the top part value marks table-mapped ids

pub const Set = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    parts: []Part = &.{},
    folders: std.ArrayList(Folder) = .empty,
    /// ids that do not fit the packed layout
    extra: std.ArrayList(Member) = .empty,
    extra_ids: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// (part, folder) pairs already merged: a damaged part can list a folder under itself
    merged: std.AutoHashMapUnmanaged(u64, void) = .empty,

    /// Open every path as a PST/OST and merge their folder trees. Paths are sorted naturally
    /// (file.pst, file_1.pst, file_2.pst, ..., file_10.pst).
    pub fn open(gpa: Allocator, io: Io, paths_in: []const []const u8) !*Set {
        if (paths_in.len > max_parts) return error.TooManyParts;
        const self = try gpa.create(Set);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        const paths = try a.dupe([]const u8, paths_in);
        std.mem.sort([]const u8, paths, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return naturalLess(x, y);
            }
        }.lt);
        var parts: std.ArrayList(Part) = .empty;
        errdefer for (parts.items) |p| p.file.close();
        for (paths) |p| {
            const f = try pst.Pst.open(gpa, io, p);
            try parts.append(a, .{ .path = try a.dupe(u8, p), .name = try a.dupe(u8, std.fs.path.basename(p)), .file = f });
        }
        self.parts = parts.items;

        try self.folders.append(a, .{ .name = try std.fmt.allocPrint(a, "{d} files", .{self.parts.len}), .parent = 0 });
        // The user's folders hang below a different container in each file type ("Top of Outlook
        // data file" in a PST, "Root - Mailbox/IPM_SUBTREE" in an OST). Anchor every part's user
        // folders (the IPM subtree named by the message store) on one merged "Mailbox" node, and
        // merge everything else (search roots, system folders) by path beside it.
        const mailbox: u32 = 1;
        try self.folders.append(a, .{ .name = "Mailbox (merged)", .parent = 0 });
        try self.folders.items[0].children.append(a, mailbox);
        var tmp = std.heap.ArenaAllocator.init(gpa);
        defer tmp.deinit();
        for (self.parts, 0..) |p, i| {
            const part: u16 = @intCast(i);
            try self.folders.items[0].members.append(a, .{ .part = part, .nid = pst.NID.root_folder });
            const ipm = pst.ipmSubtree(tmp.allocator(), p.file);
            if (ipm) |sub| {
                try self.folders.items[mailbox].members.append(a, .{ .part = part, .nid = sub });
                try self.merge(tmp.allocator(), part, p.file, sub, mailbox, 0, 0);
            }
            try self.merge(tmp.allocator(), part, p.file, pst.NID.root_folder, 0, ipm orelse 0, 0);
        }
        return self;
    }

    /// Merge the sub-folders of `pst_folder` (in part `part`) into merged folder `into`,
    /// leaving out folder `skip` (the IPM subtree, merged separately).
    fn merge(self: *Set, t: Allocator, part: u16, f: *pst.Pst, pst_folder: u32, into: u32, skip: u32, depth: u32) !void {
        if (depth > 64) return;
        const a = self.arena.allocator();
        const kids = pst.subFolders(t, f, pst_folder) catch return;
        for (kids) |k| {
            if (k == skip) continue;
            if ((try self.merged.getOrPut(a, (@as(u64, part) << 32) | k)).found_existing) continue;
            const info = pst.folderInfo(t, f, k) catch continue;
            var target: ?u32 = null;
            for (self.folders.items[into].children.items) |c| {
                if (std.ascii.eqlIgnoreCase(self.folders.items[c].name, info.name)) {
                    target = c;
                    break;
                }
            }
            const id = target orelse blk: {
                const nid: u32 = @intCast(self.folders.items.len);
                try self.folders.append(a, .{ .name = try a.dupe(u8, info.name), .parent = into });
                try self.folders.items[into].children.append(a, nid);
                break :blk nid;
            };
            try self.folders.items[id].members.append(a, .{ .part = part, .nid = k });
            self.folders.items[id].count += info.count;
            try self.merge(t, part, f, k, id, skip, depth + 1);
        }
    }

    pub fn close(self: *Set) void {
        for (self.parts) |p| p.file.close();
        self.extra_ids.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn rootFolder(_: *const Set) u32 {
        return 0;
    }

    pub fn describe(self: *const Set, buf: []u8) []const u8 {
        var ost: usize = 0;
        for (self.parts) |p| if (p.file.is_ost) {
            ost += 1;
        };
        return std.fmt.bufPrint(buf, "{d} {s} files merged into one mailbox, {d} MB", .{ self.parts.len, if (ost == 0) "PST" else if (ost == self.parts.len) "OST" else "PST/OST", self.totalSize() / (1024 * 1024) }) catch "";
    }

    pub fn totalSize(self: *const Set) u64 {
        var t: u64 = 0;
        for (self.parts) |p| t += p.file.file_size;
        return t;
    }

    pub fn issueCount(self: *const Set) usize {
        var n: usize = 0;
        for (self.parts) |p| n += p.file.issues.items.len;
        return n;
    }

    // ------------------------------------------------------------ ids

    pub fn packId(self: *Set, part: u16, nid: u32) u32 {
        const index = nid >> 5;
        if ((nid & 0x1F) == pst.NID_TYPE.normal_message and index < (1 << index_bits) and part < max_parts)
            return (@as(u32, part) << index_bits) | index;
        const key = (@as(u64, part) << 32) | nid;
        if (self.extra_ids.get(key)) |id| return id;
        const id: u32 = (@as(u32, max_parts) << index_bits) | @as(u32, @intCast(self.extra.items.len));
        self.extra.append(self.arena.allocator(), .{ .part = part, .nid = nid }) catch return id;
        self.extra_ids.put(self.gpa, key, id) catch {};
        return id;
    }

    fn unpackId(self: *const Set, id: u32) !Member {
        const part: u16 = @intCast(id >> index_bits);
        if (part == max_parts) {
            const i = id & ((1 << index_bits) - 1);
            if (i >= self.extra.items.len) return error.NotFound;
            return self.extra.items[i];
        }
        if (part >= self.parts.len) return error.NotFound;
        return .{ .part = part, .nid = ((id & ((1 << index_bits) - 1)) << 5) | pst.NID_TYPE.normal_message };
    }

    /// Which part file an id belongs to (for display).
    pub fn partOf(self: *const Set, id: u32) ?*const Part {
        const m = self.unpackId(id) catch return null;
        return &self.parts[m.part];
    }

    // ------------------------------------------------------------ store interface

    pub fn folderInfo(self: *Set, a: Allocator, id: u32) !pst.FolderInfo {
        _ = a;
        if (id >= self.folders.items.len) return error.NotFound;
        const f = self.folders.items[id];
        return .{ .nid = id, .name = f.name, .count = f.count, .unread = 0, .has_subfolders = f.children.items.len > 0, .container_class = "" };
    }

    pub fn subFolders(self: *Set, a: Allocator, id: u32) ![]u32 {
        if (id >= self.folders.items.len) return error.NotFound;
        return a.dupe(u32, self.folders.items[id].children.items);
    }

    /// Items of every part's copy of this folder; each names its part, cross-part duplicates are flagged.
    pub fn folderMessages(self: *Set, a: Allocator, id: u32) ![]pst.MessageSummary {
        if (id >= self.folders.items.len) return error.NotFound;
        var out: std.ArrayList(pst.MessageSummary) = .empty;
        var seen: std.StringHashMapUnmanaged(u16) = .empty; // duplicate key -> first part
        for (self.folders.items[id].members.items) |mb| {
            const part = self.parts[mb.part];
            const list = pst.folderMessages(a, part.file, mb.nid) catch |e| {
                if (self.folders.items[id].members.items.len == 1) return e;
                continue;
            };
            for (list) |s0| {
                var s = s0;
                s.nid = self.packId(mb.part, s0.nid);
                // same item = same subject, sender and times (sizes differ between PST and OST copies)
                const key = try std.fmt.allocPrint(a, "{s}\x00{s}\x00{?d}\x00{?d}", .{ s.subject, s.from, s.submit_time, s.delivery_time });
                const gop = try seen.getOrPut(a, key);
                var dup: ?[]const u8 = null;
                if (gop.found_existing) {
                    if (gop.value_ptr.* != mb.part) dup = self.parts[gop.value_ptr.*].name;
                } else gop.value_ptr.* = mb.part;
                s.note = if (dup) |d|
                    try std.fmt.allocPrint(a, "{s} - duplicate of an item in {s}{s}{s}", .{ part.name, d, if (s0.note.len > 0) "; " else "", s0.note })
                else if (s0.note.len > 0)
                    try std.fmt.allocPrint(a, "{s}; {s}", .{ part.name, s0.note })
                else
                    part.name;
                try out.append(a, s);
            }
        }
        return out.toOwnedSlice(a);
    }

    pub fn loadMessage(self: *Set, a: Allocator, id: u32) !pst.Message {
        const m = try self.unpackId(id);
        return pst.loadMessage(a, self.parts[m.part].file, m.nid);
    }

    pub fn loadMessageHeaders(self: *Set, a: Allocator, id: u32) !pst.Message {
        const m = try self.unpackId(id);
        return pst.loadMessageHeaders(a, self.parts[m.part].file, m.nid);
    }
};

/// "file_2.pst" < "file_10.pst": digit runs compare by value, the rest case-insensitively.
pub fn naturalLess(x: []const u8, y: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[j])) {
            const si = i;
            const sj = j;
            while (i < x.len and std.ascii.isDigit(x[i])) i += 1;
            while (j < y.len and std.ascii.isDigit(y[j])) j += 1;
            const a = std.mem.trimStart(u8, x[si..i], "0");
            const b = std.mem.trimStart(u8, y[sj..j], "0");
            if (a.len != b.len) return a.len < b.len;
            const o = std.mem.order(u8, a, b);
            if (o != .eq) return o == .lt;
            continue;
        }
        const cx = std.ascii.toLower(x[i]);
        const cy = std.ascii.toLower(y[j]);
        if (cx != cy) return cx < cy;
        i += 1;
        j += 1;
    }
    return x.len - i < y.len - j;
}

// ================================================================ tests

const testing = std.testing;

test "natural order of part files" {
    try testing.expect(naturalLess("export.pst", "export_1.pst"));
    try testing.expect(naturalLess("export_2.pst", "export_10.pst"));
    try testing.expect(!naturalLess("export_10.pst", "export_2.pst"));
    try testing.expect(naturalLess("Part 9 of 12.pst", "Part 10 of 12.pst"));
}
