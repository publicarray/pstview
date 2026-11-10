//! pstx - command-line companion for pstview.
//!
//!   pstx tree   <pst|ost>
//!   pstx list   <pst|ost> <folder path | 0xNID>
//!   pstx show   <pst|ost> <message nid (hex)>
//!   pstx export <pst|ost> <folder path | 0xNID> <out dir> [msg|eml] [--modified YYYY-MM-DD] [--match text]
//!   pstx hash   <pst|ost>
//!
//! Dates for --modified are in this computer's local time zone.

const std = @import("std");
const Io = std.Io;
const pst = @import("pst.zig");
const exp = @import("export.zig");
const win = @import("win.zig");
const search = @import("search.zig");
const headers = @import("headers.zig");

fn fmtLocal(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    return pst.fmtTime(buf, v, win.localOffset(v));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    if (args.len < 3) {
        try out.writeAll(
            \\usage:
            \\  pstx tree   <pst|ost>
            \\  pstx list   <pst|ost> <folder path | 0xNID>
            \\  pstx show   <pst|ost> <message nid (hex)>
            \\  pstx export <pst|ost> <folder path | 0xNID> <out dir> [msg|eml] [--modified YYYY-MM-DD] [--match text]
            \\  pstx hash   <pst|ost>
            \\  pstx hidden <pst|ost>      orphaned messages/folders and hidden (FAI) items
            \\  pstx verify <pst|ost>      read every block, check checksums, list problems
            \\  pstx search <pst|ost> <folder|0xNID> "<query>"   e.g. "from:*@gmail.com subject:invoice"
            \\  pstx triage <pst|ost> <folder|0xNID>             header analysis, risky items first
            \\  pstx headers <pst|ost> <message nid>             full header analysis of one message
            \\
        );
        return;
    }
    const cmd = args[1];
    const f = pst.Pst.open(gpa, io, args[2]) catch |e| {
        try out.print("cannot open {s}: {s}\n", .{ args[2], pst.Pst.openErrorText(e) });
        return;
    };
    defer f.close();

    if (std.mem.eql(u8, cmd, "tree")) {
        try printTree(arena, out, f, pst.NID.root_folder, 0);
    } else if (std.mem.eql(u8, cmd, "list")) {
        const path = if (args.len > 3) args[3] else "";
        const nid = (try resolveFolder(arena, f, path)) orelse {
            try out.print("folder not found: {s}\n", .{path});
            return;
        };
        const msgs = try pst.folderMessages(arena, f, nid);
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        for (msgs) |m| {
            const rt = m.delivery_time orelse m.submit_time;
            try out.print("{x:0>8}\t{s}\t{s}\t{s}\t{s}\n", .{
                m.nid,
                pst.fmtTime(&b1, rt, if (rt) |t| win.localOffset(t) else 0),
                pst.fmtTime(&b2, m.modified_time, if (m.modified_time) |t| win.localOffset(t) else 0),
                m.from,
                m.subject,
            });
        }
        try out.print("-- {d} items (times local)\n", .{msgs.len});
    } else if (std.mem.eql(u8, cmd, "hidden")) {
        const h = try pst.hiddenScan(arena, f);
        try out.print("Nodes in index: {d}; folders reachable: {d}; items listed in folder tables: {d}\n\n", .{ h.total_nodes, h.folders_reached, h.listed_messages });
        try out.print("== Orphaned messages (in file, not shown in any folder): {d}\n", .{h.orphans.len});
        try printSummaries(out, h.orphans);
        try out.print("\n== Hidden associated (FAI) items - rules, views, forms: {d}\n", .{h.fai.len});
        try printSummaries(out, h.fai);
        try out.print("\n== Orphaned folders (not reachable from the folder tree): {d}\n", .{h.orphan_folders.len});
        for (h.orphan_folders) |fnid| {
            const info = pst.folderInfo(arena, f, fnid) catch {
                try out.print("  0x{x:0>8}  (unreadable)\n", .{fnid});
                continue;
            };
            try out.print("  0x{x:0>8}  {s}  ({d} items)\n", .{ fnid, info.name, info.count });
        }
        try printIssues(out, f);
    } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "triage")) {
        const is_search = std.mem.eql(u8, cmd, "search");
        if (args.len < (if (is_search) @as(usize, 5) else 4)) return out.writeAll("usage: pstx search <pst|ost> <folder|0xNID> <query>   |   pstx triage <pst|ost> <folder|0xNID>\n");
        const fnid = (try resolveFolder(arena, f, args[3])) orelse return out.print("folder not found: {s}\n", .{args[3]});
        const msgs = try pst.folderMessages(arena, f, fnid);
        const mctx: ?headers.Context = if (is_search) null else search.buildMailboxContext(arena, f, null);
        const ix = search.buildIndexCtx(arena, f, msgs, null, mctx);
        const terms = if (is_search) search.parse(arena, args[4]) else &[_]search.Term{};
        var order: std.ArrayList(usize) = .empty;
        for (msgs, 0..) |_, i| if (!is_search or search.matches(ix.fields[i], terms)) try order.append(arena, i);
        if (!is_search) {
            const Ctx = struct {
                ix: search.FolderIndex,
                fn gt(c: @This(), x: usize, y: usize) bool {
                    return @intFromEnum(c.ix.analyses[x].risk) > @intFromEnum(c.ix.analyses[y].risk);
                }
            };
            std.mem.sort(usize, order.items, Ctx{ .ix = ix }, Ctx.gt);
            try out.print("Organisation domain detected: {s}\n", .{if (ix.ctx.org_domains.len > 0) ix.ctx.org_domains[0] else "?"});
        }
        var b1: [32]u8 = undefined;
        for (order.items) |i| {
            const m = msgs[i];
            const an = ix.analyses[i];
            const rt = m.delivery_time orelse m.submit_time;
            if (!is_search and an.risk == .none) continue;
            try out.print("{x:0>8}  {s}  {s:<7} | {s} | {s} | {s}\n", .{ m.nid, pst.fmtTime(&b1, rt, if (rt) |t| win.localOffset(t) else 0), an.risk.label(), m.from, m.subject, if (an.risk == .none) "" else an.summary() });
        }
        try out.print("-- {d} of {d} items\n", .{ order.items.len, msgs.len });
    } else if (std.mem.eql(u8, cmd, "headers")) {
        if (args.len < 4) return out.writeAll("usage: pstx headers <pst|ost> <message nid hex>\n");
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const m = try pst.loadMessage(arena, f, nid);
        const an = headers.analyse(arena, headers.inputFromMessage(arena, &m), search.buildMailboxContext(arena, f, null));
        try out.writeAll(headers.reportText(arena, an, fmtLocal));
    } else if (std.mem.eql(u8, cmd, "locate")) {
        if (args.len < 4) return out.writeAll("usage: pstx locate <pst|ost> <nid hex>\n");
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const e = (try f.lookupNode(nid)) orelse return out.print("node 0x{x} not in index\n", .{nid});
        try out.print("node 0x{x:0>8} type 0x{x:0>2} parent 0x{x:0>8} bid_data 0x{x} bid_sub 0x{x}\n", .{ e.nid, e.nid & 0x1F, e.nid_parent, e.bid_data, e.bid_sub });
        inline for (.{ .{ "data", e.bid_data }, .{ "sub", e.bid_sub } }) |kv| {
            if (kv[1] != 0) if (try f.lookupBlock(kv[1])) |b| {
                try out.print("  {s} block bid 0x{x} at file offset {d} (0x{x}), {d} bytes", .{ kv[0], b.bid, b.ib, b.ib, b.cb });
                if (b.cb_inflated != b.cb) try out.print(" (zlib, {d} bytes inflated)", .{b.cb_inflated});
                try out.writeAll("\n");
            };
        }
    } else if (std.mem.eql(u8, cmd, "verify")) {
        try verifyCmd(arena, out, f);
    } else if (std.mem.eql(u8, cmd, "hash")) {
        try out.print("{s}  {s}\n", .{ try sha256File(arena, io, f), args[2] });
    } else if (std.mem.eql(u8, cmd, "export")) {
        try exportCmd(arena, io, out, f, args);
    } else if (std.mem.eql(u8, cmd, "show")) {
        if (args.len < 4) return out.writeAll("usage: pstx show <pst|ost> <nid hex>\n");
        const nid = try std.fmt.parseInt(u32, args[3], 16);
        const m = try pst.loadMessage(arena, f, nid);
        var b1: [32]u8 = undefined;
        try out.print("Subject: {s}\nFrom: {s} <{s}>\nReceived (UTC): {s}\nClass: {s}\n", .{
            try m.subject(arena),                                     try m.senderName(arena), try m.senderEmail(arena),
            pst.fmtTime(&b1, m.pc.time(pst.Tag.delivery_time), 0), try m.pc.string(arena, pst.Tag.message_class),
        });
        for (m.recipients) |r| try out.print("Recipient[{d}]: {s} <{s}>\n", .{ r.kind, r.name, r.email });
        for (m.attachments) |at| try out.print("Attachment: {s} ({d} bytes, method {d}, data {d})\n", .{ at.filename, at.size, at.method, at.data().len });
        const body = try m.bodyText(arena);
        try out.print("\n{s}\n", .{body[0..@min(body.len, 2000)]});
    } else {
        try out.print("unknown command {s}\n", .{cmd});
    }
}

fn printSummaries(out: *Io.Writer, list: []const pst.MessageSummary) !void {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    for (list) |m| {
        const rt = m.delivery_time orelse m.submit_time;
        try out.print("  {x:0>8}  {s}  mod {s}  {s}  | {s} | {s} | {s}\n", .{
            m.nid,
            pst.fmtTime(&b1, rt, if (rt) |t| win.localOffset(t) else 0),
            pst.fmtTime(&b2, m.modified_time, if (m.modified_time) |t| win.localOffset(t) else 0),
            m.message_class,
            m.from,
            m.subject,
            m.note,
        });
    }
}

fn printIssues(out: *Io.Writer, f: *pst.Pst) !void {
    try out.print("\n== Integrity log: {d} issue(s)\n", .{f.issues.items.len});
    for (f.issues.items) |is| try out.print("  {s}: id=0x{x} detail=0x{x}\n", .{ is.kind.text(), is.id, is.detail });
}

/// Read every block of every node (data + sub-nodes), checking checksums; then report.
fn verifyCmd(a: std.mem.Allocator, out: *Io.Writer, f: *pst.Pst) !void {
    _ = a;
    const st = try pst.verifyAll(f, null);
    try out.print("Checked {d} nodes, {d} sub-nodes, {d} data blocks ({d} MB) with checksum verification.\n", .{ st.nodes, st.subnodes, st.blocks, st.bytes / (1024 * 1024) });
    try printIssues(out, f);
    if (f.issues.items.len == 0) try out.writeAll("No integrity problems found.\n");
}

fn printTree(a: std.mem.Allocator, out: *Io.Writer, f: *pst.Pst, nid: u32, depth: usize) !void {
    const info = pst.folderInfo(a, f, nid) catch |e| {
        try out.print("{x}: error {s}\n", .{ nid, @errorName(e) });
        return;
    };
    for (0..depth) |_| try out.writeAll("  ");
    const msgs = pst.folderMessages(a, f, nid) catch &.{};
    try out.print("{s}  [count={d} table={d}] nid={x}\n", .{ if (info.name.len > 0) info.name else "(root)", info.count, msgs.len, nid });
    const kids = try pst.subFolders(a, f, nid);
    for (kids) |k| try printTree(a, out, f, k, depth + 1);
}

/// Resolve "Inbox/0.1 Inbox read" style paths below the top-of-store folder.
/// With duplicate names (Acronis exports can contain two "Deleted Items"), the folder with most items wins.
pub fn findFolder(a: std.mem.Allocator, f: *pst.Pst, path: []const u8) !?u32 {
    var cur: u32 = pst.NID.root_folder;
    const top = try pst.subFolders(a, f, cur);
    for (top) |k| {
        const i = try pst.folderInfo(a, f, k);
        if (std.mem.startsWith(u8, i.name, "Top of")) {
            cur = k;
            break;
        }
    }
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        const kids = try pst.subFolders(a, f, cur);
        var found: ?u32 = null;
        var best: i64 = -1;
        for (kids) |k| {
            const i = try pst.folderInfo(a, f, k);
            if (std.ascii.eqlIgnoreCase(i.name, part) and i.count > best) {
                found = k;
                best = i.count;
            }
        }
        cur = found orelse return null;
    }
    return cur;
}

pub fn resolveFolder(a: std.mem.Allocator, f: *pst.Pst, path: []const u8) !?u32 {
    if (std.mem.startsWith(u8, path, "0x")) return try std.fmt.parseInt(u32, path[2..], 16);
    return findFolder(a, f, path);
}

fn sha256File(a: std.mem.Allocator, io: Io, f: *pst.Pst) ![]const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const buf = try a.alloc(u8, 8 * 1024 * 1024);
    var off: u64 = 0;
    while (off < f.file_size) {
        const n = try f.file.readPositionalAll(io, buf, off);
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    const hex = std.fmt.bytesToHex(d, .lower);
    return try a.dupe(u8, &hex);
}

fn writeOut(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn exportCmd(a: std.mem.Allocator, io: Io, out: *Io.Writer, f: *pst.Pst, args: []const [:0]const u8) !void {
    if (args.len < 5) return out.writeAll("usage: pstx export <pst|ost> <folder|0xNID> <outdir> [msg|eml] [--modified YYYY-MM-DD] [--match text]\n");
    const folder = (try resolveFolder(a, f, args[3])) orelse return out.print("folder not found: {s}\n", .{args[3]});
    const dir = args[4];
    var kind: []const u8 = "msg";
    var modified: ?[]const u8 = null;
    var match: ?[]const u8 = null;
    var i: usize = 5;
    while (i < args.len) : (i += 1) {
        const v = args[i];
        if (std.mem.eql(u8, v, "--modified") and i + 1 < args.len) {
            i += 1;
            modified = args[i];
        } else if (std.mem.eql(u8, v, "--match") and i + 1 < args.len) {
            i += 1;
            match = args[i];
        } else kind = v;
    }
    const is_msg = std.mem.eql(u8, kind, "msg");
    try Io.Dir.cwd().createDirPath(io, dir);
    const msgs = try pst.folderMessages(a, f, folder);
    var rows: std.ArrayList(exp.ReportRow) = .empty;
    var n: usize = 0;
    var tb: [64]u8 = undefined;
    for (msgs) |s| {
        if (modified) |d| {
            const t = s.modified_time orelse continue;
            const loc = pst.fmtTime(&tb, t, win.localOffset(t));
            if (!std.mem.startsWith(u8, loc, d)) continue;
        }
        if (match) |q| if (std.ascii.indexOfIgnoreCase(s.subject, q) == null) continue;
        n += 1;
        var ia_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer ia_state.deinit();
        const ia = ia_state.allocator();
        var m = pst.loadMessage(ia, f, s.nid) catch |e| {
            try out.print("  FAILED load 0x{x}: {s}\n", .{ s.nid, @errorName(e) });
            continue;
        };
        const t = s.delivery_time orelse s.submit_time orelse s.modified_time;
        const loc = pst.fmtTime(&tb, t, if (t) |tv| win.localOffset(tv) else 0);
        var pfx_buf: [64]u8 = undefined;
        const pfx = try std.fmt.bufPrint(&pfx_buf, "{d:0>3} {s}", .{ n, if (loc.len >= 16) loc[0..16] else loc });
        for (pfx) |*c| if (c.* == ':') {
            c.* = '-';
        };
        const name = try exp.safeName(a, pfx, s.subject, if (is_msg) "msg" else "eml");
        const data = if (is_msg) try exp.buildMsg(ia, &m) else try exp.buildEml(ia, &m, 0);
        try writeOut(io, try std.fmt.allocPrint(ia, "{s}\\{s}", .{ dir, name }), data);
        var al: std.ArrayList(u8) = .empty;
        for (m.attachments, 0..) |att, k| {
            if (k > 0) try al.appendSlice(a, "; ");
            try al.appendSlice(a, if (att.filename.len > 0) att.filename else "(embedded item)");
        }
        try rows.append(a, .{
            .folder = args[3],
            .nid = s.nid,
            .received = s.delivery_time,
            .sent = s.submit_time,
            .modified = s.modified_time,
            .from = s.from,
            .to = s.to,
            .cc = s.cc,
            .subject = s.subject,
            .class = s.message_class,
            .size = s.size,
            .attachments = al.items,
            .export_file = name,
        });
        try out.print("  {s}  ({d} bytes)\n", .{ name, data.len });
    }
    const now = Io.Clock.real.now(io).toSeconds();
    var fmt_buf: [128]u8 = undefined;
    const meta: exp.ReportMeta = .{
        .pst_path = args[2],
        .pst_size = f.file_size,
        .format = f.describe(&fmt_buf),
        .sha256_hex = try sha256File(a, io, f),
        .generated_utc = now,
        .tz_label = "local time",
        .tz_offset = win.localOffset(now),
        .title = try std.fmt.allocPrint(a, "Export report - {s}", .{args[3]}),
    };
    try writeOut(io, try std.fmt.allocPrint(a, "{s}\\pstview report.csv", .{dir}), try exp.reportCsv(a, rows.items, meta));
    try writeOut(io, try std.fmt.allocPrint(a, "{s}\\pstview report.html", .{dir}), try exp.reportHtml(a, rows.items, meta));
    try out.print("-- exported {d} items to {s}\n", .{ rows.items.len, dir });
}
