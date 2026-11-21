//! pstx - command-line companion for pstview.
//!
//!   pstx tree   <pst|ost>
//!   pstx list   <pst|ost> <folder path | 0xNID>
//!   pstx show   <pst|ost> <message nid (hex)> [--html out.html]   --html: the sanitised safe view as a page
//!   pstx hash   <pst|ost>
//!
//! pstx reads and reports; it does not export. It cannot write .msg, .eml, .pst or attachment
//! files (the export code is not part of it); those exports are made in pstview, where each one
//! asks where to save.

const std = @import("std");
const Io = std.Io;
const pst = @import("pst.zig");
const platform = @import("platform.zig");
const search = @import("search.zig");
const headers = @import("headers.zig");
const store = @import("store.zig");
const Store = store.Store;
const hreport = @import("headerreport.zig");
const mime = @import("mime.zig");
const build_options = @import("build_options");

fn fmtLocal(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    return pst.fmtTime(buf, v, platform.localOffset(v));
}

/// Exit code 0 only when the command did what was asked: scripts and CI rely on it.
pub fn main(init: std.process.Init) u8 {
    run(init) catch |e| switch (e) {
        error.Reported => return 1, // the message is already on stdout
        error.WriteFailed => return 1, // stdout was closed (pstx list ... | head)
        else => {
            std.debug.print("pstx: {s}\n", .{@errorName(e)});
            return 1;
        },
    };
    return 0;
}

/// Print a message for the user and fail the command.
fn fail(out: *Io.Writer, comptime fmt: []const u8, args: anytype) error{ Reported, WriteFailed } {
    out.print(fmt, args) catch return error.WriteFailed;
    return error.Reported;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    mime.charset_hook = &platform.charsetToUtf8;

    var out_buf: [64 * 1024]u8 = undefined;
    // streaming, not positional: redirected output must append (pstx a >> log; pstx b >> log)
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "version"))) {
        try out.print("pstx {s}\n", .{build_options.version});
        return;
    }
    if (args.len < 3) {
        try out.print("pstx {s} - read-only PST / OST / MBOX command-line tool\n", .{build_options.version});
        try out.writeAll(
            \\usage:
            \\  pstx tree   <pst|ost>
            \\  pstx list   <pst|ost> <folder path | 0xNID>
            \\  pstx show   <pst|ost> <message nid (hex)> [--html out.html]   --html: the sanitised safe view as a page
            \\  pstx hash   <pst|ost>
            \\  pstx hidden <pst|ost>      orphaned messages/folders and hidden (FAI) items
            \\  pstx recover <pst|ost>     deleted items and earlier versions recovered from stale index pages
            \\  pstx verify <pst|ost>      read every block, check checksums, list problems
            \\  pstx search <pst|ost> <folder|0xNID> "<query>"   e.g. "from:*@gmail.com subject:invoice"
            \\  pstx triage <pst|ost> <folder|0xNID>             header analysis, risky items first
            \\  pstx headers <pst|ost> <message nid> [--html out.html]      full header analysis of one message
            \\  pstx props   <pst|ost> <message nid> [--html out.html]      every MAPI property (incl. named) of one item
            \\  pstx analyse <message.eml | headers.txt> [--html out.html]  analyse headers without a mailbox
            \\
            \\Exports (.msg, .eml, attachments, PST) are made in pstview, which asks where to save each one.
            \\
        );
        return;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "export") or std.mem.eql(u8, cmd, "topst"))
        return fail(out, "pstx does not export. Use pstview: File > Export ... asks where to save.\n", .{});
    if (std.mem.eql(u8, cmd, "analyse") or std.mem.eql(u8, cmd, "analyze")) return analyseFileCmd(arena, io, out, args);
    const f = Store.open(gpa, io, args[2]) catch |e| {
        return fail(out, "cannot open {s}: {s}\n", .{ args[2], store.openErrorText(e) });
    };
    defer f.close();

    if (std.mem.eql(u8, cmd, "tree")) {
        var db: [200]u8 = undefined;
        try out.print("{s}\n", .{f.describe(&db)});
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try printTree(arena, out, f, f.rootFolder(), 0, &seen);
    } else if (std.mem.eql(u8, cmd, "list")) {
        const path = if (args.len > 3) args[3] else "";
        const nid = (try resolveFolder(arena, f, path)) orelse {
            return fail(out, "folder not found: {s}\n", .{path});
        };
        const msgs = try f.folderMessages(arena, nid);
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        for (msgs) |m| {
            const rt = m.delivery_time orelse m.submit_time;
            try out.print("{x:0>8}\t{s}\t{s}\t{s}\t{s}\n", .{
                m.nid,
                pst.fmtTime(&b1, rt, if (rt) |t| platform.localOffset(t) else 0),
                pst.fmtTime(&b2, m.modified_time, if (m.modified_time) |t| platform.localOffset(t) else 0),
                m.from,
                m.subject,
            });
        }
        try out.print("-- {d} items (times local)\n", .{msgs.len});
    } else if (std.mem.eql(u8, cmd, "hidden")) {
        const parts = try f.pstParts(arena, args[2]);
        if (parts.len == 0) return fail(out, "{s}: only available for PST/OST files\n", .{cmd});
        for (parts) |part| {
            if (parts.len > 1) try out.print("\n######## {s}  (ids below are NIDs within this part)\n", .{part.name});
            try hiddenCmd(arena, out, part.file);
        }
    } else if (std.mem.eql(u8, cmd, "recover")) {
        if (f == .mbox) return fail(out, "{s}: only available for PST/OST files (Thunderbird messages deleted but not compacted are marked in `list`)\n", .{cmd});
        const r = try f.recoverDeleted(arena, args[2], null);
        try out.print("Stale index pages: {d} node-tree, {d} block-tree; {d} unindexed block(s) verified intact by id and checksum.\n\n", .{ r.stale_node_pages, r.stale_block_pages, r.blocks });
        try out.print("== Recovered items no longer in the index (deleted, or moved and re-numbered): {d}\n", .{r.deleted.len});
        try printSummaries(out, r.deleted);
        try out.print("\n== Earlier versions of existing items: {d}\n", .{r.versions.len});
        try printSummaries(out, r.versions);
        try out.writeAll("\nThe ids above work with `pstx show`, `headers` and `props` (the file is re-scanned when an id is not in the live index).\n");
    } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "triage")) {
        const is_search = std.mem.eql(u8, cmd, "search");
        if (args.len < (if (is_search) @as(usize, 5) else 4)) return fail(out, "usage: pstx search <pst|ost> <folder|0xNID> <query>   |   pstx triage <pst|ost> <folder|0xNID>\n", .{});
        const fnid = (try resolveFolder(arena, f, args[3])) orelse return fail(out, "folder not found: {s}\n", .{args[3]});
        const msgs = try f.folderMessages(arena, fnid);
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
            try out.print("{x:0>8}  {s}  {s:<7} | {s} | {s} | {s}\n", .{ m.nid, pst.fmtTime(&b1, rt, if (rt) |t| platform.localOffset(t) else 0), an.risk.label(), m.from, m.subject, if (an.risk == .none) "" else an.summary() });
        }
        try out.print("-- {d} of {d} items\n", .{ order.items.len, msgs.len });
    } else if (std.mem.eql(u8, cmd, "headers")) {
        if (args.len < 4) return fail(out, "usage: pstx headers <pst|ost> <message nid hex> [--html out.html]\n", .{});
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const m = try loadAny(arena, f, args[2], nid);
        const an = headers.analyseDetailed(arena, headers.inputFromMessage(arena, &m), search.buildMailboxContext(arena, f, null));
        try out.writeAll(try hreport.text(arena, an, fmtLocal));
        if (htmlArg(args)) |path| {
            try writeOut(io, path, try hreport.html(arena, an, args[2], fmtLocal));
            try out.print("\nHTML report written to {s}\n", .{path});
        }
    } else if (std.mem.eql(u8, cmd, "props")) {
        if (args.len < 4) return fail(out, "usage: pstx props <source> <message nid hex> [--html out.html]\n", .{});
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const m = try loadAny(arena, f, args[2], nid);
        const propview = @import("propview.zig");
        try out.writeAll(propview.text(arena, &m, fmtLocal));
        if (htmlArg(args)) |path| {
            try writeOut(io, path, propview.html(arena, &m, args[2], fmtLocal));
            try out.print("\nHTML written to {s}\n", .{path});
        }
    } else if (std.mem.eql(u8, cmd, "locate")) {
        if (args.len < 4) return fail(out, "usage: pstx locate <pst|ost> <nid hex>\n", .{});
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const p = pstOnly(out, f, cmd) orelse return error.Reported;
        const e = (try p.lookupNode(nid)) orelse return fail(out, "node 0x{x} not in index\n", .{nid});
        try out.print("node 0x{x:0>8} type 0x{x:0>2} parent 0x{x:0>8} bid_data 0x{x} bid_sub 0x{x}\n", .{ e.nid, e.nid & 0x1F, e.nid_parent, e.bid_data, e.bid_sub });
        inline for (.{ .{ "data", e.bid_data }, .{ "sub", e.bid_sub } }) |kv| {
            if (kv[1] != 0) if (try p.lookupBlock(kv[1])) |b| {
                try out.print("  {s} block bid 0x{x} at file offset {d} (0x{x}), {d} bytes", .{ kv[0], b.bid, b.ib, b.ib, b.cb });
                if (b.cb_inflated != b.cb) try out.print(" (zlib, {d} bytes inflated)", .{b.cb_inflated});
                try out.writeAll("\n");
            };
        }
    } else if (std.mem.eql(u8, cmd, "verify")) {
        const parts = try f.pstParts(arena, args[2]);
        if (parts.len == 0) return fail(out, "{s}: only available for PST/OST files\n", .{cmd});
        for (parts) |part| {
            if (parts.len > 1) try out.print("\n######## {s}\n", .{part.name});
            try verifyCmd(arena, out, part.file);
        }
    } else if (std.mem.eql(u8, cmd, "hash")) {
        for (try f.sourceFiles(arena, args[2])) |sf| {
            const h = try Store.sha256File(gpa, io, sf.path);
            try out.print("{s}  {s}  ({d} bytes)\n", .{ &h, sf.path, sf.size });
        }
    } else if (std.mem.eql(u8, cmd, "show")) {
        if (args.len < 4) return fail(out, "usage: pstx show <pst|ost> <nid hex> [--html out.html]\n", .{});
        const nid = try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, args[3], "0x")) args[3][2..] else args[3], 16);
        const m = try loadAny(arena, f, args[2], nid);
        if (htmlArg(args)) |path| {
            // the safe view of the GUI, as a self-contained page
            try writeOut(io, path, try @import("render.zig").messageDocument(arena, &m, fmtLocal));
            return out.print("wrote {s}\n", .{path});
        }
        var b1: [32]u8 = undefined;
        try out.print("Subject: {s}\nFrom: {s} <{s}>\nReceived (UTC): {s}\nClass: {s}\n", .{
            try m.subject(arena),                                  try m.senderName(arena),                       try m.senderEmail(arena),
            pst.fmtTime(&b1, m.pc.time(pst.Tag.delivery_time), 0), try m.pc.string(arena, pst.Tag.message_class),
        });
        for (@import("itemview.zig").rows(arena, &m, fmtLocal)) |row| try out.print("{s}: {s}\n", .{ row.label, row.value });
        for (m.recipients) |r| try out.print("Recipient[{d}]: {s} <{s}>\n", .{ r.kind, r.name, r.email });
        for (m.attachments) |at| try out.print("Attachment: {s} ({d} bytes, method {d}, data {d})\n", .{ at.filename, at.size, at.method, at.data().len });
        const body = try m.bodyText(arena);
        try out.print("\n{s}\n", .{body[0..@min(body.len, 2000)]});
    } else {
        return fail(out, "unknown command {s}\n", .{cmd});
    }
}

fn printSummaries(out: *Io.Writer, list: []const pst.MessageSummary) !void {
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    for (list) |m| {
        const rt = m.delivery_time orelse m.submit_time;
        try out.print("  {x:0>8}  {s}  mod {s}  {s}  | {s} | {s} | {s}\n", .{
            m.nid,
            pst.fmtTime(&b1, rt, if (rt) |t| platform.localOffset(t) else 0),
            pst.fmtTime(&b2, m.modified_time, if (m.modified_time) |t| platform.localOffset(t) else 0),
            m.message_class,
            m.from,
            m.subject,
            m.note,
        });
    }
}

/// Orphaned messages / folders and hidden (FAI) items of one PST/OST.
fn hiddenCmd(a: std.mem.Allocator, out: *Io.Writer, p: *pst.Pst) !void {
    const h = try pst.hiddenScan(a, p);
    try out.print("Nodes in index: {d}; folders reachable: {d}; items listed in folder tables: {d}\n\n", .{ h.total_nodes, h.folders_reached, h.listed_messages });
    try out.print("== Orphaned messages (in file, not shown in any folder): {d}\n", .{h.orphans.len});
    try printSummaries(out, h.orphans);
    try out.print("\n== Hidden associated (FAI) items - rules, views, forms: {d}\n", .{h.fai.len});
    try printSummaries(out, h.fai);
    try out.print("\n== Orphaned folders (not reachable from the folder tree): {d}\n", .{h.orphan_folders.len});
    for (h.orphan_folders) |fnid| {
        const info = pst.folderInfo(a, p, fnid) catch {
            try out.print("  0x{x:0>8}  (unreadable)\n", .{fnid});
            continue;
        };
        try out.print("  0x{x:0>8}  {s}  ({d} items)\n", .{ fnid, info.name, info.count });
    }
    try printIssues(out, p);
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

/// `seen`: folders already printed. In a damaged file a folder can list itself or one of its
/// parents as a sub-folder; it is shown once.
fn printTree(a: std.mem.Allocator, out: *Io.Writer, f: Store, nid: u32, depth: usize, seen: *std.AutoHashMapUnmanaged(u32, void)) !void {
    if ((try seen.getOrPut(a, nid)).found_existing) {
        for (0..depth) |_| try out.writeAll("  ");
        return out.print("(folder {x} again: listed as its own sub-folder, file is damaged)\n", .{nid});
    }
    const info = f.folderInfo(a, nid) catch |e| {
        try out.print("{x}: error {s}\n", .{ nid, @errorName(e) });
        return;
    };
    for (0..depth) |_| try out.writeAll("  ");
    const msgs = f.folderMessages(a, nid) catch &.{};
    try out.print("{s}  [count={d} table={d}] nid={x}\n", .{ if (info.name.len > 0) info.name else "(root)", info.count, msgs.len, nid });
    const kids = try f.subFolders(a, nid);
    for (kids) |k| try printTree(a, out, f, k, depth + 1, seen);
}

/// The PST behind `f`, or null (after printing why) for sources without PST structures.
fn pstOnly(out: *Io.Writer, f: Store, cmd: []const u8) ?*pst.Pst {
    return switch (f) {
        .pst => |p| p,
        else => {
            out.print("{s}: only available for PST/OST files\n", .{cmd}) catch {};
            return null;
        },
    };
}

/// Resolve "Inbox/0.1 Inbox read" style paths below the top-of-store folder.
/// With duplicate names (an export can contain two "Deleted Items"), the folder with most items wins.
pub fn findFolder(a: std.mem.Allocator, f: Store, path: []const u8) !?u32 {
    var cur: u32 = f.rootFolder();
    const top = try f.subFolders(a, cur);
    // start at the user's folders: "Top of ..." (PST), "Mailbox (merged)" (multi-file set);
    // an OST keeps them in "Root - Mailbox/IPM_SUBTREE"
    for (top) |k| {
        const i = try f.folderInfo(a, k);
        if (std.mem.startsWith(u8, i.name, "Top of") or std.mem.eql(u8, i.name, "Mailbox (merged)")) {
            cur = k;
            break;
        }
        if (std.mem.eql(u8, i.name, "Root - Mailbox")) {
            for (try f.subFolders(a, k)) |c| if (std.mem.eql(u8, (try f.folderInfo(a, c)).name, "IPM_SUBTREE")) {
                cur = c;
                break;
            };
        }
    }
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        const kids = try f.subFolders(a, cur);
        var found: ?u32 = null;
        var best: i64 = -1;
        for (kids) |k| {
            const i = try f.folderInfo(a, k);
            if (std.ascii.eqlIgnoreCase(i.name, part) and i.count > best) {
                found = k;
                best = i.count;
            }
        }
        cur = found orelse return null;
    }
    return cur;
}

pub fn resolveFolder(a: std.mem.Allocator, f: Store, path: []const u8) !?u32 {
    if (std.mem.startsWith(u8, path, "0x")) return try std.fmt.parseInt(u32, path[2..], 16);
    return findFolder(a, f, path);
}

fn writeOut(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

/// Value of a "--html <path>" option.
fn htmlArg(args: []const [:0]const u8) ?[]const u8 {
    for (args, 0..) |v, i| if (std.mem.eql(u8, v, "--html") and i + 1 < args.len) return args[i + 1];
    return null;
}

/// `pstx analyse <file>`: header analysis of a saved message (.eml) or a text file of pasted headers.
fn analyseFileCmd(a: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 3) return fail(out, "usage: pstx analyse <message.eml | headers.txt> [--html out.html]\n", .{});
    const data = Io.Dir.cwd().readFileAlloc(io, args[2], a, .limited(256 * 1024 * 1024)) catch |e| return fail(out, "cannot read {s}: {s}\n", .{ args[2], @errorName(e) });
    const an = headers.analyseDetailed(a, headers.inputFromHeaders(a, headers.headerBlock(data)), .{});
    try out.writeAll(try hreport.text(a, an, fmtLocal));
    if (htmlArg(args)) |path| {
        try writeOut(io, path, try hreport.html(a, an, args[2], fmtLocal));
        try out.print("\nHTML report written to {s}\n", .{path});
    }
}

/// Load a message by id; ids of recovered items (not in the live index) are found by running
/// the stale-page recovery scan once and retrying.
fn loadAny(a: std.mem.Allocator, f: Store, path: []const u8, nid: u32) !pst.Message {
    return f.loadMessage(a, nid) catch |e| {
        if (f == .mbox) return e;
        _ = f.recoverDeleted(a, path, null) catch return e;
        return f.loadMessage(a, nid);
    };
}
