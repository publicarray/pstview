//! PST writer: a new Unicode PST ([MS-PST] wVer 23, 512-byte pages, no encryption) built from
//! any source pstview reads (PST, OST, MBOX, merged PST sets) - also how an OST or an MBOX is
//! converted to a PST.
//!
//! Layers, as in [MS-PST]:
//!   NDB  `Ndb`       blocks, data trees (XBLOCK / XXBLOCK), sub-node trees (SLBLOCK / SIBLOCK),
//!                    the node and block B-trees, allocation map pages and the header;
//!   LTP  `Heap`      heap-on-node, B-tree-on-heap, property contexts and table contexts;
//!   Messaging        message store, name-to-id map, folders with their tables, messages with
//!                    recipient and attachment tables, attachments, embedded messages.
//!
//! The file is written front to back in one pass: blocks are appended as they are made, and only
//! the B-tree entries (24-32 bytes per node / block) are kept in memory until the B-tree pages,
//! the map pages and the header are written at the end. Where [MS-PST] leaves a detail open,
//! Outlook's own files were the reference (the template table columns, the name-map hash).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
const namemap = @import("namemap.zig");
const mime = @import("mime.zig");

const PT = pst.PT;
const wr16 = struct {
    fn f(b: []u8, o: usize, v: u16) void {
        std.mem.writeInt(u16, b[o..][0..2], v, .little);
    }
}.f;
const wr32 = struct {
    fn f(b: []u8, o: usize, v: u32) void {
        std.mem.writeInt(u32, b[o..][0..4], v, .little);
    }
}.f;
const wr64 = struct {
    fn f(b: []u8, o: usize, v: u64) void {
        std.mem.writeInt(u64, b[o..][0..8], v, .little);
    }
}.f;

fn crc(data: []const u8) u32 {
    return pst.PstCrc.hash(data);
}

/// Block / page signature ([MS-PST] 5.5).
fn signature(ib: u64, bid: u64) u16 {
    const x = ib ^ bid;
    return @as(u16, @truncate(x >> 16)) ^ @as(u16, @truncate(x));
}

fn alignUp(v: u64, a: u64) u64 {
    return (v + a - 1) / a * a;
}

// ================================================================ NDB layer

const amap_first: u64 = 0x4400;
/// Bytes mapped by one AMap page (496 * 8 * 64).
const amap_span: u64 = 253952;
const block_max: usize = 8192;
const trailer_size: usize = 16;
/// Data bytes in a full block.
pub const block_data_max: usize = block_max - trailer_size;
/// BIDs in a full XBLOCK / XXBLOCK.
const xblock_max: usize = (block_max - trailer_size - 8) / 8;
/// SLENTRYs in a full SLBLOCK, SIENTRYs in a full SIBLOCK.
const slblock_max: usize = (block_max - trailer_size - 8) / 24;
const siblock_max: usize = (block_max - trailer_size - 8) / 16;

const ptype_bbt: u8 = 0x80;
const ptype_nbt: u8 = 0x81;
const ptype_fmap: u8 = 0x82;
const ptype_pmap: u8 = 0x83;
const ptype_amap: u8 = 0x84;
const ptype_fpmap: u8 = 0x85;

/// Bytes at the start of data section `k` taken by its map pages: the AMap, a PMap in every
/// eighth section, an FMap every 496 sections from the 128th, an FPMap (at +0x600) every 31744
/// sections from the 8192nd. [MS-PST] requires the FMap / FPMap pages but gives no offsets; these
/// are the ones Outlook uses (the initial FMap / FPMap in the header cover the sections before).
fn mapPagesEnd(k: u64) u64 {
    var r: u64 = 0x200;
    if (k % 8 == 0) r = 0x400;
    if (k >= 128 and (k - 128) % 496 == 0) r = 0x600;
    if (k >= 8192 and (k - 8192) % 31744 == 0) r = 0x800;
    return r;
}

fn hasFMap(k: u64) bool {
    return k >= 128 and (k - 128) % 496 == 0;
}

fn hasFPMap(k: u64) bool {
    return k >= 8192 and (k - 8192) % 31744 == 0;
}

const BbtEnt = struct { bid: u64, ib: u64, cb: u16 };
const NbtEnt = struct { nid: u32, data: u64, sub: u64, parent: u32 };
pub const SubEnt = struct { nid: u32, data: u64, sub: u64 };

pub const Ndb = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    /// Next free byte; allocations only move forward.
    cursor: u64,
    /// Data section the cursor is in, and its allocation bits (one per 64 bytes).
    sec: u64 = 0,
    bits: [496]u8 = @splat(0),
    /// Per finished section: free 64-byte slots and the longest free run (for the FMaps).
    sec_free: std.ArrayList(u16) = .empty,
    sec_run: std.ArrayList(u8) = .empty,
    bbt: std.ArrayList(BbtEnt) = .empty,
    nbt: std.ArrayList(NbtEnt) = .empty,
    /// bidIndex counters: blocks (bidNextB), pages (bidNextP).
    next_bid: u64 = 1,
    next_pbid: u64 = 1,
    /// Last nidIndex used per NID type (header rgnid).
    rgnid: [32]u32,
    buf: []u8,

    pub fn init(gpa: Allocator, io: Io, file: Io.File) !Ndb {
        var rg: [32]u32 = @splat(0x400);
        rg[0x03] = 0x4000; // search folders
        rg[0x04] = 0x10000; // messages
        rg[0x08] = 0x8000; // associated messages
        var n: Ndb = .{ .gpa = gpa, .io = io, .file = file, .cursor = 0, .rgnid = rg, .buf = try gpa.alloc(u8, block_max) };
        n.startSection(0);
        n.cursor = amap_first + mapPagesEnd(0);
        return n;
    }

    pub fn deinit(self: *Ndb) void {
        self.sec_free.deinit(self.gpa);
        self.sec_run.deinit(self.gpa);
        self.bbt.deinit(self.gpa);
        self.nbt.deinit(self.gpa);
        self.gpa.free(self.buf);
    }

    fn markBits(self: *Ndb, from: u64, len: u64) void {
        const start = amap_first + self.sec * amap_span;
        var s = (from - start) / 64;
        const e = (from - start + len) / 64;
        while (s < e) : (s += 1) self.bits[@intCast(s / 8)] |= @as(u8, 0x80) >> @intCast(s % 8);
    }

    fn startSection(self: *Ndb, k: u64) void {
        self.sec = k;
        self.bits = @splat(0);
        self.markBits(amap_first + k * amap_span, mapPagesEnd(k));
    }

    /// Write the AMap (and PMap) of the current section and remember its free space.
    fn finishSection(self: *Ndb) !void {
        var free: u16 = 0;
        var run: u32 = 0;
        var best: u32 = 0;
        for (0..496 * 8) |s| {
            if (self.bits[s / 8] & (@as(u8, 0x80) >> @intCast(s % 8)) == 0) {
                free += 1;
                run += 1;
                best = @max(best, run);
            } else run = 0;
        }
        try self.sec_free.append(self.gpa, free);
        try self.sec_run.append(self.gpa, @intCast(@min(best, 255)));
        const ib = amap_first + self.sec * amap_span;
        try self.writeMapPage(ib, ptype_amap, &self.bits);
        if (self.sec % 8 == 0) {
            const full: [496]u8 = @splat(0xFF); // [MS-PST]: the PMap is deprecated; 1 bits are ignored
            try self.writeMapPage(ib + 0x200, ptype_pmap, &full);
        }
    }

    fn writeMapPage(self: *Ndb, ib: u64, ptype: u8, data: *const [496]u8) !void {
        var p: [512]u8 = @splat(0);
        @memcpy(p[0..496], data);
        p[496] = ptype;
        p[497] = ptype;
        wr16(&p, 498, 0);
        wr32(&p, 500, crc(p[0..496]));
        wr64(&p, 504, ib); // map pages carry their own offset as BID
        try self.file.writePositionalAll(self.io, &p, ib);
    }

    /// `size` bytes (a multiple of 64, at most 8192) at an `alignment`-aligned offset.
    fn alloc(self: *Ndb, size: u64, alignment: u64) !u64 {
        var pos = alignUp(self.cursor, alignment);
        while (true) {
            const k = (pos - amap_first) / amap_span;
            if (k != self.sec) {
                try self.finishSection();
                self.startSection(k);
            }
            const start = amap_first + k * amap_span;
            if (pos < start + mapPagesEnd(k)) pos = alignUp(start + mapPagesEnd(k), alignment);
            if (pos + size > start + amap_span) {
                pos = start + amap_span;
                continue;
            }
            self.markBits(pos, size);
            self.cursor = pos + size;
            return pos;
        }
    }

    /// One block with its trailer (`min_size`: a larger allocation, unused so far).
    fn writeBlock(self: *Ndb, data: []const u8, internal: bool, min_size: usize) !u64 {
        std.debug.assert(data.len <= block_data_max);
        const bid = (self.next_bid << 2) | @as(u64, if (internal) 2 else 0);
        self.next_bid += 1;
        const total: usize = @max(@as(usize, @intCast(alignUp(data.len + trailer_size, 64))), min_size);
        const ib = try self.alloc(total, 64);
        const b = self.buf[0..total];
        @memset(b, 0);
        @memcpy(b[0..data.len], data);
        const t = total - trailer_size;
        wr16(b, t, @intCast(data.len));
        wr16(b, t + 2, signature(ib, bid));
        wr32(b, t + 4, crc(data));
        wr64(b, t + 8, bid);
        try self.file.writePositionalAll(self.io, b, ib);
        try self.bbt.append(self.gpa, .{ .bid = bid, .ib = ib, .cb = @intCast(data.len) });
        return bid;
    }

    /// XBLOCK (level 1) or XXBLOCK (level 2) over `bids`.
    fn writeXBlock(self: *Ndb, level: u8, total: u64, bids: []const u64) !u64 {
        if (total > std.math.maxInt(u32)) return error.TooLarge;
        var b: [block_data_max]u8 = undefined;
        b[0] = 0x01;
        b[1] = level;
        wr16(&b, 2, @intCast(bids.len));
        wr32(&b, 4, @intCast(total));
        for (bids, 0..) |id, i| wr64(&b, 8 + i * 8, id);
        return self.writeBlock(b[0 .. 8 + bids.len * 8], true, 0);
    }

    /// Data tree over pre-cut blocks (each at most 8176 bytes). Row matrices ask for every block
    /// but the last to be a full 8192-byte block, as [MS-PST] 2.3.4.4 requires.
    fn writeBlocks(self: *Ndb, blocks: []const []const u8, full_blocks: bool) !u64 {
        if (blocks.len == 0) return 0;
        if (blocks.len == 1) return self.writeBlock(blocks[0], false, 0);
        var leaves: std.ArrayList(u64) = .empty;
        defer leaves.deinit(self.gpa);
        var sizes: std.ArrayList(u64) = .empty;
        defer sizes.deinit(self.gpa);
        var full: [block_data_max]u8 = undefined;
        for (blocks, 0..) |blk, i| {
            // whole rows, then dead space up to a full block ([MS-PST] 2.3.4.4: readers skip it)
            var d = blk;
            if (full_blocks and i + 1 < blocks.len) {
                @memset(&full, 0);
                @memcpy(full[0..blk.len], blk);
                d = &full;
            }
            try leaves.append(self.gpa, try self.writeBlock(d, false, 0));
            try sizes.append(self.gpa, d.len);
        }
        return self.treeOver(leaves.items, sizes.items);
    }

    fn treeOver(self: *Ndb, leaves: []const u64, sizes: []const u64) !u64 {
        var total: u64 = 0;
        for (sizes) |s| total += s;
        if (leaves.len <= xblock_max) return self.writeXBlock(1, total, leaves);
        if (leaves.len > xblock_max * xblock_max) return error.TooLarge;
        var xs: std.ArrayList(u64) = .empty;
        defer xs.deinit(self.gpa);
        var i: usize = 0;
        while (i < leaves.len) : (i += xblock_max) {
            const e = @min(leaves.len, i + xblock_max);
            var t: u64 = 0;
            for (sizes[i..e]) |s| t += s;
            try xs.append(self.gpa, try self.writeXBlock(1, t, leaves[i..e]));
        }
        return self.writeXBlock(2, total, xs.items);
    }

    /// A stream of any length as a data tree; 0 for no data.
    pub fn writeData(self: *Ndb, data: []const u8) !u64 {
        if (data.len == 0) return self.writeBlock(data, false, 0);
        if (data.len <= block_data_max) return self.writeBlock(data, false, 0);
        var leaves: std.ArrayList(u64) = .empty;
        defer leaves.deinit(self.gpa);
        var sizes: std.ArrayList(u64) = .empty;
        defer sizes.deinit(self.gpa);
        var o: usize = 0;
        while (o < data.len) : (o += block_data_max) {
            const e = @min(data.len, o + block_data_max);
            try leaves.append(self.gpa, try self.writeBlock(data[o..e], false, 0));
            try sizes.append(self.gpa, e - o);
        }
        return self.treeOver(leaves.items, sizes.items);
    }

    /// Sub-node B-tree over `ents` (sorted here); 0 for none.
    pub fn writeSubnodes(self: *Ndb, ents: []SubEnt) !u64 {
        if (ents.len == 0) return 0;
        std.mem.sort(SubEnt, ents, {}, struct {
            fn lt(_: void, x: SubEnt, y: SubEnt) bool {
                return x.nid < y.nid;
            }
        }.lt);
        var b: [block_data_max]u8 = undefined;
        if (ents.len <= slblock_max) return self.slBlock(&b, ents);
        if (ents.len > slblock_max * siblock_max) return error.TooLarge;
        var firsts: std.ArrayList(SubEnt) = .empty;
        defer firsts.deinit(self.gpa);
        var i: usize = 0;
        while (i < ents.len) : (i += slblock_max) {
            const e = @min(ents.len, i + slblock_max);
            try firsts.append(self.gpa, .{ .nid = ents[i].nid, .data = try self.slBlock(&b, ents[i..e]), .sub = 0 });
        }
        b[0] = 0x02;
        b[1] = 0x01;
        wr16(&b, 2, @intCast(firsts.items.len));
        wr32(&b, 4, 0);
        for (firsts.items, 0..) |f, j| {
            wr64(&b, 8 + j * 16, f.nid);
            wr64(&b, 16 + j * 16, f.data);
        }
        return self.writeBlock(b[0 .. 8 + firsts.items.len * 16], true, 0);
    }

    fn slBlock(self: *Ndb, b: *[block_data_max]u8, ents: []const SubEnt) !u64 {
        b[0] = 0x02;
        b[1] = 0x00;
        wr16(b, 2, @intCast(ents.len));
        wr32(b, 4, 0);
        for (ents, 0..) |e, j| {
            wr64(b, 8 + j * 24, e.nid);
            wr64(b, 16 + j * 24, e.data);
            wr64(b, 24 + j * 24, e.sub);
        }
        return self.writeBlock(b[0 .. 8 + ents.len * 24], true, 0);
    }

    /// The next NID of `nid_type`.
    pub fn newNid(self: *Ndb, nid_type: u5) u32 {
        self.rgnid[nid_type] += 1;
        return (self.rgnid[nid_type] << 5) | nid_type;
    }

    /// Record a fixed NID so that the header's counters stay above it.
    fn noteNid(self: *Ndb, nid: u32) void {
        const t = nid & 0x1F;
        self.rgnid[t] = @max(self.rgnid[t], nid >> 5);
    }

    pub fn addNode(self: *Ndb, nid: u32, data: u64, sub: u64, parent: u32) !void {
        self.noteNid(nid);
        try self.nbt.append(self.gpa, .{ .nid = nid, .data = data, .sub = sub, .parent = parent });
    }

    const Ref = struct { key: u64, bid: u64, ib: u64 };

    fn writePage(self: *Ndb, page: *[512]u8, ptype: u8) !Ref {
        const ib = try self.alloc(512, 512);
        const bid = self.next_pbid;
        self.next_pbid += 1;
        page[496] = ptype;
        page[497] = ptype;
        wr16(page, 498, signature(ib, bid));
        wr32(page, 500, crc(page[0..496]));
        wr64(page, 504, bid);
        try self.file.writePositionalAll(self.io, page, ib);
        return .{ .key = 0, .bid = bid, .ib = ib };
    }

    /// B-tree pages bottom-up over sorted leaf entries of `cb` bytes each; returns the root.
    fn writeBtree(self: *Ndb, ptype: u8, cb: usize, entries: []const u8, keys: []const u64) !Ref {
        var level: std.ArrayList(Ref) = .empty;
        defer level.deinit(self.gpa);
        const per = 488 / cb;
        const n = keys.len;
        var i: usize = 0;
        while (i < n or (n == 0 and i == 0)) : (i += per) {
            const e = @min(n, i + per);
            var page: [512]u8 = @splat(0);
            @memcpy(page[0 .. (e - i) * cb], entries[i * cb .. e * cb]);
            page[488] = @intCast(e - i);
            page[489] = @intCast(per);
            page[490] = @intCast(cb);
            page[491] = 0;
            var r = try self.writePage(&page, ptype);
            r.key = if (e > i) keys[i] else 0;
            try level.append(self.gpa, r);
            if (n == 0) break;
        }
        var depth: u8 = 1;
        while (level.items.len > 1) : (depth += 1) {
            var next: std.ArrayList(Ref) = .empty;
            const per_i = 488 / 24;
            var j: usize = 0;
            while (j < level.items.len) : (j += per_i) {
                const e = @min(level.items.len, j + per_i);
                var page: [512]u8 = @splat(0);
                for (level.items[j..e], 0..) |r, x| {
                    wr64(&page, x * 24, r.key);
                    wr64(&page, x * 24 + 8, r.bid);
                    wr64(&page, x * 24 + 16, r.ib);
                }
                page[488] = @intCast(e - j);
                page[489] = @intCast(per_i);
                page[490] = 24;
                page[491] = depth;
                var r = try self.writePage(&page, ptype);
                r.key = level.items[j].key;
                try next.append(self.gpa, r);
            }
            level.deinit(self.gpa);
            level = next;
        }
        return level.items[0];
    }

    /// Write the B-trees, the map pages and the header. The file is complete afterwards.
    pub fn finish(self: *Ndb) !u64 {
        // block B-tree (BIDs were handed out in increasing order)
        const bbt_bytes = try self.gpa.alloc(u8, self.bbt.items.len * 24);
        defer self.gpa.free(bbt_bytes);
        const bbt_keys = try self.gpa.alloc(u64, self.bbt.items.len);
        defer self.gpa.free(bbt_keys);
        for (self.bbt.items, 0..) |e, i| {
            wr64(bbt_bytes, i * 24, e.bid);
            wr64(bbt_bytes, i * 24 + 8, e.ib);
            wr16(bbt_bytes, i * 24 + 16, e.cb);
            wr16(bbt_bytes, i * 24 + 18, 2); // referenced by the BBT and by one node / block
            wr32(bbt_bytes, i * 24 + 20, 0);
            bbt_keys[i] = e.bid;
        }
        const bbt_root = try self.writeBtree(ptype_bbt, 24, bbt_bytes, bbt_keys);

        // node B-tree
        std.mem.sort(NbtEnt, self.nbt.items, {}, struct {
            fn lt(_: void, x: NbtEnt, y: NbtEnt) bool {
                return x.nid < y.nid;
            }
        }.lt);
        const nbt_bytes = try self.gpa.alloc(u8, self.nbt.items.len * 32);
        defer self.gpa.free(nbt_bytes);
        const nbt_keys = try self.gpa.alloc(u64, self.nbt.items.len);
        defer self.gpa.free(nbt_keys);
        for (self.nbt.items, 0..) |e, i| {
            if (i > 0 and self.nbt.items[i - 1].nid == e.nid) return error.DuplicateNode;
            wr64(nbt_bytes, i * 32, e.nid);
            wr64(nbt_bytes, i * 32 + 8, e.data);
            wr64(nbt_bytes, i * 32 + 16, e.sub);
            wr32(nbt_bytes, i * 32 + 24, e.parent);
            wr32(nbt_bytes, i * 32 + 28, 0);
            nbt_keys[i] = e.nid;
        }
        const nbt_root = try self.writeBtree(ptype_nbt, 32, nbt_bytes, nbt_keys);

        // the last section, then the FMaps / FPMaps that cover all sections
        try self.finishSection();
        const sections = self.sec + 1;
        const eof = amap_first + sections * amap_span;
        var k: u64 = 128;
        while (k < sections) : (k += 496) {
            var m: [496]u8 = @splat(0);
            for (0..496) |x| {
                if (k + x < sections) m[x] = self.sec_run.items[@intCast(k + x)];
            }
            try self.writeMapPage(amap_first + k * amap_span + 0x400, ptype_fmap, &m);
        }
        k = 8192;
        while (k < sections) : (k += 31744) {
            const m: [496]u8 = @splat(0xFF);
            try self.writeMapPage(amap_first + k * amap_span + 0x600, ptype_fpmap, &m);
        }
        var amap_free: u64 = 0;
        for (self.sec_free.items) |f| amap_free += @as(u64, f) * 64;
        try self.file.setLength(self.io, eof);

        // header
        var h: [564]u8 = @splat(0);
        @memcpy(h[0..4], "!BDN");
        @memcpy(h[8..10], "SM");
        wr16(&h, 10, 23); // wVer: Unicode
        wr16(&h, 12, 19); // wVerClient
        h[14] = 1;
        h[15] = 1;
        wr64(&h, 32, self.next_pbid); // bidNextP
        wr32(&h, 40, 1); // dwUnique
        for (self.rgnid, 0..) |v, i| wr32(&h, 44 + i * 4, v + 1);
        // ROOT
        wr64(&h, 184, eof);
        wr64(&h, 192, amap_first + (sections - 1) * amap_span);
        wr64(&h, 200, amap_free);
        wr64(&h, 208, 0);
        wr64(&h, 216, nbt_root.bid);
        wr64(&h, 224, nbt_root.ib);
        wr64(&h, 232, bbt_root.bid);
        wr64(&h, 240, bbt_root.ib);
        h[248] = 0x02; // VALID_AMAP2
        @memset(h[256..384], 0xFF); // rgbFM
        @memset(h[384..512], 0xFF); // rgbFP
        h[512] = 0x80;
        h[513] = 0x00; // NDB_CRYPT_NONE
        wr64(&h, 516, self.next_bid << 2); // bidNextB
        wr32(&h, 4, crc(h[8 .. 8 + 471]));
        wr32(&h, 524, crc(h[8 .. 8 + 516]));
        try self.file.writePositionalAll(self.io, &h, 0);
        return eof;
    }
};

// ================================================================ LTP layer: heap-on-node

/// A heap being built in memory; `blocks` turns it into data blocks.
pub const Heap = struct {
    a: Allocator,
    client_sig: u8,
    user_root: u32 = 0,
    blocks: std.ArrayList(Blk) = .empty,

    const Blk = struct { data: std.ArrayList(u8) = .empty, offs: std.ArrayList(u16) = .empty };
    pub const item_max: usize = 3580;

    pub fn init(a: Allocator, client_sig: u8) Heap {
        return .{ .a = a, .client_sig = client_sig };
    }

    fn headerSize(i: usize) usize {
        if (i == 0) return 12;
        if (i >= 8 and (i - 8) % 128 == 0) return 66;
        return 2;
    }

    fn newBlock(self: *Heap) !*Blk {
        const i = self.blocks.items.len;
        if (i >= 0xFFFF) return error.TooLarge;
        try self.blocks.append(self.a, .{});
        const b = &self.blocks.items[i];
        try b.data.appendNTimes(self.a, 0, headerSize(i));
        return b;
    }

    /// Store `bytes` (at most 3580) and return its HID.
    pub fn alloc(self: *Heap, bytes: []const u8) !u32 {
        std.debug.assert(bytes.len <= item_max);
        var b = if (self.blocks.items.len == 0) try self.newBlock() else &self.blocks.items[self.blocks.items.len - 1];
        // room for the item, the 2-byte alignment of the page map and the page map itself
        const map_after = 4 + 2 * (b.offs.items.len + 2);
        if (b.offs.items.len >= 2047 or b.data.items.len + bytes.len + 1 + map_after > block_data_max) b = try self.newBlock();
        try b.offs.append(self.a, @intCast(b.data.items.len));
        try b.data.appendSlice(self.a, bytes);
        const bi: u32 = @intCast(self.blocks.items.len - 1);
        return (bi << 16) | (@as(u32, @intCast(b.offs.items.len)) << 5);
    }

    fn fillLevel(free: usize) u4 {
        const steps = [_]usize{ 3584, 2560, 2048, 1792, 1536, 1280, 1024, 768, 512, 256, 128, 64, 32, 16, 8 };
        for (steps, 0..) |s, i| if (free >= s) return @intCast(i);
        return 0xF;
    }

    /// The finished blocks: headers, items and page maps.
    pub fn finish(self: *Heap) ![][]u8 {
        if (self.blocks.items.len == 0) _ = try self.newBlock();
        const out = try self.a.alloc([]u8, self.blocks.items.len);
        var levels = try self.a.alloc(u4, self.blocks.items.len);
        for (self.blocks.items, 0..) |*b, i| {
            const end: u16 = @intCast(b.data.items.len);
            if (b.data.items.len % 2 == 1) try b.data.append(self.a, 0);
            const hnpm: u16 = @intCast(b.data.items.len);
            var m: [4]u8 = undefined;
            wr16(&m, 0, @intCast(b.offs.items.len));
            wr16(&m, 2, 0);
            try b.data.appendSlice(self.a, &m);
            for (b.offs.items) |o| {
                var w: [2]u8 = undefined;
                wr16(&w, 0, o);
                try b.data.appendSlice(self.a, &w);
            }
            var w: [2]u8 = undefined;
            wr16(&w, 0, end);
            try b.data.appendSlice(self.a, &w);
            wr16(b.data.items, 0, hnpm);
            levels[i] = fillLevel(block_data_max - b.data.items.len);
            out[i] = b.data.items;
        }
        for (out, 0..) |d, i| {
            if (i == 0) {
                d[2] = 0xEC;
                d[3] = self.client_sig;
                wr32(d, 4, self.user_root);
                var fl: u32 = 0;
                for (0..@min(8, out.len)) |j| fl |= @as(u32, levels[j]) << @intCast(j * 4);
                wr32(d, 8, fl);
            } else if (headerSize(i) == 66) {
                @memset(d[2..66], 0);
                for (0..128) |j| {
                    if (i + j >= out.len) break;
                    d[2 + j / 2] |= @as(u8, levels[i + j]) << @intCast((j % 2) * 4);
                }
            }
        }
        return out;
    }
};

/// B-tree-on-heap over sorted records of `cb_key + cb_ent` bytes; returns the BTHHEADER's HID.
fn buildBth(heap: *Heap, cb_key: u8, cb_ent: u8, records: []const u8) !u32 {
    const rec = @as(usize, cb_key) + cb_ent;
    var hdr: [8]u8 = .{ 0xB5, cb_key, cb_ent, 0, 0, 0, 0, 0 };
    if (records.len == 0) return heap.alloc(&hdr);
    const a = heap.a;
    var level: std.ArrayList(struct { key: []const u8, hid: u32 }) = .empty;
    const per = Heap.item_max / rec;
    var i: usize = 0;
    while (i < records.len) : (i += per * rec) {
        const e = @min(records.len, i + per * rec);
        try level.append(a, .{ .key = records[i .. i + cb_key], .hid = try heap.alloc(records[i..e]) });
    }
    var levels: u8 = 0;
    while (level.items.len > 1) {
        levels += 1;
        const irec = @as(usize, cb_key) + 4;
        const iper = Heap.item_max / irec;
        var next: @TypeOf(level) = .empty;
        var j: usize = 0;
        while (j < level.items.len) : (j += iper) {
            const e = @min(level.items.len, j + iper);
            var buf: std.ArrayList(u8) = .empty;
            for (level.items[j..e]) |x| {
                try buf.appendSlice(a, x.key);
                var w: [4]u8 = undefined;
                wr32(&w, 0, x.hid);
                try buf.appendSlice(a, &w);
            }
            try next.append(a, .{ .key = level.items[j].key, .hid = try heap.alloc(buf.items) });
        }
        level = next;
    }
    hdr[3] = levels;
    wr32(&hdr, 4, level.items[0].hid);
    return heap.alloc(&hdr);
}

// ================================================================ LTP layer: property and table contexts

pub const Prop = struct { id: u16, ptype: u16, data: []const u8 };

fn isVariable(ptype: u16) bool {
    return pst.fixedSize(ptype) == null;
}

/// Where values too large for a heap go: data trees registered as sub-nodes of the node.
pub const Subs = struct {
    a: Allocator,
    list: std.ArrayList(SubEnt) = .empty,
    next: u32 = 0,

    /// A sub-node holding `data`; returns its NID (NID_TYPE_LTP).
    fn blob(self: *Subs, ndb: *Ndb, data: []const u8) !u32 {
        self.next += 1;
        const nid = (self.next << 5) | 0x1F;
        try self.list.append(self.a, .{ .nid = nid, .data = try ndb.writeData(data), .sub = 0 });
        return nid;
    }
};

/// The HNID / inline value of one variable-size or large value.
fn storeValue(heap: *Heap, ndb: *Ndb, subs: *Subs, data: []const u8) !u32 {
    if (data.len == 0) return 0; // an empty value has no heap item (as in Outlook's files)
    if (data.len <= Heap.item_max) return heap.alloc(data);
    return subs.blob(ndb, data);
}

/// Property context over `props` (sorted by id, unique); returns the BID of its data.
pub fn writePc(a: Allocator, ndb: *Ndb, subs: *Subs, props: []const Prop) !u64 {
    var heap = Heap.init(a, 0xBC);
    var recs: std.ArrayList(u8) = .empty;
    for (props) |p| {
        var r: [8]u8 = @splat(0);
        wr16(&r, 0, p.id);
        wr16(&r, 2, p.ptype);
        if (pst.fixedSize(p.ptype)) |sz| {
            if (sz <= 4) {
                @memcpy(r[4..][0..@min(sz, p.data.len)], p.data[0..@min(sz, p.data.len)]);
            } else {
                var v: [8]u8 = @splat(0);
                @memcpy(v[0..@min(8, p.data.len)], p.data[0..@min(8, p.data.len)]);
                wr32(&r, 4, try heap.alloc(&v));
            }
        } else wr32(&r, 4, try storeValue(&heap, ndb, subs, p.data));
        try recs.appendSlice(a, &r);
    }
    heap.user_root = try buildBth(&heap, 2, 6, recs.items);
    return ndb.writeBlocks(try heap.finish(), false);
}

pub const Column = struct { tag: u32, ib: u16 = 0, cb: u8 = 0, ibit: u8 = 0 };

/// Column layout of a table: the row id and row version first ([MS-PST] 2.3.4.4.1), then 8- and
/// 4-byte cells, 2-byte cells, 1-byte cells, then the cell existence bitmap.
pub fn layout(a: Allocator, tags_in: []const u32) !struct { cols: []Column, rgib: [4]u16 } {
    var tags: std.ArrayList(u32) = .empty;
    try tags.appendSlice(a, &.{ 0x67F20003, 0x67F30003 });
    for (tags_in) |t| {
        if (t == 0x67F20003 or t == 0x67F30003) continue;
        if (std.mem.indexOfScalar(u32, tags.items, t) == null) try tags.append(a, t);
    }
    std.mem.sort(u32, tags.items[2..], {}, std.sort.asc(u32));
    const cols = try a.alloc(Column, tags.items.len);
    const width = struct {
        fn f(t: u32) u8 {
            const pt: u16 = @truncate(t);
            if (pt & PT.mv_flag != 0) return 4;
            return switch (pt) {
                PT.int64, PT.systime, PT.float64, PT.currency, PT.apptime => 8,
                PT.int16 => 2,
                PT.boolean => 1,
                else => 4, // 4-byte values and HNIDs
            };
        }
    }.f;
    for (tags.items, 0..) |t, i| cols[i] = .{ .tag = t, .cb = width(t) };
    // row id at 0, row version at 4, then 8-byte, 4-byte, 2-byte and 1-byte cells
    cols[0].ib = 0;
    cols[1].ib = 4;
    var off: u16 = 8;
    var rgib: [4]u16 = undefined;
    for ([_]u8{ 8, 4, 2, 1 }, 0..) |w, gi| {
        for (cols[2..]) |*c| if (c.cb == w) {
            c.ib = off;
            off += w;
        };
        if (gi >= 1) rgib[gi - 1] = off;
    }
    for (cols, 0..) |*c, i| c.ibit = @intCast(i);
    rgib[3] = off + @as(u16, @intCast((cols.len + 7) / 8));
    // TCINFO lists the columns sorted by tag
    std.mem.sort(Column, cols, {}, struct {
        fn lt(_: void, x: Column, y: Column) bool {
            return x.tag < y.tag;
        }
    }.lt);
    return .{ .cols = cols, .rgib = rgib };
}

pub const Row = struct { id: u32, props: []const Prop };

/// Table context with columns `tags` (plus the row id / version) and `rows`; returns the BIDs
/// of its data and sub-nodes.
pub fn writeTc(a: Allocator, ndb: *Ndb, tags: []const u32, rows: []const Row) !struct { data: u64, sub: u64 } {
    const lay = try layout(a, tags);
    const row_size: usize = lay.rgib[3];
    var heap = Heap.init(a, 0x7C);
    var subs: Subs = .{ .a = a };
    const matrix = try a.alloc(u8, rows.len * row_size);
    @memset(matrix, 0);
    var index: std.ArrayList(u8) = .empty;
    const IdIx = struct { id: u32, ix: u32 };
    const ids = try a.alloc(IdIx, rows.len);
    for (rows, 0..) |row, ri| {
        const r = matrix[ri * row_size ..][0..row_size];
        const ceb = r[lay.rgib[2]..];
        for (lay.cols) |c| {
            const id: u16 = @truncate(c.tag >> 16);
            const pt: u16 = @truncate(c.tag);
            var data: []const u8 = undefined;
            var tmp: [4]u8 = undefined;
            if (c.tag == 0x67F20003) {
                wr32(&tmp, 0, row.id);
                data = &tmp;
            } else if (c.tag == 0x67F30003) {
                wr32(&tmp, 0, 1);
                data = &tmp;
            } else {
                const p = findProp(row.props, id, pt) orelse continue;
                data = p.data;
            }
            const cell = r[c.ib..][0..c.cb];
            const variable = (pt & PT.mv_flag) != 0 or isVariable(pt);
            if (variable) {
                wr32(cell, 0, try storeValue(&heap, ndb, &subs, data));
            } else @memcpy(cell[0..@min(c.cb, data.len)], data[0..@min(c.cb, data.len)]);
            ceb[c.ibit / 8] |= @as(u8, 0x80) >> @intCast(c.ibit % 8);
        }
        ids[ri] = .{ .id = row.id, .ix = @intCast(ri) };
    }
    std.mem.sort(IdIx, ids, {}, struct {
        fn lt(_: void, x: IdIx, y: IdIx) bool {
            return x.id < y.id;
        }
    }.lt);
    for (ids) |x| {
        var rec: [8]u8 = undefined;
        wr32(&rec, 0, x.id);
        wr32(&rec, 4, x.ix);
        try index.appendSlice(a, &rec);
    }
    const hid_index = try buildBth(&heap, 4, 4, index.items);
    // the row matrix: whole rows per block, in a sub-node
    var hnid_rows: u32 = 0;
    if (rows.len > 0) {
        const per = block_data_max / row_size;
        var blocks: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (i < rows.len) : (i += per) {
            const e = @min(rows.len, i + per);
            try blocks.append(a, matrix[i * row_size .. e * row_size]);
        }
        subs.next += 1;
        hnid_rows = (subs.next << 5) | 0x1F;
        try subs.list.append(a, .{ .nid = hnid_rows, .data = try ndb.writeBlocks(blocks.items, true), .sub = 0 });
    }
    var info: std.ArrayList(u8) = .empty;
    var head: [22]u8 = @splat(0);
    head[0] = 0x7C;
    head[1] = @intCast(lay.cols.len);
    for (lay.rgib, 0..) |v, i| wr16(&head, 2 + i * 2, v);
    wr32(&head, 10, hid_index);
    wr32(&head, 14, hnid_rows);
    try info.appendSlice(a, &head);
    for (lay.cols) |c| {
        var d: [8]u8 = undefined;
        wr32(&d, 0, c.tag);
        wr16(&d, 4, c.ib);
        d[6] = c.cb;
        d[7] = c.ibit;
        try info.appendSlice(a, &d);
    }
    heap.user_root = try heap.alloc(info.items);
    const data = try ndb.writeBlocks(try heap.finish(), false);
    return .{ .data = data, .sub = try ndb.writeSubnodes(subs.list.items) };
}

fn findProp(props: []const Prop, id: u16, ptype: u16) ?Prop {
    for (props) |p| if (p.id == id and p.ptype == ptype) return p;
    return null;
}

// ================================================================ messaging layer

/// Template table columns. [MS-PST] 2.4.4.4.1 ff. lists the required ones; these are the sets in
/// Outlook's own PST files (which differ in places, e.g. PidTagReplItemid is binary there).
const tpl_hierarchy = [_]u32{ 0x0E300102, 0x0E330014, 0x0E340102, 0x0E380003, 0x3001001F, 0x36020003, 0x36030003, 0x360A000B, 0x3613001F, 0x66350003, 0x66360003, 0x67F20003, 0x67F30003 };
const tpl_contents = [_]u32{ 0x00170003, 0x001A001F, 0x00360003, 0x0037001F, 0x00390040, 0x0042001F, 0x0057000B, 0x0058000B, 0x0070001F, 0x00710102, 0x0E03001F, 0x0E04001F, 0x0E060040, 0x0E070003, 0x0E080003, 0x0E170003, 0x0E300102, 0x0E330014, 0x0E340102, 0x0E380003, 0x0E3C0102, 0x0E3D0102, 0x10970003, 0x30080040, 0x30130102, 0x65C60003, 0x67F20003, 0x67F30003 };
const tpl_assoc = [_]u32{ 0x001A001F, 0x0E070003, 0x0E170003, 0x3001001F, 0x67F20003, 0x67F30003, 0x6800001F, 0x6803000B, 0x68051003, 0x682F001F, 0x70030003, 0x70040102, 0x70050102, 0x7006001F, 0x70070003 };
const tpl_search = [_]u32{ 0x00170003, 0x001A001F, 0x00360003, 0x0037001F, 0x0042001F, 0x0057000B, 0x0058000B, 0x0E03001F, 0x0E04001F, 0x0E05001F, 0x0E060040, 0x0E070003, 0x0E080003, 0x0E170003, 0x0E2A000B, 0x30080040, 0x67F10003, 0x67F20003, 0x67F30003 };
const tpl_attachment = [_]u32{ 0x0E200003, 0x3704001F, 0x37050003, 0x370B0003, 0x67F20003, 0x67F30003 };
const tpl_recipient = [_]u32{ 0x0C150003, 0x0E0F000B, 0x0FF90102, 0x0FFE0003, 0x0FFF0102, 0x3001001F, 0x3002001F, 0x3003001F, 0x300B0102, 0x39000003, 0x39FF001F, 0x3A40000B, 0x67F20003, 0x67F30003 };

const nid_root: u32 = 0x122;
const nid_ipm: u32 = 0x8022;
const nid_search_root: u32 = 0x8042;
const nid_deleted: u32 = 0x8062;
const nid_spam: u32 = 0x2223;

fn tableNid(folder: u32, t: u32) u32 {
    return (folder & ~@as(u32, 0x1F)) | t;
}

/// The new file's name-to-id map ([MS-PST] 2.4.7): named properties of all sources get ids here.
pub const NameMapOut = struct {
    a: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    index: std.StringHashMapUnmanaged(u16) = .empty,

    const Entry = struct { guid: [16]u8, dispid: ?u32, name: []const u8 };
    const ps_mapi = namemap.PS_MAPI;
    const ps_public = namemap.PS_PUBLIC_STRINGS;

    /// The id for a (GUID, dispid) or (GUID, name) pair, added when new; null when the map is full.
    pub fn id(self: *NameMapOut, guid: [16]u8, dispid: ?u32, name: []const u8) !?u16 {
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(self.a, &guid);
        if (dispid) |d| {
            try key.append(self.a, 'n');
            var w: [4]u8 = undefined;
            wr32(&w, 0, d);
            try key.appendSlice(self.a, &w);
        } else {
            try key.append(self.a, 's');
            try key.appendSlice(self.a, name);
        }
        if (self.index.get(key.items)) |v| return v;
        if (self.entries.items.len >= 0x7FFE) return null;
        const v: u16 = @intCast(0x8000 + self.entries.items.len);
        try self.entries.append(self.a, .{ .guid = guid, .dispid = dispid, .name = try self.a.dupe(u8, name) });
        try self.index.put(self.a, key.items, v);
        return v;
    }

    /// Properties of the map's PC: bucket count, GUID / entry / string streams, hash buckets.
    pub fn props(self: *NameMapOut) ![]Prop {
        const a = self.a;
        // Outlook registers named properties as soon as it makes a file, and readers (libpff)
        // expect all three streams: make sure there is a string name and a GUID of its own
        _ = try self.id(namemap.PS_PUBLIC_STRINGS, null, "Keywords"); // categories
        _ = try self.id(namemap.PSETID_Common, 0x8503, ""); // PidLidReminderSet
        var guids: std.ArrayList(u8) = .empty;
        var stream: std.ArrayList(u8) = .empty;
        var strings: std.ArrayList(u8) = .empty;
        var buckets: [251]std.ArrayList(u8) = @splat(.empty);
        for (self.entries.items, 0..) |e, i| {
            var wguid: u16 = undefined;
            if (std.mem.eql(u8, &e.guid, &ps_mapi)) wguid = 1 else if (std.mem.eql(u8, &e.guid, &ps_public)) wguid = 2 else {
                var gi: ?usize = null;
                var o: usize = 0;
                while (o < guids.items.len) : (o += 16) if (std.mem.eql(u8, guids.items[o..][0..16], &e.guid)) {
                    gi = o / 16;
                };
                if (gi == null) {
                    gi = guids.items.len / 16;
                    try guids.appendSlice(a, &e.guid);
                }
                wguid = @intCast(3 + gi.?);
            }
            var rec: [8]u8 = undefined;
            var hash_key: u32 = undefined;
            const field: u16 = (wguid << 1) | @intFromBool(e.dispid == null);
            if (e.dispid) |d| {
                wr32(&rec, 0, d);
                hash_key = d;
            } else {
                const w = try std.unicode.utf8ToUtf16LeAlloc(a, e.name);
                const bytes = std.mem.sliceAsBytes(w);
                wr32(&rec, 0, @intCast(strings.items.len));
                var len: [4]u8 = undefined;
                wr32(&len, 0, @intCast(bytes.len));
                try strings.appendSlice(a, &len);
                try strings.appendSlice(a, bytes);
                while (strings.items.len % 4 != 0) try strings.append(a, 0);
                hash_key = crc(bytes); // buckets hold the name's CRC (checked against Outlook's files)
            }
            wr16(&rec, 4, field);
            wr16(&rec, 6, @intCast(i));
            try stream.appendSlice(a, &rec);
            var hrec = rec;
            wr32(&hrec, 0, hash_key);
            try buckets[(hash_key ^ field) % 251].appendSlice(a, &hrec);
        }
        var out: std.ArrayList(Prop) = .empty;
        var count: [4]u8 = undefined;
        wr32(&count, 0, 251);
        try out.append(a, .{ .id = 0x0001, .ptype = PT.int32, .data = try a.dupe(u8, &count) });
        // the minimum is the bucket count alone ([MS-PST] 2.7.3.2)
        if (guids.items.len > 0) try out.append(a, .{ .id = 0x0002, .ptype = PT.binary, .data = guids.items });
        if (stream.items.len > 0) try out.append(a, .{ .id = 0x0003, .ptype = PT.binary, .data = stream.items });
        if (strings.items.len > 0) try out.append(a, .{ .id = 0x0004, .ptype = PT.binary, .data = strings.items });
        for (buckets, 0..) |b, i| if (b.items.len > 0) try out.append(a, .{ .id = @intCast(0x1000 + i), .ptype = PT.binary, .data = b.items });
        return out.items;
    }
};

fn utf16(a: Allocator, s: []const u8) ![]const u8 {
    // bytes that are not UTF-8 (a damaged or legacy name) become U+FFFD, the rest is kept
    const w = try std.unicode.utf8ToUtf16LeAlloc(a, try mime.repairUtf8(a, s));
    return std.mem.sliceAsBytes(w);
}

/// The value of an Int32 property, if it is one (a damaged source can store anything under an id).
fn int32Of(p: ?Prop) ?u32 {
    const v = p orelse return null;
    if (v.ptype != PT.int32 or v.data.len < 4) return null;
    return pst.rd32(v.data, 0);
}

/// The type [MS-PST] requires for the properties the writer relies on; null for any other id.
fn requiredType(id: u16) ?u16 {
    return switch (id) {
        0x001A, 0x0E03, 0x0E04 => PT.unicode,
        0x0E07, 0x0E08, 0x0E17, 0x0E20, 0x3705, 0x370B, 0x0C15 => PT.int32,
        0x3007, 0x3008 => PT.systime,
        0x300B => PT.binary,
        else => null,
    };
}

fn clampU32(v: i64) u32 {
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u32)));
}

fn int32(a: Allocator, v: u32) ![]const u8 {
    const b = try a.alloc(u8, 4);
    wr32(b, 0, v);
    return b;
}

fn boolean(a: Allocator, v: bool) ![]const u8 {
    const b = try a.alloc(u8, 1);
    b[0] = @intFromBool(v);
    return b;
}

fn filetime(a: Allocator, unix: i64) ![]const u8 {
    const b = try a.alloc(u8, 8);
    wr64(b, 0, @intCast(@max(unix + 11_644_473_600, 0) * 10_000_000));
    return b;
}

fn hasProp(props: []const Prop, id: u16) ?Prop {
    for (props) |p| if (p.id == id) return p;
    return null;
}

fn sortProps(props: []Prop) void {
    std.mem.sort(Prop, props, {}, struct {
        fn lt(_: void, x: Prop, y: Prop) bool {
            return x.id < y.id;
        }
    }.lt);
}

pub const Options = struct {
    /// Name of the new data file as Outlook shows it.
    display_name: []const u8 = "pstview export",
    /// Bytes that identify the source; the new file's provider UID is derived from them, so the
    /// same source gives the same file.
    uid_seed: []const u8 = "",
    progress: ?*const fn (done: usize, total: usize) void = null,
    /// One more folder below the top, of items given as properties (the test fixtures use it;
    /// `names` describes the named property ids, 0x8000 and up, that the items use).
    extra: ?Extra = null,
};

pub const Extra = struct {
    name: []const u8,
    class: []const u8,
    names: namemap.NameMap,
    items: []const []const pst.Prop,
};

/// One exported item, for the report written beside the PST.
pub const Item = struct {
    folder: []const u8,
    nid: u32,
    new_nid: u32,
    summary: pst.MessageSummary,
    attachments: []const u8,
    ok: bool,
};

pub const Stats = struct {
    folders: usize = 0,
    messages: usize = 0,
    failed: usize = 0,
    size: u64 = 0,
    items: []Item = &.{},
};

const Source = @import("store.zig").Store;

const FolderOut = struct { nid: u32, name: []const u8, class: []const u8, count: u32, unread: u32, has_sub: bool };

const Exporter = struct {
    gpa: Allocator,
    /// Long-lived allocations (name map, report rows).
    a: Allocator,
    ndb: *Ndb,
    src: Source,
    names: NameMapOut,
    opts: Options,
    uid: [16]u8,
    stats: Stats = .{},
    items: std.ArrayList(Item) = .empty,
    total: usize = 0,
    done: usize = 0,
    /// Source folders already exported / counted: a damaged source can list a folder twice
    /// or below itself, which would otherwise repeat it without end.
    visited: std.AutoHashMapUnmanaged(u32, void) = .empty,
    counted: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Name map of messages that have no PST node (the items of `Options.extra`).
    loose_names: ?namemap.NameMap = null,

    fn entryId(self: *Exporter, nid: u32) ![]const u8 {
        const b = try self.a.alloc(u8, 24);
        @memset(b[0..4], 0);
        @memcpy(b[4..20], &self.uid);
        wr32(b, 20, nid);
        return b;
    }

    const Kind = enum { message, recipient, attachment };

    /// Copy properties for the new file: named properties re-mapped to its name map, ANSI strings
    /// made Unicode, values that only make sense in the source file left out.
    fn transform(self: *Exporter, a: Allocator, src: []const pst.Prop, map: ?namemap.NameMap, kind: Kind) ![]Prop {
        var out: std.ArrayList(Prop) = .empty;
        for (src) |p| {
            switch (p.id) {
                // row id / version, object tables, computed "has attachments"
                0x67F1, 0x67F2, 0x67F3, 0x0E12, 0x0E13, 0x0E1B => continue,
                // the source store's entry ids and keys
                0x0FFA, 0x0FFB, 0x0E09, 0x0E0A => continue,
                0x0FF9, 0x0FFF => if (kind != .recipient) continue,
                else => {},
            }
            if (p.ptype == PT.object or p.ptype == 0x0001 or p.ptype == 0) continue;
            var id = p.id;
            if (id >= 0x8000) {
                const m = map orelse continue;
                const d = m.describe(id) orelse continue;
                id = (try self.names.id(d.guid, d.dispid, d.name)) orelse continue;
            }
            if (hasProp(out.items, id) != null) continue;
            var ptype = p.ptype;
            var data = p.data;
            if (ptype == PT.string8) {
                ptype = PT.unicode;
                data = try utf16(a, try pst.propToString(a, PT.string8, p.data));
            }
            // a property the writer relies on, stored with another type or too short: left
            // out, and filled in like a missing one
            if (requiredType(id)) |t| {
                if (ptype != t) continue;
                if (pst.fixedSize(t)) |sz| if (data.len < sz) continue;
            }
            if (pst.fixedSize(ptype)) |sz| if (data.len < sz) continue;
            try out.append(a, .{ .id = id, .ptype = ptype, .data = data });
        }
        return out.items;
    }

    const MsgOut = struct { data: u64, sub: u64, props: []Prop };

    /// A message node (also an embedded message): PC, recipient table, attachments.
    /// `modified`: the source folder table's modification time, for messages whose own
    /// properties lack one (OSTs keep it in the table only).
    fn message(self: *Exporter, a: Allocator, m: *pst.Message, depth: u8, modified: ?i64) !MsgOut {
        const ndb = self.ndb;
        const map: ?namemap.NameMap = if (m.node) |n| n.pst.nameMap() else self.loose_names;
        var subs: Subs = .{ .a = a };
        var props: std.ArrayList(Prop) = .empty;
        try props.appendSlice(a, try self.transform(a, m.pc.props, map, .message));

        // recipients: their properties live only in the table
        var rtags: std.ArrayList(u32) = .empty;
        try rtags.appendSlice(a, &tpl_recipient);
        var rrows: std.ArrayList(Row) = .empty;
        var to: std.ArrayList(u8) = .empty;
        var cc: std.ArrayList(u8) = .empty;
        for (m.recipients, 0..) |r, i| {
            var rp: std.ArrayList(Prop) = .empty;
            try rp.appendSlice(a, try self.transform(a, r.props, map, .recipient));
            if (hasProp(rp.items, 0x0C15) == null) try rp.append(a, .{ .id = 0x0C15, .ptype = PT.int32, .data = try int32(a, clampU32(@max(r.kind, 1))) });
            if (hasProp(rp.items, 0x3001) == null) try rp.append(a, .{ .id = 0x3001, .ptype = PT.unicode, .data = try utf16(a, r.name) });
            if (hasProp(rp.items, 0x3002) == null and r.addrtype.len > 0) try rp.append(a, .{ .id = 0x3002, .ptype = PT.unicode, .data = try utf16(a, r.addrtype) });
            if (hasProp(rp.items, 0x3003) == null and r.email.len > 0) try rp.append(a, .{ .id = 0x3003, .ptype = PT.unicode, .data = try utf16(a, r.email) });
            if (hasProp(rp.items, 0x0FFE) == null) try rp.append(a, .{ .id = 0x0FFE, .ptype = PT.int32, .data = try int32(a, 6) }); // MAPI_MAILUSER
            if (hasProp(rp.items, 0x3900) == null) try rp.append(a, .{ .id = 0x3900, .ptype = PT.int32, .data = try int32(a, 0) }); // DT_MAILUSER
            if (hasProp(rp.items, 0x0FFF) == null and r.email.len > 0) try rp.append(a, .{ .id = 0x0FFF, .ptype = PT.binary, .data = try oneOff(a, r.name, if (r.addrtype.len > 0) r.addrtype else "SMTP", r.email) });
            for (rp.items) |p| {
                const tag = (@as(u32, p.id) << 16) | p.ptype;
                // a table has at most 255 columns (and its column list must fit one heap item)
                if (rtags.items.len >= 250) break;
                if (std.mem.indexOfScalar(u32, rtags.items, tag) == null) try rtags.append(a, tag);
            }
            try rrows.append(a, .{ .id = @intCast(i), .props = rp.items });
            const list = if (r.kind == 2) &cc else if (r.kind == 1) &to else null;
            if (list) |l| {
                if (l.items.len > 0) try l.appendSlice(a, "; ");
                try l.appendSlice(a, if (r.name.len > 0) r.name else r.email);
            }
        }
        const rt = try writeTc(a, ndb, rtags.items, rrows.items);
        try subs.list.append(a, .{ .nid = pst.NID.recipient_table, .data = rt.data, .sub = rt.sub });

        // attachments
        var arows: std.ArrayList(Row) = .empty;
        var size: u64 = 0;
        for (m.attachments, 0..) |*att, i| {
            const anid: u32 = (@as(u32, @intCast(i + 1)) << 5) | 0x05; // NID_TYPE_ATTACHMENT
            var asubs: Subs = .{ .a = a };
            var ap: std.ArrayList(Prop) = .empty;
            try ap.appendSlice(a, try self.transform(a, att.pc.props, map, .attachment));
            if (att.method == 5 and depth < 8) {
                if (pst.embeddedMessage(a, att) catch null) |inner_c| {
                    var inner = inner_c;
                    const inner_out = try self.message(a, &inner, depth + 1, null);
                    const enid: u32 = (1 << 5) | 0x04;
                    try asubs.list.append(a, .{ .nid = enid, .data = inner_out.data, .sub = inner_out.sub });
                    const inner_size: u32 = int32Of(hasProp(inner_out.props, 0x0E08)) orelse 0;
                    const obj = try a.alloc(u8, 8);
                    wr32(obj, 0, enid);
                    wr32(obj, 4, inner_size);
                    try ap.append(a, .{ .id = 0x3701, .ptype = PT.object, .data = obj });
                }
            }
            const data_len: u64 = if (hasProp(ap.items, 0x3701)) |p| (if (p.ptype == PT.binary) p.data.len else 0) else 0;
            size += data_len;
            if (hasProp(ap.items, 0x0E20) == null) try ap.append(a, .{ .id = 0x0E20, .ptype = PT.int32, .data = try int32(a, @intCast(@min(data_len, std.math.maxInt(i32)))) });
            if (hasProp(ap.items, 0x3705) == null) try ap.append(a, .{ .id = 0x3705, .ptype = PT.int32, .data = try int32(a, clampU32(@max(att.method, 1))) });
            if (hasProp(ap.items, 0x370B) == null) try ap.append(a, .{ .id = 0x370B, .ptype = PT.int32, .data = try int32(a, 0xFFFFFFFF) });
            sortProps(ap.items);
            const adata = try writePc(a, ndb, &asubs, ap.items);
            try subs.list.append(a, .{ .nid = anid, .data = adata, .sub = try ndb.writeSubnodes(asubs.list.items) });
            try arows.append(a, .{ .id = anid, .props = ap.items });
        }
        if (arows.items.len > 0) {
            const at = try writeTc(a, ndb, &tpl_attachment, arows.items);
            try subs.list.append(a, .{ .nid = pst.NID.attachment_table, .data = at.data, .sub = at.sub });
        }

        // what Outlook needs on every message ([MS-PST] 2.4.5.1.1), when the source lacks it
        if (hasProp(props.items, 0x001A) == null) try props.append(a, .{ .id = 0x001A, .ptype = PT.unicode, .data = try utf16(a, "IPM.Note") });
        var flags: u32 = int32Of(hasProp(props.items, 0x0E07)) orelse 0x01;
        if (m.attachments.len > 0) flags |= 0x10 else flags &= ~@as(u32, 0x10);
        for (props.items) |*p| if (p.id == 0x0E07) {
            p.data = try int32(a, flags);
        };
        if (hasProp(props.items, 0x0E07) == null) try props.append(a, .{ .id = 0x0E07, .ptype = PT.int32, .data = try int32(a, flags) });
        if (hasProp(props.items, 0x0E08) == null) {
            for (props.items) |p| size += p.data.len + 8;
            try props.append(a, .{ .id = 0x0E08, .ptype = PT.int32, .data = try int32(a, @intCast(@min(size, std.math.maxInt(i32)))) });
        }
        if (hasProp(props.items, 0x0E17) == null) try props.append(a, .{ .id = 0x0E17, .ptype = PT.int32, .data = try int32(a, 0) });
        const when: ?Prop = hasProp(props.items, 0x0E06) orelse hasProp(props.items, 0x0039) orelse hasProp(props.items, 0x3007) orelse hasProp(props.items, 0x3008);
        const when_data = if (when) |w| w.data else try filetime(a, 0);
        if (hasProp(props.items, 0x3007) == null) try props.append(a, .{ .id = 0x3007, .ptype = PT.systime, .data = when_data });
        if (hasProp(props.items, 0x3008) == null) try props.append(a, .{ .id = 0x3008, .ptype = PT.systime, .data = if (modified) |t| try filetime(a, t) else when_data });
        if (hasProp(props.items, 0x300B) == null) {
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            for (props.items) |p| if (p.id == 0x1035 or p.id == 0x0037 or p.id == 0x0039 or p.id == 0x0E06) h.update(p.data);
            h.update(&self.uid);
            var d: [32]u8 = undefined;
            h.final(&d);
            try props.append(a, .{ .id = 0x300B, .ptype = PT.binary, .data = try a.dupe(u8, d[0..16]) });
        }
        if (hasProp(props.items, 0x0E04) == null and to.items.len > 0) try props.append(a, .{ .id = 0x0E04, .ptype = PT.unicode, .data = try utf16(a, to.items) });
        if (hasProp(props.items, 0x0E03) == null and cc.items.len > 0) try props.append(a, .{ .id = 0x0E03, .ptype = PT.unicode, .data = try utf16(a, cc.items) });
        sortProps(props.items);
        const data = try writePc(a, ndb, &subs, props.items);
        return .{ .data = data, .sub = try ndb.writeSubnodes(subs.list.items), .props = props.items };
    }

    /// The four nodes of a folder: PC, hierarchy, contents and associated contents tables.
    fn folderNodes(self: *Exporter, a: Allocator, nid: u32, parent: u32, name: []const u8, class: []const u8, count: u32, unread: u32, kids: []const FolderOut, contents: []const Row) !void {
        const ndb = self.ndb;
        var props: std.ArrayList(Prop) = .empty;
        try props.append(a, .{ .id = 0x3001, .ptype = PT.unicode, .data = try utf16(a, name) });
        try props.append(a, .{ .id = 0x3602, .ptype = PT.int32, .data = try int32(a, count) });
        try props.append(a, .{ .id = 0x3603, .ptype = PT.int32, .data = try int32(a, unread) });
        try props.append(a, .{ .id = 0x360A, .ptype = PT.boolean, .data = try boolean(a, kids.len > 0) });
        if (class.len > 0) try props.append(a, .{ .id = 0x3613, .ptype = PT.unicode, .data = try utf16(a, class) });
        var subs: Subs = .{ .a = a };
        try ndb.addNode(nid, try writePc(a, ndb, &subs, props.items), try ndb.writeSubnodes(subs.list.items), parent);

        var hrows: std.ArrayList(Row) = .empty;
        for (kids) |k| {
            var kp: std.ArrayList(Prop) = .empty;
            try kp.append(a, .{ .id = 0x3001, .ptype = PT.unicode, .data = try utf16(a, k.name) });
            try kp.append(a, .{ .id = 0x3602, .ptype = PT.int32, .data = try int32(a, k.count) });
            try kp.append(a, .{ .id = 0x3603, .ptype = PT.int32, .data = try int32(a, k.unread) });
            try kp.append(a, .{ .id = 0x360A, .ptype = PT.boolean, .data = try boolean(a, k.has_sub) });
            if (k.class.len > 0) try kp.append(a, .{ .id = 0x3613, .ptype = PT.unicode, .data = try utf16(a, k.class) });
            try kp.append(a, .{ .id = 0x6635, .ptype = PT.int32, .data = try int32(a, 0) });
            try kp.append(a, .{ .id = 0x6636, .ptype = PT.int32, .data = try int32(a, 0) });
            try hrows.append(a, .{ .id = k.nid, .props = kp.items });
        }
        const ht = try writeTc(a, ndb, &tpl_hierarchy, hrows.items);
        try ndb.addNode(tableNid(nid, 0x0D), ht.data, ht.sub, 0);
        const ct = try writeTc(a, ndb, &tpl_contents, contents);
        try ndb.addNode(tableNid(nid, 0x0E), ct.data, ct.sub, 0);
        const ft = try writeTc(a, ndb, &tpl_assoc, &.{});
        try ndb.addNode(tableNid(nid, 0x0F), ft.data, ft.sub, 0);
    }

    fn progress(self: *Exporter) void {
        if (self.opts.progress) |p| p(self.done, self.total);
    }

    /// Export source folder `src_id` (its messages and sub-folders) as folder `nid`.
    fn folder(self: *Exporter, src_id: u32, nid: u32, parent: u32, path: []const u8, name_override: ?[]const u8, depth: u32) anyerror!FolderOut {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const fa = arena.allocator();
        const info = self.src.folderInfo(fa, src_id) catch pst.FolderInfo{ .nid = src_id, .name = "", .count = 0, .unread = 0, .has_subfolders = false, .container_class = "" };
        const name = try self.a.dupe(u8, name_override orelse (if (info.name.len > 0) info.name else "(unnamed)"));
        const class = try self.a.dupe(u8, info.container_class);
        const fpath = if (path.len == 0) name else try std.fmt.allocPrint(self.a, "{s}/{s}", .{ path, name });
        self.stats.folders += 1;

        // messages
        var rows: std.ArrayList(Row) = .empty;
        var count: u32 = 0;
        var unread: u32 = 0;
        const msgs = self.src.folderMessages(fa, src_id) catch &.{};
        for (msgs) |s| {
            var ma = std.heap.ArenaAllocator.init(self.gpa);
            defer ma.deinit();
            const a = ma.allocator();
            self.done += 1;
            if (self.done % 25 == 0) self.progress();
            var item: Item = .{ .folder = fpath, .nid = s.nid, .new_nid = 0, .summary = try dupSummary(self.a, s), .attachments = "", .ok = false };
            if (self.src.loadMessage(a, s.nid)) |m_c| {
                var m = m_c;
                var att_names: std.ArrayList(u8) = .empty;
                for (m.attachments, 0..) |att, i| {
                    if (i > 0) try att_names.appendSlice(a, "; ");
                    try att_names.appendSlice(a, if (att.filename.len > 0) att.filename else "(embedded item)");
                }
                item.attachments = try self.a.dupe(u8, att_names.items);
                if (self.message(a, &m, 0, s.modified_time)) |out| {
                    const mnid = self.ndb.newNid(0x04);
                    try self.ndb.addNode(mnid, out.data, out.sub, nid);
                    // the contents table row copies the template columns from the message
                    var kept: std.ArrayList(Prop) = .empty;
                    for (out.props) |p| {
                        const tag = (@as(u32, p.id) << 16) | p.ptype;
                        if (std.mem.indexOfScalar(u32, &tpl_contents, tag) != null) try kept.append(fa, .{ .id = p.id, .ptype = p.ptype, .data = try fa.dupe(u8, p.data) });
                    }
                    try rows.append(fa, .{ .id = mnid, .props = kept.items });
                    count += 1;
                    if ((int32Of(hasProp(out.props, 0x0E07)) orelse 1) & 0x01 == 0) unread += 1;
                    item.new_nid = mnid;
                    item.ok = true;
                    self.stats.messages += 1;
                } else |e| {
                    if (e == error.OutOfMemory) return e;
                    self.stats.failed += 1;
                }
            } else |_| self.stats.failed += 1;
            try self.items.append(self.a, item);
        }

        // sub-folders (a damaged source can nest without end: stop at 64 levels)
        var kids: std.ArrayList(FolderOut) = .empty;
        if (depth < 64) {
            const subs = self.src.subFolders(fa, src_id) catch &.{};
            for (subs) |k| {
                if ((try self.visited.getOrPut(self.a, k)).found_existing) continue;
                const knid = self.ndb.newNid(0x02);
                try kids.append(fa, try self.folder(k, knid, nid, fpath, null, depth + 1));
            }
        }
        try self.folderNodes(fa, nid, parent, name, class, count, unread, kids.items, rows.items);
        return .{ .nid = nid, .name = name, .class = class, .count = count, .unread = unread, .has_sub = kids.items.len > 0 };
    }

    /// The folder of `Options.extra`.
    fn extraFolder(self: *Exporter, x: Extra, nid: u32, parent: u32) !FolderOut {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const fa = arena.allocator();
        self.loose_names = x.names;
        defer self.loose_names = null;
        var rows: std.ArrayList(Row) = .empty;
        for (x.items) |props| {
            var m: pst.Message = .{ .nid = 0, .node = null, .pc = .{ .props = try fa.dupe(pst.Prop, props) }, .recipients = &.{}, .attachments = &.{} };
            const out = try self.message(fa, &m, 0, null);
            const mnid = self.ndb.newNid(0x04);
            try self.ndb.addNode(mnid, out.data, out.sub, nid);
            var kept: std.ArrayList(Prop) = .empty;
            for (out.props) |p| {
                const tag = (@as(u32, p.id) << 16) | p.ptype;
                if (std.mem.indexOfScalar(u32, &tpl_contents, tag) != null) try kept.append(fa, p);
            }
            try rows.append(fa, .{ .id = mnid, .props = kept.items });
            self.stats.messages += 1;
        }
        self.stats.folders += 1;
        const count: u32 = @intCast(x.items.len);
        try self.folderNodes(fa, nid, parent, x.name, x.class, count, 0, &.{}, rows.items);
        return .{ .nid = nid, .name = try self.a.dupe(u8, x.name), .class = try self.a.dupe(u8, x.class), .count = count, .unread = 0, .has_sub = false };
    }

    fn countAll(self: *Exporter, id: u32, depth: u32) void {
        if ((self.counted.getOrPut(self.a, id) catch return).found_existing) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const info = self.src.folderInfo(arena.allocator(), id) catch return;
        self.total += @intCast(@max(info.count, 0));
        if (depth >= 64) return;
        for (self.src.subFolders(arena.allocator(), id) catch &.{}) |k| self.countAll(k, depth + 1);
    }

    /// The folder whose sub-folders are the user's folders.
    fn userRoot(self: *Exporter) u32 {
        return switch (self.src) {
            .pst => |p| blk: {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                break :blk pst.ipmSubtree(arena.allocator(), p) orelse pst.NID.root_folder;
            },
            .set => 1, // the merged "Mailbox" (multi.zig)
            .mbox => |m| m.rootFolder(),
        };
    }

    fn run(self: *Exporter) !void {
        const a = self.a;
        const ndb = self.ndb;
        const top = self.userRoot();
        self.countAll(top, 0);
        // the fixed folders come first; new folders are numbered after them
        for ([_]u32{ nid_ipm, nid_search_root, nid_deleted }) |n| ndb.noteNid(n);

        // the user's folders below "Top of Personal Folders"; a top-level "Deleted Items"
        // becomes the file's own Deleted Items folder
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const fa = arena.allocator();
        var kids: std.ArrayList(FolderOut) = .empty;
        var deleted: ?FolderOut = null;
        try self.visited.put(self.a, top, {});
        for (self.src.subFolders(fa, top) catch &.{}) |k| {
            if ((try self.visited.getOrPut(self.a, k)).found_existing) continue;
            const info = self.src.folderInfo(fa, k) catch continue;
            if (deleted == null and std.ascii.eqlIgnoreCase(info.name, "Deleted Items")) {
                deleted = try self.folder(k, nid_deleted, nid_ipm, "", "Deleted Items", 1);
                continue;
            }
            try kids.append(fa, try self.folder(k, ndb.newNid(0x02), nid_ipm, "", null, 1));
        }
        if (self.opts.extra) |x| try kids.append(fa, try self.extraFolder(x, ndb.newNid(0x02), nid_ipm));
        if (deleted == null) {
            try self.folderNodes(fa, nid_deleted, nid_ipm, "Deleted Items", "", 0, 0, &.{}, &.{});
            deleted = .{ .nid = nid_deleted, .name = "Deleted Items", .class = "", .count = 0, .unread = 0, .has_sub = false };
        }
        try kids.insert(fa, 0, deleted.?);
        try self.folderNodes(fa, nid_ipm, nid_root, "Top of Personal Folders", "", 0, 0, kids.items, &.{});

        // the rest of the minimum PST ([MS-PST] 2.7)
        try self.folderNodes(fa, nid_search_root, nid_root, "Search Root", "", 0, 0, &.{}, &.{});
        {
            var props: std.ArrayList(Prop) = .empty;
            try props.append(fa, .{ .id = 0x3001, .ptype = PT.unicode, .data = try utf16(fa, "SPAM Search Folder 2") });
            try props.append(fa, .{ .id = 0x3602, .ptype = PT.int32, .data = try int32(fa, 0) });
            try props.append(fa, .{ .id = 0x3603, .ptype = PT.int32, .data = try int32(fa, 0) });
            try props.append(fa, .{ .id = 0x360A, .ptype = PT.boolean, .data = try boolean(fa, false) });
            var subs: Subs = .{ .a = fa };
            try ndb.addNode(nid_spam, try writePc(fa, ndb, &subs, props.items), 0, nid_root);
            const st = try writeTc(fa, ndb, &tpl_search, &.{});
            try ndb.addNode(tableNid(nid_spam, 0x10), st.data, st.sub, 0);
        }
        const root_kids = [_]FolderOut{
            .{ .nid = nid_ipm, .name = "Top of Personal Folders", .class = "", .count = 0, .unread = 0, .has_sub = true },
            .{ .nid = nid_search_root, .name = "Search Root", .class = "", .count = 0, .unread = 0, .has_sub = false },
            .{ .nid = nid_spam, .name = "SPAM Search Folder 2", .class = "", .count = 0, .unread = 0, .has_sub = false },
        };
        try self.folderNodes(fa, nid_root, nid_root, "", "", 0, 0, &root_kids, &.{});
        inline for (.{ .{ 0x60D, &tpl_hierarchy }, .{ 0x60E, &tpl_contents }, .{ 0x60F, &tpl_assoc }, .{ 0x610, &tpl_search }, .{ 0x671, &tpl_attachment }, .{ 0x692, &tpl_recipient } }) |t| {
            const tc = try writeTc(fa, ndb, t[1], &.{});
            try ndb.addNode(t[0], tc.data, tc.sub, 0);
        }
        try ndb.addNode(0x1E1, 0, 0, 0); // search management queue (empty)
        try ndb.addNode(0x201, 0, 0, 0); // search activity list (empty)

        // name-to-id map and message store
        var subs: Subs = .{ .a = fa };
        const nm = try self.names.props();
        try ndb.addNode(pst.NID.name_to_id_map, try writePc(fa, ndb, &subs, nm), try ndb.writeSubnodes(subs.list.items), 0);
        var sp: std.ArrayList(Prop) = .empty;
        try sp.append(fa, .{ .id = 0x0FF9, .ptype = PT.binary, .data = &self.uid });
        try sp.append(fa, .{ .id = 0x3001, .ptype = PT.unicode, .data = try utf16(fa, self.opts.display_name) });
        try sp.append(fa, .{ .id = 0x35DF, .ptype = PT.int32, .data = try int32(fa, 0x89) }); // IPM subtree, wastebasket, finder valid
        try sp.append(fa, .{ .id = 0x35E0, .ptype = PT.binary, .data = try self.entryId(nid_ipm) });
        try sp.append(fa, .{ .id = 0x35E3, .ptype = PT.binary, .data = try self.entryId(nid_deleted) });
        try sp.append(fa, .{ .id = 0x35E7, .ptype = PT.binary, .data = try self.entryId(nid_search_root) });
        try sp.append(fa, .{ .id = 0x67FF, .ptype = PT.int32, .data = try int32(fa, 0) }); // no password
        var ssubs: Subs = .{ .a = fa };
        try ndb.addNode(pst.NID.message_store, try writePc(fa, ndb, &ssubs, sp.items), try ndb.writeSubnodes(ssubs.list.items), 0);
        _ = a;
        self.progress();
    }
};

fn dupSummary(a: Allocator, s: pst.MessageSummary) !pst.MessageSummary {
    var d = s;
    d.subject = try a.dupe(u8, s.subject);
    d.from = try a.dupe(u8, s.from);
    d.to = try a.dupe(u8, s.to);
    d.cc = try a.dupe(u8, s.cc);
    d.message_class = try a.dupe(u8, s.message_class);
    d.note = try a.dupe(u8, s.note);
    return d;
}

/// MAPI one-off entry id for a recipient address ([MS-OXCDATA] 2.2.5.1), Unicode strings.
fn oneOff(a: Allocator, name: []const u8, addrtype: []const u8, email: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendNTimes(a, 0, 4);
    try out.appendSlice(a, &[_]u8{ 0x81, 0x2B, 0x1F, 0xA4, 0xBE, 0xA3, 0x10, 0x19, 0x9D, 0x6E, 0x00, 0xDD, 0x01, 0x0F, 0x54, 0x02 });
    try out.appendSlice(a, &[_]u8{ 0x00, 0x00, 0x01, 0x90 }); // version 0, MAPI_ONE_OFF_UNICODE | MAPI_ONE_OFF_NO_RICH_INFO
    for ([_][]const u8{ if (name.len > 0) name else email, addrtype, email }) |s| {
        try out.appendSlice(a, try utf16(a, s));
        try out.appendSlice(a, &[_]u8{ 0, 0 });
    }
    return out.items;
}

/// Write `src` as a new PST at `out_path`: first to "<out_path>.partial", renamed when complete,
/// so a failed export leaves no file that looks finished. Report rows go to `report_arena`.
pub fn exportStore(gpa: Allocator, io: Io, src: Source, out_path: []const u8, opts: Options, report_arena: Allocator) !Stats {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.partial", .{out_path});
    defer gpa.free(tmp);
    const cwd = Io.Dir.cwd();
    const file = try cwd.createFile(io, tmp, .{ .read = true, .truncate = true });
    var ok = false;
    defer if (!ok) {
        file.close(io);
        cwd.deleteFile(io, tmp) catch {};
    };
    var ndb = try Ndb.init(gpa, io, file);
    defer ndb.deinit();
    var uid: [16]u8 = undefined;
    {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("pstview pst export");
        h.update(opts.uid_seed);
        var d: [32]u8 = undefined;
        h.final(&d);
        uid = d[0..16].*;
    }
    var ex: Exporter = .{ .gpa = gpa, .a = report_arena, .ndb = &ndb, .src = src, .names = .{ .a = report_arena }, .opts = opts, .uid = uid };
    try ex.run();
    const size = try ndb.finish();
    try file.sync(io);
    file.close(io);
    ok = true;
    try cwd.rename(tmp, cwd, out_path, io);
    ex.stats.size = size;
    ex.stats.items = ex.items.items;
    return ex.stats;
}

/// Refuse to write over a file that is part of the source: sources are evidence and are never
/// written to.
pub fn checkTarget(a: Allocator, io: Io, src: Source, src_path: []const u8, out_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const target = cwd.realPathFileAlloc(io, out_path, a) catch |e| switch (e) {
        error.FileNotFound => return, // a new file cannot be a source
        else => return e,
    };
    for (try src.sourceFiles(a, src_path)) |sf| {
        const real = cwd.realPathFileAlloc(io, sf.path, a) catch continue;
        if (std.mem.eql(u8, real, target)) return error.TargetIsSource;
    }
    const st = try cwd.statFile(io, out_path, .{});
    if (st.kind == .directory) return error.TargetIsDirectory;
}

pub fn targetErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.TargetIsSource => "The new PST would replace a file of the source. Sources are never written to: choose another name.",
        error.TargetIsDirectory => "The target is a folder: give a file name for the new PST.",
        else => @errorName(e),
    };
}

/// Report rows of an export; the "exported as" column names the item's node in the new file.
pub fn reportRows(a: Allocator, stats: Stats) ![]@import("export.zig").ReportRow {
    const rows = try a.alloc(@import("export.zig").ReportRow, stats.items.len);
    for (stats.items, rows) |it, *r| {
        const s = it.summary;
        r.* = .{
            .folder = it.folder,
            .nid = it.nid,
            .received = s.delivery_time,
            .sent = s.submit_time,
            .modified = s.modified_time,
            .from = s.from,
            .to = s.to,
            .cc = s.cc,
            .subject = s.subject,
            .class = s.message_class,
            .size = s.size,
            .attachments = it.attachments,
            .export_file = if (it.ok) try std.fmt.allocPrint(a, "PST item 0x{x:0>8}", .{it.new_nid}) else "NOT EXPORTED",
        };
    }
    return rows;
}

// ================================================================ tests

const testing = std.testing;

test "name map: hash buckets as in Outlook's files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var m: NameMapOut = .{ .a = arena.allocator() };
    try testing.expectEqual(@as(?u16, 0x8000), try m.id(namemap.PS_PUBLIC_STRINGS, null, "Keywords"));
    try testing.expectEqual(@as(?u16, 0x8000), try m.id(namemap.PS_PUBLIC_STRINGS, null, "Keywords"));
    try testing.expectEqual(@as(?u16, 0x8001), try m.id(namemap.PSETID_Appointment, 0x820D, ""));
    const props = try m.props();
    // An Outlook-made PST keeps "Keywords" (PS_PUBLIC_STRINGS, string name) in bucket 0x65 as
    // { CRC32 of the UTF-16 name = 0x2EDA4D3B, wGuid 2 | N, index }.
    const b = hasProp(props, 0x1065).?;
    try testing.expectEqualSlices(u8, &[_]u8{ 0x3B, 0x4D, 0xDA, 0x2E, 0x05, 0x00, 0x00, 0x00 }, b.data[0..8]);
    try testing.expectEqual(@as(u32, 251), pst.rd32(hasProp(props, 0x0001).?.data, 0));
    // the appointment GUID is the first in the GUID stream (wGuid 3)
    try testing.expectEqualSlices(u8, &namemap.PSETID_Appointment, hasProp(props, 0x0002).?.data[0..16]);
    const entries = hasProp(props, 0x0003).?.data;
    try testing.expectEqual(@as(u32, 0x820D), pst.rd32(entries, 8));
    try testing.expectEqual(@as(u16, 3 << 1), pst.rd16(entries, 12));
}

test "table layout: row id and version first, cells grouped by size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const l = try layout(arena.allocator(), &tpl_hierarchy);
    try testing.expectEqual(@as(usize, 13), l.cols.len);
    for (l.cols, 0..) |c, i| {
        if (i > 0) try testing.expect(l.cols[i - 1].tag < c.tag);
        if (c.tag == 0x67F20003) try testing.expect(c.ib == 0 and c.ibit == 0);
        if (c.tag == 0x67F30003) try testing.expect(c.ib == 4 and c.ibit == 1);
        if (c.tag == 0x0E330014) try testing.expect(c.cb == 8 and c.ib % 8 == 0);
        if (c.tag == 0x360A000B) try testing.expectEqual(@as(u8, 1), c.cb);
    }
    // 8 + 8-byte cell + 9 four-byte cells, then one boolean, then 2 bytes of existence bits
    try testing.expectEqual([4]u16{ 52, 52, 53, 55 }, l.rgib);
}

test "heap: items, page map and HIDs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var h = Heap.init(arena.allocator(), 0xBC);
    const h1 = try h.alloc("abc");
    const h2 = try h.alloc("defgh");
    try testing.expectEqual(@as(u32, 0x20), h1);
    try testing.expectEqual(@as(u32, 0x40), h2);
    h.user_root = h1;
    const blocks = try h.finish();
    try testing.expectEqual(@as(usize, 1), blocks.len);
    // read it back with the reader's heap
    const ro = try pst.Heap.init(blocks, .unicode);
    try testing.expectEqual(@as(u8, 0xBC), ro.client_sig);
    try testing.expectEqualStrings("abc", try ro.get(h1));
    try testing.expectEqualStrings("defgh", try ro.get(h2));
    // a heap that needs many blocks gets the bitmap header in block 8
    var big = Heap.init(arena.allocator(), 0x7C);
    const item: [3000]u8 = @splat(7);
    var last: u32 = 0;
    for (0..40) |_| last = try big.alloc(&item);
    const bb = try big.finish();
    try testing.expect(bb.len > 9);
    const ro2 = try pst.Heap.init(bb, .unicode);
    try testing.expectEqualSlices(u8, &item, try ro2.get(last));
}
