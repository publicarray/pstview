//! Deleted-item recovery for PST/OST files (the approach of libpff's pffrecover).
//!
//! When Outlook changes the node or block B-tree it writes the modified pages to new places and
//! frees the old ones, but the old bytes usually stay in the file until the space is reused.
//! This scan reads every page-aligned position of the file, keeps B-tree pages that are valid
//! (page type repeated, checksum correct) but no longer part of the current trees, and uses them:
//!   * stale node-tree leaves list messages that may since have been deleted;
//!   * stale block-tree leaves give file offsets of blocks that are no longer indexed.
//! A message is recovered when its node is missing from the current index (deleted) and its
//! data block can still be read with a matching block trailer (id and checksum). Messages whose
//! node still exists but pointed at a different data block are reported as earlier versions.
//! Recovered nodes and blocks are registered with the Pst, so the normal reader, preview and
//! export work on them. Nothing is written to the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
pub const pst_mod = pst;

pub const Kind = enum { deleted, earlier_version };

pub const Item = struct {
    kind: Kind,
    nid: u32,
    parent: u32,
    bid_data: u64,
    bid_sub: u64,
    /// file offset of the stale index page that listed it
    page_ib: u64,
    summary: pst.MessageSummary,
};

pub const Result = struct {
    pages_checked: u64 = 0,
    stale_node_pages: usize = 0,
    stale_block_pages: usize = 0,
    blocks_found: usize = 0,
    items: []Item = &.{},
};

const Candidate = struct { e: pst.NbtEntry, page_ib: u64 };

/// Scan the whole file. `progress(done, total)` is called now and then with byte counts.
pub fn scan(a: Allocator, f: *pst.Pst, progress: ?*const fn (done: u64, total: u64) void) !Result {
    var res: Result = .{};
    const ps = f.format.pageSize();

    // pages of the current trees
    var live: std.AutoHashMapUnmanaged(u64, void) = .empty;
    try collectPages(a, f, f.nbt_ib, &live, 0);
    try collectPages(a, f, f.bbt_ib, &live, 0);

    var cands: std.ArrayList(Candidate) = .empty;
    var stale_blocks: std.AutoHashMapUnmanaged(u64, pst.BbtEntry) = .empty;
    const chunk = 8 * 1024 * 1024;
    const buf = try a.alloc(u8, chunk);
    var base: u64 = 0;
    while (base < f.file_size) : (base += chunk) {
        const n = f.readRaw(buf, base) catch break;
        if (n == 0) break;
        var o: usize = 0;
        while (o + ps <= n) : (o += ps) {
            const ib = base + o;
            res.pages_checked += 1;
            if (live.contains(ib)) continue;
            const p = buf[o..][0..ps];
            const ptype = f.pageType(p) orelse continue; // not a valid B-tree page
            const m = f.pageMeta(p) catch continue;
            if (m.level != 0) continue;
            if (ptype == 0x81) {
                res.stale_node_pages += 1;
                if (m.cb_ent < 28) continue;
                for (0..m.c_ent) |i| {
                    const e = i * m.cb_ent;
                    const ent: pst.NbtEntry = .{ .nid = @truncate(pst.rd64(p, e)), .bid_data = pst.rd64(p, e + 8), .bid_sub = pst.rd64(p, e + 16), .nid_parent = pst.rd32(p, e + 24) };
                    if ((ent.nid & 0x1F) != pst.NID_TYPE.normal_message or ent.bid_data == 0) continue;
                    try cands.append(a, .{ .e = ent, .page_ib = ib });
                }
            } else {
                res.stale_block_pages += 1;
                for (0..m.c_ent) |i| {
                    const e = i * m.cb_ent;
                    const bid = pst.rd64(p, e) & ~@as(u64, 1);
                    const cb = pst.rd16(p, e + 16);
                    const be: pst.BbtEntry = .{ .bid = bid, .ib = pst.rd64(p, e + 8), .cb = cb, .cb_inflated = if (f.format == .unicode_4k and m.cb_ent >= 20) pst.rd16(p, e + 18) else cb };
                    const gop = try stale_blocks.getOrPut(a, bid);
                    if (!gop.found_existing) gop.value_ptr.* = be;
                }
            }
        }
        if (progress) |cb| cb(base + n, f.file_size);
    }

    // which candidates are deleted (or older versions), and are their blocks still intact?
    var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
    var items: std.ArrayList(Item) = .empty;
    for (cands.items) |c| {
        const key = (@as(u128, c.e.nid) << 64) | c.e.bid_data;
        if (seen.contains(key)) continue;
        try seen.put(a, key, {});
        const current = f.lookupNode(c.e.nid) catch null;
        const kind: Kind = if (current) |cur| (if (cur.bid_data == c.e.bid_data) continue else .earlier_version) else .deleted;
        if (!(try ensureBlocks(a, f, c.e.bid_data, &stale_blocks, &res))) continue;
        if (c.e.bid_sub != 0) _ = try ensureBlocks(a, f, c.e.bid_sub, &stale_blocks, &res);
        // register the node so the reader can load it (earlier versions get a synthetic NID
        // in the unused high range so they do not shadow the current item)
        var nid = c.e.nid;
        if (kind == .earlier_version) nid = 0xF000_0000 | @as(u32, @intCast(items.items.len << 5)) | pst.NID_TYPE.normal_message;
        try f.recovered_nodes.put(f.gpa, nid, .{ .nid = nid, .bid_data = c.e.bid_data, .bid_sub = c.e.bid_sub, .nid_parent = c.e.nid_parent });
        var s = pst.summaryFromNode(a, f, nid, "");
        const pname = if (pst.folderInfo(a, f, c.e.nid_parent)) |fi| fi.name else |_| "?";
        s.note = try std.fmt.allocPrint(a, "{s} - from stale index page at 0x{x}; original folder \"{s}\"{s}", .{
            if (kind == .deleted) "RECOVERED - no longer in the index (deleted, or moved and re-numbered)" else "EARLIER VERSION of an existing item",
            c.page_ib,
            pname,
            if (kind == .earlier_version) (std.fmt.allocPrint(a, "; current item NID 0x{x:0>8}", .{c.e.nid}) catch "") else "",
        });
        try items.append(a, .{ .kind = kind, .nid = nid, .parent = c.e.nid_parent, .bid_data = c.e.bid_data, .bid_sub = c.e.bid_sub, .page_ib = c.page_ib, .summary = s });
    }
    res.items = items.items;
    return res;
}

/// Make every block of a data tree readable: indexed blocks are fine; others are taken from
/// stale block-tree entries if the block on disk still carries the right id and checksum.
fn ensureBlocks(a: Allocator, f: *pst.Pst, bid_in: u64, stale: *std.AutoHashMapUnmanaged(u64, pst.BbtEntry), res: *Result) !bool {
    const bid = bid_in & ~@as(u64, 1);
    if ((f.lookupBlock(bid) catch null) != null) return true;
    const be = stale.get(bid) orelse return false;
    if (!f.blockIntact(a, be)) return false;
    try f.recovered_blocks.put(f.gpa, bid, be);
    res.blocks_found += 1;
    // an XBLOCK / SLBLOCK lists further blocks: they must be recoverable too
    if ((bid & 2) != 0) {
        const kids = f.childBlocks(a, bid) catch return false;
        for (kids) |k| if (!(try ensureBlocks(a, f, k, stale, res))) return false;
    }
    return true;
}

fn collectPages(a: Allocator, f: *pst.Pst, ib: u64, out: *std.AutoHashMapUnmanaged(u64, void), depth: u8) !void {
    if (depth > 32 or out.contains(ib)) return;
    try out.put(a, ib, {});
    const p = f.page(ib) catch return;
    const m = f.pageMeta(p) catch return;
    if (m.level == 0) return;
    for (0..m.c_ent) |i| try collectPages(a, f, pst.rd64(p, i * m.cb_ent + 16), out, depth + 1);
}
