//! Read-only Outlook PST / OST (Unicode, MS-PST) reader.
//!
//! Two on-disk variants are supported:
//!   * wVer 23 - Unicode PST and Outlook 2003-2010 OST: 512-byte B-tree pages, blocks up to
//!     8 KiB padded to 64 bytes with a 16-byte trailer.
//!   * wVer 36 - Outlook 2013+ OST ("4K"): 4096-byte B-tree pages, blocks up to 64 KiB padded
//!     to 512 bytes with a 24-byte trailer, block payloads optionally zlib-compressed.
//!     Not covered by [MS-PST]; layout per libpff's PFF notes, checked against real OSTs.
//!
//! Layers (per [MS-PST]):
//!   NDB  - header, node B-tree (NBT), block B-tree (BBT), data/sub-node blocks
//!   LTP  - heap-on-node (HN), BTree-on-heap (BTH), property context (PC), table context (TC)
//!   Msg  - folders, messages, recipients, attachments
//!
//! The file is opened read-only and never written to, so evidence files are not modified.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rtfcp = @import("rtfcp.zig");
const namemap = @import("namemap.zig");
const mime = @import("mime.zig");

pub const Error = error{ NotPst, UnsupportedFormat, Corrupt, NotFound };

// ---------------------------------------------------------------- little-endian helpers

inline fn need(b: []const u8, off: usize, n: usize) Error!void {
    if (off > b.len or b.len - off < n) return error.Corrupt;
}
pub inline fn rd8(b: []const u8, o: usize) u8 {
    return b[o];
}
pub inline fn rd16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
pub inline fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
pub inline fn rd64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}

// ---------------------------------------------------------------- property ids / types

pub const PT = struct {
    pub const int16: u16 = 0x0002;
    pub const int32: u16 = 0x0003;
    pub const float32: u16 = 0x0004;
    pub const float64: u16 = 0x0005;
    pub const currency: u16 = 0x0006;
    pub const apptime: u16 = 0x0007;
    pub const err: u16 = 0x000A;
    pub const boolean: u16 = 0x000B;
    pub const object: u16 = 0x000D;
    pub const int64: u16 = 0x0014;
    pub const string8: u16 = 0x001E;
    pub const unicode: u16 = 0x001F;
    pub const systime: u16 = 0x0040;
    pub const guid: u16 = 0x0048;
    pub const binary: u16 = 0x0102;
    pub const mv_flag: u16 = 0x1000;
};

pub const Tag = struct {
    pub const message_class: u16 = 0x001A;
    pub const subject: u16 = 0x0037;
    pub const client_submit_time: u16 = 0x0039;
    pub const sent_repr_name: u16 = 0x0042;
    pub const sent_repr_email: u16 = 0x0065;
    pub const sent_repr_addrtype: u16 = 0x0064;
    pub const transport_headers: u16 = 0x007D;
    pub const sender_name: u16 = 0x0C1A;
    pub const sender_email: u16 = 0x0C1F;
    pub const sender_addrtype: u16 = 0x0C1E;
    pub const recipient_type: u16 = 0x0C15;
    pub const display_bcc: u16 = 0x0E02;
    pub const display_cc: u16 = 0x0E03;
    pub const display_to: u16 = 0x0E04;
    pub const delivery_time: u16 = 0x0E06;
    pub const message_flags: u16 = 0x0E07;
    pub const message_size: u16 = 0x0E08;
    pub const has_attachments: u16 = 0x0E1B;
    pub const attach_size: u16 = 0x0E20;
    pub const body: u16 = 0x1000;
    pub const rtf_compressed: u16 = 0x1009;
    pub const body_html: u16 = 0x1013;
    pub const internet_message_id: u16 = 0x1035;
    pub const display_name: u16 = 0x3001;
    pub const addrtype: u16 = 0x3002;
    pub const email_address: u16 = 0x3003;
    pub const creation_time: u16 = 0x3007;
    pub const last_modified: u16 = 0x3008;
    pub const content_count: u16 = 0x3602;
    pub const content_unread: u16 = 0x3603;
    pub const subfolders: u16 = 0x360A;
    pub const container_class: u16 = 0x3613;
    pub const attach_data: u16 = 0x3701;
    pub const attach_filename: u16 = 0x3704;
    pub const attach_method: u16 = 0x3705;
    pub const attach_long_filename: u16 = 0x3707;
    pub const attach_mime_tag: u16 = 0x370E;
    pub const attach_content_id: u16 = 0x3712;
    pub const smtp_address: u16 = 0x39FE;
    pub const sender_smtp: u16 = 0x5D01;
    pub const sent_repr_smtp: u16 = 0x5D02;
    pub const internet_cpid: u16 = 0x3FDE;
};

/// NIDs of well-known nodes.
pub const NID = struct {
    pub const message_store: u32 = 0x21;
    pub const name_to_id_map: u32 = 0x61;
    pub const root_folder: u32 = 0x122;
    pub const recipient_table: u32 = 0x692;
    pub const attachment_table: u32 = 0x671;
};

const nid_type_hierarchy_table: u32 = 0x0D;
const nid_type_contents_table: u32 = 0x0E;

/// Compressible-encryption decode table ([MS-PST] 5.1, NDB_CRYPT_PERMUTE).
const crypt_permute_decode = [256]u8{
    0x47, 0xf1, 0xb4, 0xe6, 0x0b, 0x6a, 0x72, 0x48, 0x85, 0x4e, 0x9e, 0xeb, 0xe2, 0xf8, 0x94, 0x53,
    0xe0, 0xbb, 0xa0, 0x02, 0xe8, 0x5a, 0x09, 0xab, 0xdb, 0xe3, 0xba, 0xc6, 0x7c, 0xc3, 0x10, 0xdd,
    0x39, 0x05, 0x96, 0x30, 0xf5, 0x37, 0x60, 0x82, 0x8c, 0xc9, 0x13, 0x4a, 0x6b, 0x1d, 0xf3, 0xfb,
    0x8f, 0x26, 0x97, 0xca, 0x91, 0x17, 0x01, 0xc4, 0x32, 0x2d, 0x6e, 0x31, 0x95, 0xff, 0xd9, 0x23,
    0xd1, 0x00, 0x5e, 0x79, 0xdc, 0x44, 0x3b, 0x1a, 0x28, 0xc5, 0x61, 0x57, 0x20, 0x90, 0x3d, 0x83,
    0xb9, 0x43, 0xbe, 0x67, 0xd2, 0x46, 0x42, 0x76, 0xc0, 0x6d, 0x5b, 0x7e, 0xb2, 0x0f, 0x16, 0x29,
    0x3c, 0xa9, 0x03, 0x54, 0x0d, 0xda, 0x5d, 0xdf, 0xf6, 0xb7, 0xc7, 0x62, 0xcd, 0x8d, 0x06, 0xd3,
    0x69, 0x5c, 0x86, 0xd6, 0x14, 0xf7, 0xa5, 0x66, 0x75, 0xac, 0xb1, 0xe9, 0x45, 0x21, 0x70, 0x0c,
    0x87, 0x9f, 0x74, 0xa4, 0x22, 0x4c, 0x6f, 0xbf, 0x1f, 0x56, 0xaa, 0x2e, 0xb3, 0x78, 0x33, 0x50,
    0xb0, 0xa3, 0x92, 0xbc, 0xcf, 0x19, 0x1c, 0xa7, 0x63, 0xcb, 0x1e, 0x4d, 0x3e, 0x4b, 0x1b, 0x9b,
    0x4f, 0xe7, 0xf0, 0xee, 0xad, 0x3a, 0xb5, 0x59, 0x04, 0xea, 0x40, 0x55, 0x25, 0x51, 0xe5, 0x7a,
    0x89, 0x38, 0x68, 0x52, 0x7b, 0xfc, 0x27, 0xae, 0xd7, 0xbd, 0xfa, 0x07, 0xf4, 0xcc, 0x8e, 0x5f,
    0xef, 0x35, 0x9c, 0x84, 0x2b, 0x15, 0xd5, 0x77, 0x34, 0x49, 0xb6, 0x12, 0x0a, 0x7f, 0x71, 0x88,
    0xfd, 0x9d, 0x18, 0x41, 0x7d, 0x93, 0xd8, 0x58, 0x2c, 0xce, 0xfe, 0x24, 0xaf, 0xde, 0xb8, 0x36,
    0xc8, 0xa1, 0x80, 0xa6, 0x99, 0x98, 0xa8, 0x2f, 0x0e, 0x81, 0x65, 0x73, 0xe4, 0xc2, 0xa2, 0x8a,
    0xd4, 0xe1, 0x11, 0xd0, 0x08, 0x8b, 0x2a, 0xf2, 0xed, 0x9a, 0x64, 0x3f, 0xc1, 0x6c, 0xf9, 0xec,
};

/// On-disk layout variant, chosen from the header's wVer.
pub const Format = enum {
    /// wVer 23: Unicode PST, Outlook 2003-2010 OST.
    unicode,
    /// wVer 36: Outlook 2013+ OST with 4 KiB pages and compressed blocks.
    unicode_4k,

    pub fn label(f: Format) []const u8 {
        return switch (f) {
            .unicode => "Unicode (512-byte pages)",
            .unicode_4k => "Unicode 4K pages (Outlook 2013+)",
        };
    }

    pub fn pageSize(f: Format) usize {
        return switch (f) {
            .unicode => 512,
            .unicode_4k => 4096,
        };
    }
    /// Bytes at the start of a B-tree page that hold entries.
    fn pageEntriesLen(f: Format) usize {
        return switch (f) {
            .unicode => 488,
            .unicode_4k => 4056,
        };
    }
    /// Offset of the PAGETRAILER (ptype, ptypeRepeat, wSig, dwCRC, bid); the CRC covers the bytes before it.
    fn pageTrailer(f: Format) usize {
        return switch (f) {
            .unicode => 496,
            .unicode_4k => 4072,
        };
    }
    /// BLOCKTRAILER size: cb(2) wSig(2) dwCRC(4) bid(8) [+ 4K: unknown(2) cbInflated(2) pad(4)].
    fn blockTrailerLen(f: Format) usize {
        return switch (f) {
            .unicode => 16,
            .unicode_4k => 24,
        };
    }
    /// Blocks are stored padded to this many bytes, trailer included.
    fn blockAlign(f: Format) usize {
        return switch (f) {
            .unicode => 64,
            .unicode_4k => 512,
        };
    }
};

/// B-tree page metadata (from the bytes after the entries).
pub const PageMeta = struct { c_ent: usize, cb_ent: usize, level: u8 };

fn permuteDecode(buf: []u8) void {
    for (buf) |*c| c.* = crypt_permute_decode[c.*];
}

/// Decompress a zlib stream that must expand to exactly `len` bytes (4K OST blocks).
fn inflate(a: Allocator, src: []const u8, len: usize) ![]u8 {
    const out = try a.alloc(u8, len);
    var in: Io.Reader = .fixed(src);
    var w: Io.Writer = .fixed(out);
    var d: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    const n = d.reader.streamRemaining(&w) catch return error.Corrupt;
    if (n != len) return error.Corrupt;
    return out;
}

/// PST checksum: CRC-32 (reflected 0xEDB88320 table) with initial value 0 and no final XOR ([MS-PST] 5.3).
pub const PstCrc = std.hash.crc.Crc(u32, .{
    .polynomial = 0x04c11db7,
    .initial = 0x00000000,
    .reflect_input = true,
    .reflect_output = true,
    .xor_output = 0x00000000,
});

/// One integrity problem found while reading. Reading continues (tolerant mode).
pub const Issue = struct {
    kind: Kind,
    id: u64, // page offset, BID or NID depending on kind
    detail: u64 = 0,

    pub const Kind = enum {
        page_bad_type,
        page_crc_mismatch,
        page_bid_mismatch,
        block_crc_mismatch,
        block_bid_mismatch,
        block_missing,
        block_unreadable,
        block_inflate_failed,
        node_unreadable,
        table_unreadable,
        rebuilt_from_index,

        pub fn text(k: Kind) []const u8 {
            return switch (k) {
                .page_bad_type => "B-tree page has an invalid type - subtree skipped",
                .page_crc_mismatch => "B-tree page checksum mismatch",
                .page_bid_mismatch => "B-tree page trailer BID mismatch",
                .block_crc_mismatch => "data block checksum mismatch",
                .block_bid_mismatch => "data block trailer BID mismatch",
                .block_missing => "data block referenced but not in block index",
                .block_unreadable => "data block could not be read",
                .block_inflate_failed => "compressed data block could not be decompressed",
                .node_unreadable => "node could not be parsed",
                .table_unreadable => "folder table unreadable",
                .rebuilt_from_index => "folder contents rebuilt from node index (table was damaged)",
            };
        }
    };
};

pub const NID_TYPE = struct {
    pub const normal_folder: u32 = 0x02;
    pub const search_folder: u32 = 0x03;
    pub const normal_message: u32 = 0x04;
    pub const attachment: u32 = 0x05;
    pub const assoc_message: u32 = 0x08;
    pub const hierarchy_table: u32 = 0x0D;
    pub const contents_table: u32 = 0x0E;
    pub const assoc_contents_table: u32 = 0x0F;
};

pub const NbtEntry = struct { nid: u32, bid_data: u64, bid_sub: u64, nid_parent: u32 };
/// `cb` is the stored size; `cb_inflated` differs from it only for compressed 4K-OST blocks.
pub const BbtEntry = struct { bid: u64, ib: u64, cb: u16, cb_inflated: u16 };
pub const SubEntry = struct { bid_data: u64, bid_sub: u64 };
pub const SubMap = std.AutoHashMapUnmanaged(u32, SubEntry);

// ================================================================ NDB layer

pub const Pst = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    file_size: u64,
    format: Format,
    /// "SM" for a PST, "SO" for an OST (header dwMagicClient).
    is_ost: bool,
    crypt: u8,
    nbt_ib: u64,
    bbt_ib: u64,
    page_cache: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    /// Integrity problems found so far (tolerant mode logs and carries on).
    issues: std.ArrayList(Issue) = .empty,
    issue_keys: std.AutoHashMapUnmanaged(u128, void) = .empty,
    /// Verify page/block checksums while reading.
    verify: bool = true,
    all_nodes: ?[]NbtEntry = null,
    /// Named-property map (NID 0x61), loaded on first use.
    names: ?namemap.NameMap = null,
    names_arena: ?std.heap.ArenaAllocator = null,
    /// Nodes and blocks recovered from stale index pages (see recover.zig); consulted when the
    /// live index has no entry, so recovered items load like any other.
    recovered_nodes: std.AutoHashMapUnmanaged(u32, NbtEntry) = .empty,
    recovered_blocks: std.AutoHashMapUnmanaged(u64, BbtEntry) = .empty,

    pub fn nameMap(self: *Pst) namemap.NameMap {
        if (self.names) |n| return n;
        self.names_arena = std.heap.ArenaAllocator.init(self.gpa);
        self.names = namemap.NameMap.load((&self.names_arena.?).allocator(), self);
        return self.names.?;
    }

    pub fn note(self: *Pst, kind: Issue.Kind, id: u64, detail: u64) void {
        const key = (@as(u128, @intFromEnum(kind)) << 64) | id;
        if (self.issue_keys.contains(key)) return;
        if (self.issues.items.len >= 10_000) return;
        self.issue_keys.put(self.gpa, key, {}) catch return;
        self.issues.append(self.gpa, .{ .kind = kind, .id = id, .detail = detail }) catch {};
    }

    /// Open a PST or OST read-only. `path` may be absolute or relative to the cwd.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !*Pst {
        const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        errdefer file.close(io);

        var hdr: [564]u8 = undefined;
        const n = try file.readPositionalAll(io, &hdr, 0);
        if (n < hdr.len) return error.NotPst;
        if (!std.mem.eql(u8, hdr[0..4], "!BDN")) return error.NotPst;
        const wver = rd16(&hdr, 10);
        // 14/15 = ANSI, 23 = Unicode (512-byte pages), 36 = Unicode 4K pages (Outlook 2013+ OST)
        const format: Format = switch (wver) {
            23 => .unicode,
            36 => .unicode_4k,
            else => return error.UnsupportedFormat,
        };
        const crypt = hdr[513];
        if (crypt > 1) return error.UnsupportedFormat; // high (cyclic) encryption not yet supported

        const self = try gpa.create(Pst);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .file = file,
            .file_size = try file.length(io),
            .format = format,
            .is_ost = std.mem.eql(u8, hdr[8..10], "SO"),
            .crypt = crypt,
            .nbt_ib = rd64(&hdr, 224),
            .bbt_ib = rd64(&hdr, 240),
        };
        return self;
    }

    /// One-line description of the file type, e.g. "OST, Unicode 4K pages (Outlook 2013+), not encrypted".
    pub fn describe(self: *const Pst, buf: []u8) []const u8 {
        const enc = switch (self.crypt) {
            0 => "not encrypted",
            1 => "compressible encryption",
            else => "high encryption",
        };
        return std.fmt.bufPrint(buf, "{s}, {s}, {s}", .{ if (self.is_ost) "OST" else "PST", self.format.label(), enc }) catch "";
    }

    /// Human-readable reason for an `open` failure.
    pub fn openErrorText(e: anyerror) []const u8 {
        return switch (e) {
            error.NotPst => "Not an Outlook PST/OST file (no !BDN signature).",
            error.UnsupportedFormat => "Unsupported Outlook data file: ANSI (Outlook 97-2002) files and \"high\" encryption are not supported yet.",
            error.FileNotFound => "File not found.",
            error.AccessDenied => "Access denied. If Outlook has the file open, close Outlook or work on a copy.",
            error.FileBusy, error.SharingViolation => "The file is locked by another program (Outlook?). Close it or work on a copy.",
            else => @errorName(e),
        };
    }

    pub fn close(self: *Pst) void {
        var it = self.page_cache.valueIterator();
        while (it.next()) |p| self.gpa.free(p.*);
        self.page_cache.deinit(self.gpa);
        self.issues.deinit(self.gpa);
        self.issue_keys.deinit(self.gpa);
        if (self.all_nodes) |n| self.gpa.free(n);
        if (self.names_arena) |*ar| ar.deinit();
        self.recovered_nodes.deinit(self.gpa);
        self.recovered_blocks.deinit(self.gpa);
        self.file.close(self.io);
        self.gpa.destroy(self);
    }

    /// Raw bytes at `off` (fewer at the end of the file); used by whole-file scans.
    pub fn readRaw(self: *Pst, buf: []u8, off: u64) !usize {
        if (off >= self.file_size) return 0;
        const len: usize = @intCast(@min(buf.len, self.file_size - off));
        return self.file.readPositionalAll(self.io, buf[0..len], off);
    }

    /// Page type (0x80 block tree, 0x81 node tree) if `p` is a well-formed B-tree page with a
    /// correct checksum, else null. Does not log: used to probe arbitrary file positions.
    pub fn pageType(self: *Pst, p: []const u8) ?u8 {
        const t = self.format.pageTrailer();
        if (p.len < self.format.pageSize()) return null;
        const ptype = p[t];
        if ((ptype != 0x80 and ptype != 0x81) or p[t + 1] != ptype) return null;
        if (PstCrc.hash(p[0..t]) != rd32(p, t + 4)) return null;
        _ = self.pageMeta(p) catch return null;
        return ptype;
    }

    /// Is the block described by `e` still on disk with its own id and a correct checksum?
    pub fn blockIntact(self: *Pst, a: Allocator, e: BbtEntry) bool {
        const tl = self.format.blockTrailerLen();
        const al = self.format.blockAlign();
        const aligned: usize = (@as(usize, e.cb) + tl + al - 1) & ~(al - 1);
        const full = a.alloc(u8, aligned) catch return false;
        self.readAt(full, e.ib) catch return false;
        const t = full[aligned - tl ..];
        if (rd16(t, 0) != e.cb) return false;
        if ((rd64(t, 8) & ~@as(u64, 1)) != (e.bid & ~@as(u64, 1))) return false;
        return PstCrc.hash(full[0..e.cb]) == rd32(t, 4);
    }

    /// Block ids referenced by an internal block (XBLOCK / XXBLOCK entries, SLBLOCK data and
    /// sub-node blocks, SIBLOCK child blocks).
    pub fn childBlocks(self: *Pst, a: Allocator, bid: u64) ![]u64 {
        const b = try self.readBlock(a, bid);
        try need(b, 0, 8);
        const c_ent: usize = rd16(b, 2);
        var out: std.ArrayList(u64) = .empty;
        switch (b[0]) {
            0x01 => {
                try need(b, 8, c_ent * 8);
                for (0..c_ent) |i| try out.append(a, rd64(b, 8 + i * 8));
            },
            0x02 => if (b[1] == 0) {
                try need(b, 8, c_ent * 24);
                for (0..c_ent) |i| {
                    try out.append(a, rd64(b, 8 + i * 24 + 8));
                    const sub = rd64(b, 8 + i * 24 + 16);
                    if (sub != 0) try out.append(a, sub);
                }
            } else {
                try need(b, 8, c_ent * 16);
                for (0..c_ent) |i| try out.append(a, rd64(b, 8 + i * 16 + 8));
            },
            else => return error.Corrupt,
        }
        return out.items;
    }

    fn readAt(self: *Pst, buf: []u8, off: u64) !void {
        if (off + buf.len > self.file_size) return error.Corrupt;
        const n = try self.file.readPositionalAll(self.io, buf, off);
        if (n != buf.len) return error.Corrupt;
    }

    /// One B-tree page (512 or 4096 bytes depending on the format), cached for the life of the Pst.
    pub fn page(self: *Pst, ib: u64) ![]const u8 {
        if (self.page_cache.get(ib)) |p| return p;
        const p = try self.gpa.alloc(u8, self.format.pageSize());
        errdefer self.gpa.free(p);
        try self.readAt(p, ib);
        // PAGETRAILER: ptype(1) ptypeRepeat(1) wSig(2) dwCRC(4) bid(8)
        const t = self.format.pageTrailer();
        const ptype = p[t];
        if ((ptype != 0x80 and ptype != 0x81) or p[t + 1] != ptype) {
            self.note(.page_bad_type, ib, ptype);
            return error.Corrupt;
        }
        if (self.verify) {
            const crc = PstCrc.hash(p[0..t]);
            if (crc != rd32(p, t + 4)) self.note(.page_crc_mismatch, ib, crc);
        }
        try self.page_cache.put(self.gpa, ib, p);
        return p;
    }

    /// Entry count, entry size and level of a B-tree page; error.Corrupt if they do not fit the page.
    pub fn pageMeta(self: *Pst, p: []const u8) Error!PageMeta {
        const e = self.format.pageEntriesLen();
        const m: PageMeta = switch (self.format) {
            // cEnt(1) cEntMax(1) cbEnt(1) cLevel(1)
            .unicode => .{ .c_ent = p[e], .cb_ent = p[e + 2], .level = p[e + 3] },
            // cEnt(2) cEntMax(2) cbEnt(1) cLevel(1)
            .unicode_4k => .{ .c_ent = rd16(p, e), .cb_ent = p[e + 4], .level = p[e + 5] },
        };
        if (m.cb_ent < 8 or m.c_ent * m.cb_ent > e) return error.Corrupt;
        return m;
    }

    /// Every node in the node B-tree (NBT), cached. Corrupt subtrees are skipped and logged.
    pub fn allNodes(self: *Pst) ![]const NbtEntry {
        if (self.all_nodes) |n| return n;
        var list: std.ArrayList(NbtEntry) = .empty;
        errdefer list.deinit(self.gpa);
        try self.walkNbt(self.nbt_ib, &list, 0);
        self.all_nodes = try list.toOwnedSlice(self.gpa);
        return self.all_nodes.?;
    }

    fn walkNbt(self: *Pst, ib: u64, list: *std.ArrayList(NbtEntry), depth: u8) !void {
        if (depth > 32) return;
        const p = self.page(ib) catch return; // logged by page()
        const m = self.pageMeta(p) catch {
            self.note(.page_bad_type, ib, 0);
            return;
        };
        for (0..m.c_ent) |i| {
            const o = i * m.cb_ent;
            if (m.level > 0) {
                try self.walkNbt(rd64(p, o + 16), list, depth + 1);
            } else if (m.cb_ent >= 28) {
                try list.append(self.gpa, .{ .nid = @truncate(rd64(p, o)), .bid_data = rd64(p, o + 8), .bid_sub = rd64(p, o + 16), .nid_parent = rd32(p, o + 24) });
            }
        }
    }

    pub fn nodesWithParent(self: *Pst, a: Allocator, parent: u32, nid_type: u32) ![]u32 {
        const nodes = try self.allNodes();
        var out: std.ArrayList(u32) = .empty;
        for (nodes) |n| {
            if ((n.nid & 0x1F) == nid_type and n.nid_parent == parent and n.nid != parent) try out.append(a, n.nid);
        }
        return out.toOwnedSlice(a);
    }

    /// Descend a NBT/BBT and return the matching leaf entry bytes (valid for the life of the Pst).
    fn btreeFind(self: *Pst, root_ib: u64, key: u64, is_bbt: bool) !?[]const u8 {
        const k = if (is_bbt) key & ~@as(u64, 1) else key;
        var ib = root_ib;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const p = try self.page(ib);
            const m = try self.pageMeta(p);
            if (m.level > 0) {
                var chosen: ?usize = null;
                for (0..m.c_ent) |i| {
                    const ek = rd64(p, i * m.cb_ent);
                    if (ek <= k) chosen = i else break;
                }
                const i = chosen orelse return null;
                ib = rd64(p, i * m.cb_ent + 16);
            } else {
                for (0..m.c_ent) |i| {
                    var ek = rd64(p, i * m.cb_ent);
                    if (is_bbt) ek &= ~@as(u64, 1);
                    if (ek == k) return p[i * m.cb_ent ..][0..m.cb_ent];
                }
                return null;
            }
        }
        return error.Corrupt;
    }

    pub fn lookupNode(self: *Pst, nid: u32) !?NbtEntry {
        const e = (try self.btreeFind(self.nbt_ib, nid, false)) orelse return self.recovered_nodes.get(nid);
        return .{ .nid = @truncate(rd64(e, 0)), .bid_data = rd64(e, 8), .bid_sub = rd64(e, 16), .nid_parent = rd32(e, 24) };
    }

    pub fn lookupBlock(self: *Pst, bid: u64) !?BbtEntry {
        const e = (try self.btreeFind(self.bbt_ib, bid, true)) orelse return self.recovered_blocks.get(bid & ~@as(u64, 1));
        // BBTENTRY: bref(bid, ib) cb(2) then cRef(2) for wVer 23, cbInflated(2) cRef(4) for 4K
        const cb = rd16(e, 16);
        const cb_inflated = if (self.format == .unicode_4k and e.len >= 20) rd16(e, 18) else cb;
        return .{ .bid = rd64(e, 0), .ib = rd64(e, 8), .cb = cb, .cb_inflated = cb_inflated };
    }

    /// Read one block: decompressed if stored compressed (4K OST), decrypted if it is an external/data block.
    fn readBlock(self: *Pst, a: Allocator, bid: u64) ![]u8 {
        const e = (try self.lookupBlock(bid)) orelse {
            self.note(.block_missing, bid, 0);
            return error.NotFound;
        };
        // Blocks are stored padded (64 or 512 bytes) with a BLOCKTRAILER at the end:
        // cb(2) wSig(2) dwCRC(4) bid(8) [...]. Read it to verify integrity.
        const tl = self.format.blockTrailerLen();
        const al = self.format.blockAlign();
        const aligned: usize = (@as(usize, e.cb) + tl + al - 1) & ~(al - 1);
        const full = try a.alloc(u8, aligned);
        self.readAt(full, e.ib) catch |err| {
            self.note(.block_unreadable, bid, e.ib);
            return err;
        };
        var buf = full[0..e.cb];
        if (self.verify) {
            const t = full[aligned - tl ..];
            if ((rd64(t, 8) & ~@as(u64, 1)) != (bid & ~@as(u64, 1))) self.note(.block_bid_mismatch, bid, e.ib);
            if (PstCrc.hash(buf) != rd32(t, 4)) self.note(.block_crc_mismatch, bid, e.ib);
        }
        const decrypt = (bid & 2) == 0 and self.crypt == 1;
        if (e.cb_inflated != e.cb) {
            // 4K OST: payload is a zlib stream. Undo encryption first if the stream header is not visible
            // (the order is undocumented; every OST seen so far is unencrypted).
            var decrypted = false;
            if (decrypt and !(buf.len >= 2 and buf[0] == 0x78)) {
                permuteDecode(buf);
                decrypted = true;
            }
            buf = inflate(a, buf, e.cb_inflated) catch |err| {
                self.note(.block_inflate_failed, bid, e.ib);
                return err;
            };
            if (decrypt and !decrypted) permuteDecode(buf);
        } else if (decrypt) permuteDecode(buf);
        return buf;
    }

    /// Return the list of data blocks for a data tree (follows XBLOCK / XXBLOCK).
    pub fn readDataBlocks(self: *Pst, a: Allocator, bid: u64) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        if (bid == 0) return list.toOwnedSlice(a);
        try self.collectBlocks(a, bid, &list, 0);
        return list.toOwnedSlice(a);
    }

    fn collectBlocks(self: *Pst, a: Allocator, bid: u64, list: *std.ArrayList([]u8), depth: u8) anyerror!void {
        if (depth > 3) return error.Corrupt;
        const b = try self.readBlock(a, bid);
        if ((bid & 2) == 0) {
            try list.append(a, b);
            return;
        }
        try need(b, 0, 8);
        if (b[0] != 0x01) return error.Corrupt; // XBLOCK/XXBLOCK
        const c_ent: usize = rd16(b, 2);
        try need(b, 8, c_ent * 8);
        for (0..c_ent) |i| {
            const child = rd64(b, 8 + i * 8);
            try self.collectBlocks(a, child, list, depth + 1);
        }
    }

    /// Concatenate a data tree into one buffer.
    pub fn readData(self: *Pst, a: Allocator, bid: u64) ![]u8 {
        const blocks = try self.readDataBlocks(a, bid);
        if (blocks.len == 1) return blocks[0];
        var total: usize = 0;
        for (blocks) |b| total += b.len;
        const out = try a.alloc(u8, total);
        var o: usize = 0;
        for (blocks) |b| {
            @memcpy(out[o..][0..b.len], b);
            o += b.len;
        }
        return out;
    }

    /// Load the sub-node B-tree (SLBLOCK/SIBLOCK) rooted at `bid_sub`.
    pub fn readSubnodes(self: *Pst, a: Allocator, bid_sub: u64, map: *SubMap) anyerror!void {
        if (bid_sub == 0) return;
        const b = try self.readBlock(a, bid_sub);
        try need(b, 0, 8);
        if (b[0] != 0x02) return error.Corrupt;
        const level = b[1];
        const c_ent: usize = rd16(b, 2);
        if (level == 0) {
            try need(b, 8, c_ent * 24);
            for (0..c_ent) |i| {
                const o = 8 + i * 24;
                const nid: u32 = @truncate(rd64(b, o));
                try map.put(a, nid, .{ .bid_data = rd64(b, o + 8), .bid_sub = rd64(b, o + 16) });
            }
        } else {
            try need(b, 8, c_ent * 16);
            for (0..c_ent) |i| try self.readSubnodes(a, rd64(b, 8 + i * 16 + 8), map);
        }
    }

    pub fn node(self: *Pst, nid: u32) !Node {
        const e = (try self.lookupNode(nid)) orelse return error.NotFound;
        return .{ .pst = self, .nid = nid, .bid_data = e.bid_data, .bid_sub = e.bid_sub };
    }
};

/// A node (top-level NBT node or a sub-node) with lazily-loaded sub-nodes.
pub const Node = struct {
    pst: *Pst,
    nid: u32,
    bid_data: u64,
    bid_sub: u64,
    subs: ?SubMap = null,

    pub fn subMap(self: *Node, a: Allocator) !*SubMap {
        if (self.subs == null) {
            var m: SubMap = .empty;
            try self.pst.readSubnodes(a, self.bid_sub, &m);
            self.subs = m;
        }
        return &self.subs.?;
    }

    pub fn subNode(self: *Node, a: Allocator, nid: u32) !?Node {
        const m = try self.subMap(a);
        const e = m.get(nid) orelse return null;
        return .{ .pst = self.pst, .nid = nid, .bid_data = e.bid_data, .bid_sub = e.bid_sub };
    }

    pub fn subData(self: *Node, a: Allocator, nid: u32) ![]u8 {
        const m = try self.subMap(a);
        const e = m.get(nid) orelse return error.NotFound;
        return self.pst.readData(a, e.bid_data);
    }
};

// ================================================================ LTP layer

pub const Heap = struct {
    blocks: [][]u8,
    client_sig: u8,
    user_root: u32,
    format: Format,

    pub fn init(blocks: [][]u8, format: Format) !Heap {
        if (blocks.len == 0) return error.Corrupt;
        const b0 = blocks[0];
        try need(b0, 0, 12);
        if (b0[2] != 0xEC) return error.Corrupt;
        return .{ .blocks = blocks, .client_sig = b0[3], .user_root = rd32(b0, 4), .format = format };
    }

    pub fn get(self: Heap, hid: u32) ![]const u8 {
        if (hid == 0) return &.{};
        if ((hid & 0x1F) != 0) return error.Corrupt;
        // HID: hidType(5) hidIndex(11) hidBlockIndex(16); 4K OSTs use hidIndex(14) hidBlockIndex(13)
        const idx: usize, const bi: usize = switch (self.format) {
            .unicode => .{ (hid >> 5) & 0x7FF, hid >> 16 },
            .unicode_4k => .{ (hid >> 5) & 0x3FFF, hid >> 19 },
        };
        if (bi >= self.blocks.len or idx == 0) return error.Corrupt;
        const b = self.blocks[bi];
        try need(b, 0, 2);
        const hnpm: usize = rd16(b, 0);
        try need(b, hnpm, 4);
        const c_alloc: usize = rd16(b, hnpm);
        if (idx > c_alloc) return error.Corrupt;
        try need(b, hnpm + 4, (c_alloc + 1) * 2);
        const start: usize = rd16(b, hnpm + 4 + (idx - 1) * 2);
        const end: usize = rd16(b, hnpm + 4 + idx * 2);
        if (end < start or end > b.len) return error.Corrupt;
        return b[start..end];
    }
};

/// Collect all leaf records of a BTH.
fn bthRecords(a: Allocator, heap: Heap, hid_hdr: u32, key_size: *u8, data_size: *u8) ![][]const u8 {
    const h = try heap.get(hid_hdr);
    try need(h, 0, 8);
    if (h[0] != 0xB5) return error.Corrupt;
    key_size.* = h[1];
    data_size.* = h[2];
    var out: std.ArrayList([]const u8) = .empty;
    const root = rd32(h, 4);
    if (root != 0) try bthCollect(a, heap, root, h[3], h[1], h[2], &out);
    return out.toOwnedSlice(a);
}

fn bthCollect(a: Allocator, heap: Heap, hid: u32, level: u8, cb_key: u8, cb_ent: u8, out: *std.ArrayList([]const u8)) anyerror!void {
    const d = try heap.get(hid);
    if (level > 0) {
        const rs: usize = @as(usize, cb_key) + 4;
        var o: usize = 0;
        while (o + rs <= d.len) : (o += rs) try bthCollect(a, heap, rd32(d, o + cb_key), level - 1, cb_key, cb_ent, out);
    } else {
        const rs: usize = @as(usize, cb_key) + cb_ent;
        if (rs == 0) return error.Corrupt;
        var o: usize = 0;
        while (o + rs <= d.len) : (o += rs) try out.append(a, d[o..][0..rs]);
    }
}

pub fn fixedSize(ptype: u16) ?usize {
    return switch (ptype) {
        PT.int16 => 2,
        PT.int32, PT.float32, PT.err => 4,
        PT.boolean => 1,
        PT.float64, PT.currency, PT.apptime, PT.int64, PT.systime => 8,
        else => null,
    };
}

pub const Prop = struct {
    id: u16,
    ptype: u16,
    data: []const u8,
    /// Raw HNID / sub-node NID for heap or sub-node values (0 for inline values).
    hnid: u32 = 0,
};

/// Property context: all properties of a message, folder, attachment, etc.
pub const PropContext = struct {
    props: []Prop,

    pub fn load(a: Allocator, node: *Node) !PropContext {
        const blocks = try node.pst.readDataBlocks(a, node.bid_data);
        const heap = try Heap.init(blocks, node.pst.format);
        if (heap.client_sig != 0xBC) return error.Corrupt;
        var ks: u8 = 0;
        var ds: u8 = 0;
        const recs = try bthRecords(a, heap, heap.user_root, &ks, &ds);
        if (ks != 2 or ds != 6) return error.Corrupt;
        var props: std.ArrayList(Prop) = .empty;
        for (recs) |r| {
            const id = rd16(r, 0);
            const ptype = rd16(r, 2);
            const hnid = rd32(r, 4);
            const data: []const u8 = blk: {
                if (fixedSize(ptype)) |sz| if (sz <= 4) break :blk r[4..][0..sz];
                if (hnid == 0) break :blk &.{};
                if ((hnid & 0x1F) == 0) break :blk heap.get(hnid) catch &.{};
                break :blk node.subData(a, hnid) catch &.{};
            };
            const inline_val = if (fixedSize(ptype)) |sz| sz <= 4 else false;
            try props.append(a, .{ .id = id, .ptype = ptype, .data = data, .hnid = if (inline_val) 0 else hnid });
        }
        return .{ .props = try props.toOwnedSlice(a) };
    }

    pub fn find(self: PropContext, id: u16) ?Prop {
        for (self.props) |p| if (p.id == id) return p;
        return null;
    }
    pub fn string(self: PropContext, a: Allocator, id: u16) ![]const u8 {
        const p = self.find(id) orelse return "";
        return propToString(a, p.ptype, p.data);
    }
    pub fn int(self: PropContext, id: u16) ?i64 {
        const p = self.find(id) orelse return null;
        return propToInt(p.ptype, p.data);
    }
    pub fn time(self: PropContext, id: u16) ?i64 {
        const p = self.find(id) orelse return null;
        if (p.ptype != PT.systime or p.data.len < 8) return null;
        return filetimeToUnix(rd64(p.data, 0));
    }
    pub fn bytes(self: PropContext, id: u16) ?[]const u8 {
        const p = self.find(id) orelse return null;
        return p.data;
    }
};

pub const ColDesc = struct { id: u16, ptype: u16, ib: u16, cb: u8, ibit: u8 };

/// Table context: folder hierarchy/contents tables, recipient & attachment tables.
pub const Table = struct {
    heap: Heap,
    node: *Node,
    cols: []ColDesc,
    rows: [][]const u8,
    ceb_off: u16,

    pub fn load(a: Allocator, node: *Node) !Table {
        const blocks = try node.pst.readDataBlocks(a, node.bid_data);
        const heap = try Heap.init(blocks, node.pst.format);
        if (heap.client_sig != 0x7C) return error.Corrupt;
        const info = try heap.get(heap.user_root);
        try need(info, 0, 22);
        if (info[0] != 0x7C) return error.Corrupt;
        const c_cols: usize = info[1];
        const ceb_off = rd16(info, 6);
        const row_size: usize = rd16(info, 8);
        const hnid_rows = rd32(info, 14);
        try need(info, 22, c_cols * 8);
        const cols = try a.alloc(ColDesc, c_cols);
        for (cols, 0..) |*c, i| {
            const o = 22 + i * 8;
            const tag = rd32(info, o);
            c.* = .{ .ptype = @truncate(tag), .id = @truncate(tag >> 16), .ib = rd16(info, o + 4), .cb = info[o + 6], .ibit = info[o + 7] };
        }
        var rows: std.ArrayList([]const u8) = .empty;
        if (hnid_rows != 0 and row_size > 0) {
            if ((hnid_rows & 0x1F) == 0) {
                const d = try heap.get(hnid_rows);
                var o: usize = 0;
                while (o + row_size <= d.len) : (o += row_size) try rows.append(a, d[o..][0..row_size]);
            } else {
                const sub = (try node.subNode(a, hnid_rows)) orelse return error.Corrupt;
                const rblocks = try node.pst.readDataBlocks(a, sub.bid_data);
                for (rblocks) |rb| {
                    var o: usize = 0;
                    while (o + row_size <= rb.len) : (o += row_size) try rows.append(a, rb[o..][0..row_size]);
                }
            }
        }
        return .{ .heap = heap, .node = node, .cols = cols, .rows = try rows.toOwnedSlice(a), .ceb_off = ceb_off };
    }

    pub fn colIndex(self: Table, id: u16) ?usize {
        for (self.cols, 0..) |c, i| if (c.id == id) return i;
        return null;
    }

    pub fn rowId(self: Table, r: usize) u32 {
        return rd32(self.rows[r], 0);
    }

    /// Raw cell value (variable-length values are resolved through the heap / sub-nodes).
    pub fn cell(self: Table, a: Allocator, r: usize, id: u16) ?Prop {
        const ci = self.colIndex(id) orelse return null;
        const c = self.cols[ci];
        const row = self.rows[r];
        const byte = self.ceb_off + c.ibit / 8;
        if (byte >= row.len) return null;
        if ((row[byte] & (@as(u8, 0x80) >> @intCast(c.ibit % 8))) == 0) return null;
        if (@as(usize, c.ib) + c.cb > row.len) return null;
        const raw = row[c.ib..][0..c.cb];
        if (fixedSize(c.ptype) != null) return .{ .id = c.id, .ptype = c.ptype, .data = raw };
        if (raw.len < 4) return null;
        const hnid = rd32(raw, 0);
        if (hnid == 0) return .{ .id = c.id, .ptype = c.ptype, .data = &.{} };
        const data: []const u8 = if ((hnid & 0x1F) == 0)
            self.heap.get(hnid) catch return null
        else
            self.node.subData(a, hnid) catch return null;
        return .{ .id = c.id, .ptype = c.ptype, .data = data };
    }

    pub fn string(self: Table, a: Allocator, r: usize, id: u16) []const u8 {
        const p = self.cell(a, r, id) orelse return "";
        return propToString(a, p.ptype, p.data) catch "";
    }
    pub fn int(self: Table, a: Allocator, r: usize, id: u16) ?i64 {
        const p = self.cell(a, r, id) orelse return null;
        return propToInt(p.ptype, p.data);
    }
    pub fn time(self: Table, a: Allocator, r: usize, id: u16) ?i64 {
        const p = self.cell(a, r, id) orelse return null;
        if (p.ptype != PT.systime or p.data.len < 8) return null;
        return filetimeToUnix(rd64(p.data, 0));
    }
};

// ================================================================ value conversion

pub fn filetimeToUnix(ft: u64) ?i64 {
    if (ft == 0 or ft == 0x7FFFFFFFFFFFFFFF) return null;
    return @as(i64, @intCast(ft / 10_000_000)) - 11_644_473_600;
}

pub fn propToInt(ptype: u16, d: []const u8) ?i64 {
    return switch (ptype) {
        PT.int16 => if (d.len >= 2) @as(i64, @as(i16, @bitCast(rd16(d, 0)))) else null,
        PT.int32, PT.err => if (d.len >= 4) @as(i64, @as(i32, @bitCast(rd32(d, 0)))) else null,
        PT.boolean => if (d.len >= 1) @as(i64, @intFromBool(d[0] != 0)) else null,
        PT.int64, PT.currency => if (d.len >= 8) @as(i64, @bitCast(rd64(d, 0))) else null,
        else => null,
    };
}

/// UTF-16LE (possibly unaligned, possibly with lone surrogates) -> UTF-8, lenient.
pub fn utf16ToUtf8(a: Allocator, d: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, d.len / 2 + 8);
    var i: usize = 0;
    while (i + 1 < d.len) : (i += 2) {
        var cp: u21 = rd16(d, i);
        if (cp == 0) {
            if (i + 2 >= d.len) break; // trailing terminator
            continue;
        }
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 3 < d.len) {
            const lo = rd16(d, i + 2);
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i += 2;
            } else cp = 0xFFFD;
        } else if (cp >= 0xD800 and cp <= 0xDFFF) cp = 0xFFFD;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

/// 8-bit string (treated as Windows-1252 / Latin-1) -> UTF-8.
pub fn latin1ToUtf8(a: Allocator, d: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (d) |c| {
        if (c == 0) break;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(mime.cp1252Char(c), &buf) catch 0;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

pub fn propToString(a: Allocator, ptype: u16, d: []const u8) ![]const u8 {
    return switch (ptype) {
        PT.unicode => utf16ToUtf8(a, d),
        PT.string8 => latin1ToUtf8(a, d),
        PT.binary => d, // e.g. HTML body stored as binary
        else => "",
    };
}

/// PST subjects may start with 0x01 + prefix-length; strip that marker.
pub fn cleanSubject(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == 0x01) return s[2..];
    return s;
}

// ================================================================ messaging layer

pub const FolderInfo = struct {
    nid: u32,
    name: []const u8,
    count: i64,
    unread: i64,
    has_subfolders: bool,
    container_class: []const u8,
};

pub const MessageSummary = struct {
    nid: u32,
    subject: []const u8,
    from: []const u8,
    to: []const u8,
    cc: []const u8,
    message_class: []const u8,
    delivery_time: ?i64,
    submit_time: ?i64,
    modified_time: ?i64,
    size: ?i64,
    flags: ?i64,
    /// Non-empty for hidden/recovered items, e.g. "orphaned (parent Inbox)".
    note: []const u8 = "",
};

/// NID of the top of the user's folders (IPM subtree) from the message store's
/// PR_IPM_SUBTREE_ENTRYID: "Top of Outlook data file" in a PST, "Root - Mailbox/IPM_SUBTREE" in an OST.
/// OSTs carry no PST-style entry id there, so the folder is also found by its well-known name.
pub fn ipmSubtree(a: Allocator, pst: *Pst) ?u32 {
    entry_id: {
        var n = pst.node(NID.message_store) catch break :entry_id;
        const pc = PropContext.load(a, &n) catch break :entry_id;
        const eid = pc.bytes(0x35E0) orelse break :entry_id;
        if (eid.len != 24) break :entry_id;
        // PST entry id: flags(4) provider uid(16) nid(4)
        const nid = rd32(eid, 20);
        if ((nid & 0x1F) == NID_TYPE.normal_folder and (pst.lookupNode(nid) catch null) != null) return nid;
    }
    const top = subFolders(a, pst, NID.root_folder) catch return null;
    for (top) |k| {
        const name = (folderInfo(a, pst, k) catch continue).name;
        if (std.mem.startsWith(u8, name, "Top of") or std.mem.eql(u8, name, "IPM_SUBTREE")) return k;
        if (std.mem.eql(u8, name, "Root - Mailbox")) {
            const inner = subFolders(a, pst, k) catch continue;
            for (inner) |c| {
                const cn = (folderInfo(a, pst, c) catch continue).name;
                if (std.mem.eql(u8, cn, "IPM_SUBTREE") or std.mem.startsWith(u8, cn, "Top of")) return c;
            }
        }
    }
    return null;
}

pub fn folderInfo(a: Allocator, pst: *Pst, nid: u32) !FolderInfo {
    var n = try pst.node(nid);
    const pc = try PropContext.load(a, &n);
    return .{
        .nid = nid,
        .name = try pc.string(a, Tag.display_name),
        .count = pc.int(Tag.content_count) orelse 0,
        .unread = pc.int(Tag.content_unread) orelse 0,
        .has_subfolders = (pc.int(Tag.subfolders) orelse 0) != 0,
        .container_class = try pc.string(a, Tag.container_class),
    };
}

/// NIDs of the direct sub-folders of a folder. If the hierarchy table is damaged,
/// sub-folders are rebuilt from the node index (parent pointers) and the issue is logged.
pub fn subFolders(a: Allocator, pst: *Pst, folder_nid: u32) ![]u32 {
    const tnid = (folder_nid & ~@as(u32, 0x1F)) | nid_type_hierarchy_table;
    const from_table: ?[]u32 = blk: {
        var n = pst.node(tnid) catch |e| switch (e) {
            error.NotFound => break :blk @as([]u32, &.{}),
            else => break :blk null,
        };
        const t = Table.load(a, &n) catch break :blk null;
        const out = try a.alloc(u32, t.rows.len);
        for (out, 0..) |*o, r| o.* = t.rowId(r);
        break :blk out;
    };
    if (from_table) |ft| return ft;
    pst.note(.table_unreadable, tnid, folder_nid);
    pst.note(.rebuilt_from_index, folder_nid, 0);
    return pst.nodesWithParent(a, folder_nid, NID_TYPE.normal_folder);
}

/// Message list of a folder from its contents table (fast; no per-message load for PSTs).
/// If the contents table is damaged, items are rebuilt from the node index (tolerant mode).
///
/// OST contents tables are a local cache kept by Outlook and are not fully reliable: in real
/// OSTs the sender-name cells point at unrelated heap items, and many rows (e.g. most Sent Items)
/// lack columns altogether. For OSTs the sender always comes from the message itself.
pub fn folderMessages(a: Allocator, pst: *Pst, folder_nid: u32) ![]MessageSummary {
    const tnid = (folder_nid & ~@as(u32, 0x1F)) | nid_type_contents_table;
    var n = pst.node(tnid) catch |e| switch (e) {
        error.NotFound => return &.{},
        else => return rebuildFolderMessages(a, pst, folder_nid, tnid),
    };
    const t = Table.load(a, &n) catch return rebuildFolderMessages(a, pst, folder_nid, tnid);
    const out = try a.alloc(MessageSummary, t.rows.len);
    for (out, 0..) |*m, r| {
        var from: []const u8 = "";
        if (!pst.is_ost) {
            from = t.string(a, r, Tag.sent_repr_name);
            if (from.len == 0) from = t.string(a, r, Tag.sender_name);
        }
        m.* = .{
            .nid = t.rowId(r),
            .subject = cleanSubject(t.string(a, r, Tag.subject)),
            .from = from,
            .to = t.string(a, r, Tag.display_to),
            .cc = t.string(a, r, Tag.display_cc),
            .message_class = t.string(a, r, Tag.message_class),
            .delivery_time = t.time(a, r, Tag.delivery_time),
            .submit_time = t.time(a, r, Tag.client_submit_time),
            .modified_time = t.time(a, r, Tag.last_modified),
            .size = t.int(a, r, Tag.message_size),
            .flags = t.int(a, r, Tag.message_flags),
        };
        // Row without sender cells (or any OST row): fill the gaps from the message's own properties.
        if (pst.is_ost or (from.len == 0 and t.cell(a, r, Tag.sent_repr_name) == null and t.cell(a, r, Tag.sender_name) == null))
            fillFromNode(a, pst, m);
    }
    return out;
}

/// Fill empty fields of a list entry from the message's own properties (silently keeps them on error).
fn fillFromNode(a: Allocator, pst: *Pst, m: *MessageSummary) void {
    var n = pst.node(m.nid) catch return;
    const pc = PropContext.load(a, &n) catch return;
    if (m.from.len == 0) m.from = pc.string(a, Tag.sent_repr_name) catch "";
    if (m.from.len == 0) m.from = pc.string(a, Tag.sender_name) catch "";
    if (m.subject.len == 0) m.subject = cleanSubject(pc.string(a, Tag.subject) catch "");
    if (m.to.len == 0) m.to = pc.string(a, Tag.display_to) catch "";
    if (m.cc.len == 0) m.cc = pc.string(a, Tag.display_cc) catch "";
    if (m.message_class.len == 0) m.message_class = pc.string(a, Tag.message_class) catch "";
    m.delivery_time = m.delivery_time orelse pc.time(Tag.delivery_time);
    m.submit_time = m.submit_time orelse pc.time(Tag.client_submit_time);
    m.modified_time = m.modified_time orelse pc.time(Tag.last_modified);
    m.size = m.size orelse pc.int(Tag.message_size);
    m.flags = m.flags orelse pc.int(Tag.message_flags);
}

fn rebuildFolderMessages(a: Allocator, pst: *Pst, folder_nid: u32, table_nid: u32) ![]MessageSummary {
    pst.note(.table_unreadable, table_nid, folder_nid);
    pst.note(.rebuilt_from_index, folder_nid, 0);
    const nids = try pst.nodesWithParent(a, folder_nid, NID_TYPE.normal_message);
    var out: std.ArrayList(MessageSummary) = .empty;
    for (nids) |nid| try out.append(a, summaryFromNode(a, pst, nid, "rebuilt from node index"));
    return out.toOwnedSlice(a);
}

/// Build a list entry from a message's own properties (used when no table row exists).
pub fn summaryFromNode(a: Allocator, pst: *Pst, nid: u32, note_text: []const u8) MessageSummary {
    var s: MessageSummary = .{
        .nid = nid,
        .subject = "",
        .from = "",
        .to = "",
        .cc = "",
        .message_class = "",
        .delivery_time = null,
        .submit_time = null,
        .modified_time = null,
        .size = null,
        .flags = null,
        .note = note_text,
    };
    var n = pst.node(nid) catch {
        s.subject = "(unreadable node)";
        pst.note(.node_unreadable, nid, 0);
        return s;
    };
    const pc = PropContext.load(a, &n) catch {
        s.subject = "(unreadable properties)";
        pst.note(.node_unreadable, nid, 0);
        return s;
    };
    s.subject = cleanSubject(pc.string(a, Tag.subject) catch "");
    s.from = pc.string(a, Tag.sent_repr_name) catch "";
    if (s.from.len == 0) s.from = pc.string(a, Tag.sender_name) catch "";
    s.to = pc.string(a, Tag.display_to) catch "";
    s.cc = pc.string(a, Tag.display_cc) catch "";
    s.message_class = pc.string(a, Tag.message_class) catch "";
    s.delivery_time = pc.time(Tag.delivery_time);
    s.submit_time = pc.time(Tag.client_submit_time);
    s.modified_time = pc.time(Tag.last_modified);
    s.size = pc.int(Tag.message_size);
    s.flags = pc.int(Tag.message_flags);
    return s;
}

pub const HiddenScan = struct {
    /// Messages present in the file but not listed in any folder's contents table.
    orphans: []MessageSummary,
    /// Folder-associated (FAI) items: rules, views, forms, etc. Hidden in Outlook.
    fai: []MessageSummary,
    /// Folders present in the file but not reachable from the folder tree.
    orphan_folders: []u32,
    total_nodes: usize,
    folders_reached: usize,
    listed_messages: usize,
};

/// Walk the whole node index and find everything the folder tables do not show.
pub fn hiddenScan(a: Allocator, pst: *Pst) !HiddenScan {
    const nodes = try pst.allNodes();
    var reached_folders: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var listed: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var folder_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    // folders whose contents table is damaged: their items are shown in the folder itself
    // (rebuilt from the node index), so they are not reported as orphans
    var damaged: std.AutoHashMapUnmanaged(u32, void) = .empty;

    // breadth-first walk of the visible folder tree
    var queue: std.ArrayList(u32) = .empty;
    try queue.append(a, NID.root_folder);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const f = queue.items[qi];
        if (reached_folders.contains(f)) continue;
        try reached_folders.put(a, f, {});
        if (folderInfo(a, pst, f)) |info| try folder_names.put(a, f, info.name) else |_| {}
        // listed items (normal + associated contents tables)
        inline for (.{ nid_type_contents_table, NID_TYPE.assoc_contents_table }) |tt| {
            const tnid = (f & ~@as(u32, 0x1F)) | tt;
            if (pst.node(tnid)) |nn| {
                var tn = nn;
                if (Table.load(a, &tn)) |t| {
                    for (0..t.rows.len) |r| try listed.put(a, t.rowId(r), {});
                } else |_| {
                    pst.note(.table_unreadable, tnid, f);
                    if (tt == nid_type_contents_table) try damaged.put(a, f, {});
                }
            } else |e| if (e != error.NotFound and tt == nid_type_contents_table) try damaged.put(a, f, {});
        }
        const kids = subFolders(a, pst, f) catch &.{};
        for (kids) |k| try queue.append(a, k);
    }

    var orphans: std.ArrayList(MessageSummary) = .empty;
    var fai: std.ArrayList(MessageSummary) = .empty;
    var orphan_folders: std.ArrayList(u32) = .empty;
    for (nodes) |n| {
        const t = n.nid & 0x1F;
        if (t == NID_TYPE.normal_message and !listed.contains(n.nid) and !damaged.contains(n.nid_parent)) {
            const pname = folder_names.get(n.nid_parent);
            const note_text = if (pname) |p|
                try std.fmt.allocPrint(a, "orphaned - parent folder \"{s}\" does not list it", .{p})
            else
                try std.fmt.allocPrint(a, "orphaned - parent folder 0x{x} missing", .{n.nid_parent});
            try orphans.append(a, summaryFromNode(a, pst, n.nid, note_text));
        } else if (t == NID_TYPE.assoc_message) {
            const pname = folder_names.get(n.nid_parent) orelse "?";
            const note_text = try std.fmt.allocPrint(a, "hidden associated (FAI) item of \"{s}\"", .{pname});
            try fai.append(a, summaryFromNode(a, pst, n.nid, note_text));
        } else if (t == NID_TYPE.normal_folder and !reached_folders.contains(n.nid)) {
            try orphan_folders.append(a, n.nid);
        }
    }
    return .{
        .orphans = try orphans.toOwnedSlice(a),
        .fai = try fai.toOwnedSlice(a),
        .orphan_folders = try orphan_folders.toOwnedSlice(a),
        .total_nodes = nodes.len,
        .folders_reached = reached_folders.count(),
        .listed_messages = listed.count(),
    };
}

pub const VerifyStats = struct { nodes: usize = 0, subnodes: usize = 0, blocks: usize = 0, bytes: u64 = 0 };

/// Read every block of every node and sub-node with checksum verification. Problems go to `pst.issues`.
pub fn verifyAll(pst: *Pst, progress: ?*const fn (done: usize, total: usize) void) !VerifyStats {
    const nodes = try pst.allNodes();
    var st: VerifyStats = .{ .nodes = nodes.len };
    for (nodes, 0..) |n, i| {
        var na = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer na.deinit();
        const ia = na.allocator();
        if (n.bid_data != 0) {
            if (pst.readDataBlocks(ia, n.bid_data)) |bl| {
                st.blocks += bl.len;
                for (bl) |b| st.bytes += b.len;
            } else |_| pst.note(.node_unreadable, n.nid, n.bid_data);
        }
        var subs: SubMap = .empty;
        pst.readSubnodes(ia, n.bid_sub, &subs) catch pst.note(.node_unreadable, n.nid, n.bid_sub);
        var it = subs.iterator();
        while (it.next()) |e| {
            st.subnodes += 1;
            if (pst.readDataBlocks(ia, e.value_ptr.bid_data)) |bl| {
                st.blocks += bl.len;
                for (bl) |b| st.bytes += b.len;
            } else |_| pst.note(.node_unreadable, n.nid, e.key_ptr.*);
        }
        if (progress) |p| if (i % 500 == 0) p(i, nodes.len);
    }
    return st;
}

/// Human-readable integrity log.
pub fn issuesText(a: Allocator, pst: *Pst) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Integrity log - {d} issue(s)\n\n", .{pst.issues.items.len});
    if (pst.issues.items.len == 0) try out.appendSlice(a, "No problems recorded so far. Use 'Verify every block' to check the whole file.\n");
    for (pst.issues.items) |is| try out.print(a, "{s}\n    id=0x{x}  detail=0x{x}\n", .{ is.kind.text(), is.id, is.detail });
    return out.toOwnedSlice(a);
}

pub const Recipient = struct {
    kind: i64, // 1=To 2=Cc 3=Bcc
    name: []const u8,
    email: []const u8,
    addrtype: []const u8,
    props: []Prop,
};

pub const Attachment = struct {
    sub_nid: u32,
    filename: []const u8,
    mime: []const u8,
    content_id: []const u8,
    method: i64,
    size: i64,
    pc: PropContext,
    /// PST sub-node holding the attachment (null for messages built from other sources).
    node: ?Node,
    /// Already-parsed embedded message (method 5) for messages built from other sources.
    embedded: ?*Message = null,

    /// Attachment bytes (method 1 = by value). Empty if not available.
    pub fn data(self: *const Attachment) []const u8 {
        const p = self.pc.find(Tag.attach_data) orelse return &.{};
        if (p.ptype == PT.binary) return p.data;
        return &.{};
    }
};

pub const Message = struct {
    nid: u32,
    /// PST node of the message (null for messages built from other sources, e.g. MBOX).
    node: ?Node,
    pc: PropContext,
    recipients: []Recipient,
    attachments: []Attachment,

    pub fn subject(self: *const Message, a: Allocator) ![]const u8 {
        return cleanSubject(try self.pc.string(a, Tag.subject));
    }
    pub fn senderName(self: *const Message, a: Allocator) ![]const u8 {
        const s = try self.pc.string(a, Tag.sent_repr_name);
        return if (s.len > 0) s else try self.pc.string(a, Tag.sender_name);
    }
    pub fn senderEmail(self: *const Message, a: Allocator) ![]const u8 {
        inline for (.{ Tag.sent_repr_smtp, Tag.sender_smtp, Tag.sent_repr_email, Tag.sender_email }) |t| {
            const s = try self.pc.string(a, t);
            if (s.len > 0 and std.mem.indexOfScalar(u8, s, '@') != null) return s;
        }
        return try self.pc.string(a, Tag.sender_email);
    }
    /// Plain-text body. Falls back to text recovered from the compressed RTF body when the message
    /// has neither a plain-text nor an HTML body (common in OSTs).
    pub fn bodyText(self: *const Message, a: Allocator) ![]const u8 {
        const t = try self.pc.string(a, Tag.body);
        if (t.len > 0 or self.hasHtml()) return t;
        const r = self.rtfBody(a) orelse return t;
        return if (r.kind == .text) r.data else "";
    }
    /// HTML body. Falls back to HTML de-encapsulated from the compressed RTF body (`\fromhtml1`).
    pub fn bodyHtml(self: *const Message, a: Allocator) ![]const u8 {
        const h = try self.pc.string(a, Tag.body_html);
        if (h.len > 0) return h;
        if (self.pc.bytes(Tag.body)) |b| if (b.len > 0) return h;
        const r = self.rtfBody(a) orelse return h;
        return if (r.kind == .html) r.data else "";
    }
    /// HTML body converted to UTF-8 for display. PR_HTML is stored as bytes in the message's
    /// code page (PR_INTERNET_CPID, typically Windows-1252); `bodyHtml` returns those bytes as stored.
    pub fn bodyHtmlUtf8(self: *const Message, a: Allocator) ![]const u8 {
        const h = try self.bodyHtml(a);
        if (std.unicode.utf8ValidateSlice(h)) return h;
        const cp = self.pc.int(Tag.internet_cpid) orelse 0;
        return mime.repairUtf8(a, mime.fromCodePage(a, std.math.cast(u32, cp) orelse 0, h));
    }
    fn hasHtml(self: *const Message) bool {
        const b = self.pc.bytes(Tag.body_html) orelse return false;
        return b.len > 0;
    }
    fn rtfBody(self: *const Message, a: Allocator) ?rtfcp.Body {
        const raw = self.pc.bytes(Tag.rtf_compressed) orelse return null;
        if (raw.len == 0) return null;
        return rtfcp.body(a, raw) catch null;
    }
};

pub fn loadMessage(a: Allocator, pst: *Pst, nid: u32) !Message {
    var n = try pst.node(nid);
    return loadMessageNode(a, n.pst, &n);
}

/// Load only properties and recipients (no attachment data) - used for searching.
pub fn loadMessageHeaders(a: Allocator, pst: *Pst, nid: u32) !Message {
    var n = try pst.node(nid);
    return loadMessageOpts(a, &n, false);
}

/// Load a message from a node (top-level message or embedded message sub-node).
pub fn loadMessageNode(a: Allocator, pst: *Pst, n: *Node) !Message {
    _ = pst;
    return loadMessageOpts(a, n, true);
}

fn loadMessageOpts(a: Allocator, n: *Node, with_attachments: bool) !Message {
    const pc = try PropContext.load(a, n);

    var recips: std.ArrayList(Recipient) = .empty;
    if (try n.subNode(a, NID.recipient_table)) |rn_const| {
        var rn = rn_const;
        if (Table.load(a, &rn)) |t| {
            for (0..t.rows.len) |r| {
                var email = t.string(a, r, Tag.smtp_address);
                if (email.len == 0) email = t.string(a, r, Tag.email_address);
                var props: std.ArrayList(Prop) = .empty;
                for (t.cols) |c| if (t.cell(a, r, c.id)) |p| try props.append(a, p);
                try recips.append(a, .{
                    .kind = t.int(a, r, Tag.recipient_type) orelse 1,
                    .name = t.string(a, r, Tag.display_name),
                    .email = email,
                    .addrtype = t.string(a, r, Tag.addrtype),
                    .props = try props.toOwnedSlice(a),
                });
            }
        } else |_| {}
    }

    var atts: std.ArrayList(Attachment) = .empty;
    if (!with_attachments) {} else if (try n.subNode(a, NID.attachment_table)) |an_const| {
        var an = an_const;
        if (Table.load(a, &an)) |t| {
            for (0..t.rows.len) |r| {
                const sub_nid = t.rowId(r);
                var att_node = (try n.subNode(a, sub_nid)) orelse continue;
                const apc = PropContext.load(a, &att_node) catch continue;
                var fname = try apc.string(a, Tag.attach_long_filename);
                if (fname.len == 0) fname = try apc.string(a, Tag.attach_filename);
                if (fname.len == 0) fname = try apc.string(a, Tag.display_name);
                try atts.append(a, .{
                    .sub_nid = sub_nid,
                    .filename = fname,
                    .mime = try apc.string(a, Tag.attach_mime_tag),
                    .content_id = try apc.string(a, Tag.attach_content_id),
                    .method = apc.int(Tag.attach_method) orelse 1,
                    .size = apc.int(Tag.attach_size) orelse 0,
                    .pc = apc,
                    .node = att_node,
                });
            }
        } else |_| {}
    }

    return .{
        .nid = n.nid,
        .node = n.*,
        .pc = pc,
        .recipients = try recips.toOwnedSlice(a),
        .attachments = try atts.toOwnedSlice(a),
    };
}

/// For an embedded-message attachment (method 5), load the inner message.
pub fn embeddedMessage(a: Allocator, att: *Attachment) !?Message {
    if (att.embedded) |e| return e.*;
    var an = att.node orelse return null;
    const p = att.pc.find(Tag.attach_data) orelse return null;
    if (p.ptype != PT.object or p.hnid == 0) return null;
    var sub = (try an.subNode(a, p.hnid)) orelse return null;
    return try loadMessageNode(a, an.pst, &sub);
}

// ================================================================ time formatting (UTC)

pub const DateTime = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

pub fn unixToDateTime(t: i64) DateTime {
    const secs: u64 = @intCast(@max(t, 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

/// "YYYY-MM-DD HH:MM:SS" for a unix timestamp shifted by `offset_secs`.
pub fn fmtTime(buf: []u8, t: ?i64, offset_secs: i64) []const u8 {
    const v = t orelse return "";
    const d = unixToDateTime(v + offset_secs);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ d.year, d.month, d.day, d.hour, d.minute, d.second }) catch "";
}
