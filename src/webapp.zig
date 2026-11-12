//! pstview for macOS and Linux: the portable half of the GUI.
//!
//! The window's content is one page (webui.html) shown in the operating system's own web view
//! (WKWebView on macOS, WebKitGTK on Linux). This file is the model behind that page: it opens the
//! source read-only, answers the page's requests with JSON and runs exports and reports. The
//! platform shells (gui_mac.zig, gui_gtk.zig) provide the window, the web view and the dialogs.
//!
//! Page -> model: a string "id \x1f command \x1f arg ..." posted to the "pstview" message handler.
//! Model -> page: `pv.reply(id, <json>)` evaluated in the page.
//!
//! Message HTML is shown by the page in a sandboxed frame (no scripts) from the sanitised,
//! CSP-locked document of render.zig; the shells also refuse every navigation, so nothing in a
//! message can reach the network. The page is light or dark (the system's theme, or the View
//! menu's); the documents are rendered to match, with HTML mail bodies always on white.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const List = std.ArrayList(u8);
const pst = @import("pst.zig");
const exp = @import("export.zig");
const render = @import("render.zig");
const search = @import("search.zig");
const hdrs = @import("headers.zig");
const store = @import("store.zig");
const hreport = @import("headerreport.zig");
const itemview = @import("itemview.zig");
const propview = @import("propview.zig");
const mime = @import("mime.zig");
const platform = @import("platform.zig");
const glyph = @import("glyph.zig");
const build_options = @import("build_options");

/// What the model needs from the platform shell.
pub const Shell = struct {
    /// Run JavaScript in the page.
    eval: *const fn (js: []const u8) void,
    /// File or folder chooser; null when cancelled. Paths are absolute.
    pickOpen: *const fn (a: Allocator, title: []const u8, multiple: bool, folders: bool) ?[]const []const u8,
    pickSave: *const fn (a: Allocator, title: []const u8, name: []const u8) ?[]const u8,
    /// Open a folder or file with the desktop's default application.
    openPath: *const fn (path: []const u8) void,
    openUrl: *const fn (url: []const u8) void,
    setTitle: *const fn (title: []const u8) void,
    quit: *const fn (code: u8) void,
};

pub const page_html = @embedFile("webui.html");
pub const project_url = "https://github.com/publicarray/pstview";

const FolderKind = enum { normal, orphans, fai, label, recovered, versions };
const Folder = struct {
    nid: u32,
    path: []const u8,
    name: []const u8,
    label: []const u8,
    count: i64,
    kind: FolderKind = .normal,
    parent: i32 = -1,
    glyph: glyph.Glyph = .folder,
    expanded: bool = false,
};

const App = struct {
    gpa: Allocator,
    io: Io,
    shell: Shell,
    file: ?store.Store = null,
    file_path: []u8 = &.{},
    file_arena: std.heap.ArenaAllocator,
    folder_arena: std.heap.ArenaAllocator,
    folders: std.ArrayList(Folder) = .empty,
    cur_folder: ?usize = null,
    msgs: []pst.MessageSummary = &.{},
    view: std.ArrayList(u32) = .empty,
    sort_col: i32 = 0,
    sort_desc: bool = true,
    query: []u8 = &.{},
    sha_hex: ?[]const u8 = null,
    hidden: ?pst.HiddenScan = null,
    recovery: ?store.Store.Recovery = null,
    index: ?search.FolderIndex = null,
    mailbox_ctx: ?hdrs.Context = null,
    source_name: []const u8 = "",
    source_desc: []const u8 = "",
    /// The report last shown in the viewer, for "Save as".
    last_doc: []u8 = &.{},
    last_doc_name: []u8 = &.{},
    /// Sources to open as soon as the page is up (command line, or files the desktop handed over).
    start_paths: []const []const u8 = &.{},
    page_ready: bool = false,
    selftest: bool = false,
    /// The page's theme (it follows the system or the View menu); documents are rendered to match.
    dark: bool = false,
};

var app: App = undefined;

pub fn init(gpa: Allocator, io: Io, shell: Shell, start_paths: []const []const u8, selftest: bool) void {
    app = .{
        .gpa = gpa,
        .io = io,
        .shell = shell,
        .file_arena = std.heap.ArenaAllocator.init(gpa),
        .folder_arena = std.heap.ArenaAllocator.init(gpa),
        .start_paths = start_paths,
        .selftest = selftest,
    };
    mime.charset_hook = &platform.charsetToUtf8;
}

pub fn deinit() void {
    closeSource();
}

/// Files handed over by the desktop (macOS "Open With", dock drop), before or after the page is up.
pub fn openFromShell(paths: []const []const u8) void {
    if (paths.len == 0) return;
    if (!app.page_ready) {
        const copy = app.gpa.alloc([]const u8, paths.len) catch return;
        for (paths, 0..) |p, i| copy[i] = app.gpa.dupe(u8, p) catch "";
        app.start_paths = copy;
        return;
    }
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: List = .empty;
    out.appendSlice(a, "pv.opened(") catch return;
    openPaths(a, &out, paths) catch return;
    out.append(a, ')') catch return;
    app.shell.eval(out.items);
}

// ================================================================ JSON output

const Error = Allocator.Error;

/// A JSON string. Bytes that are not valid UTF-8 become U+FFFD, so the result is always valid
/// UTF-8; "<", U+2028 and U+2029 are escaped so the text is also safe inside script source.
fn jstr(a: Allocator, out: *List, raw: []const u8) Error!void {
    const s = mime.repairUtf8(a, raw) catch raw;
    try out.ensureUnusedCapacity(a, s.len + 2);
    try out.append(a, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c < 0x80) {
            switch (c) {
                '"' => try out.appendSlice(a, "\\\""),
                '\\' => try out.appendSlice(a, "\\\\"),
                '\n' => try out.appendSlice(a, "\\n"),
                '\r' => try out.appendSlice(a, "\\r"),
                '\t' => try out.appendSlice(a, "\\t"),
                '<' => try out.appendSlice(a, "\\u003c"),
                else => if (c < 0x20 or c == 0x7f) try out.print(a, "\\u{x:0>4}", .{c}) else try out.append(a, c),
            }
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
        if (n < 2 or i + n > s.len or !std.unicode.utf8ValidateSlice(s[i .. i + n])) {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        }
        if (n == 3 and c == 0xE2 and s[i + 1] == 0x80 and (s[i + 2] == 0xA8 or s[i + 2] == 0xA9)) {
            try out.appendSlice(a, if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
        } else try out.appendSlice(a, s[i .. i + n]);
        i += n;
    }
    try out.append(a, '"');
}

/// `"key":` followed by a JSON string, with a leading comma unless `first`.
fn kv(a: Allocator, out: *List, first: bool, key: []const u8, val: []const u8) Error!void {
    if (!first) try out.append(a, ',');
    try out.print(a, "\"{s}\":", .{key});
    try jstr(a, out, val);
}

fn message(a: Allocator, out: *List, comptime fmt: []const u8, args: anytype) Error!void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    try out.append(a, '{');
    try kv(a, out, true, "message", text);
    try out.append(a, '}');
}

fn failure(a: Allocator, out: *List, comptime fmt: []const u8, args: anytype) Error!void {
    const text = try std.fmt.allocPrint(a, fmt, args);
    try out.append(a, '{');
    try kv(a, out, true, "error", text);
    try out.append(a, '}');
}

// ================================================================ requests

/// One request from the page; always answers with exactly one `pv.reply`.
pub fn onMessage(text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = std.mem.indexOfScalar(u8, text, 0x1f) orelse return;
    const id = text[0..s1];
    if (id.len == 0 or id.len > 12) return;
    for (id) |c| if (!std.ascii.isDigit(c)) return;
    const after = text[s1 + 1 ..];
    const s2 = std.mem.indexOfScalar(u8, after, 0x1f);
    const cmd = if (s2) |p| after[0..p] else after;
    const rest = if (s2) |p| after[p + 1 ..] else "";

    var out: List = .empty;
    out.print(a, "pv.reply({s},", .{id}) catch return;
    const mark = out.items.len;
    dispatch(a, &out, cmd, rest) catch {
        out.shrinkRetainingCapacity(mark);
        out.appendSlice(a, "{\"error\":\"Out of memory.\"}") catch return;
    };
    out.append(a, ')') catch return;
    app.shell.eval(out.items);
}

fn argAt(rest: []const u8, n: usize) []const u8 {
    var it = std.mem.splitScalar(u8, rest, 0x1f);
    var i: usize = 0;
    while (it.next()) |x| : (i += 1) if (i == n) return x;
    return "";
}

fn argInt(rest: []const u8, n: usize) ?usize {
    return std.fmt.parseInt(usize, argAt(rest, n), 10) catch null;
}

/// The message in view row `row` of the current folder.
fn rowMsg(row: ?usize) ?u32 {
    const r = row orelse return null;
    if (app.file == null or r >= app.view.items.len) return null;
    return app.view.items[r];
}

fn dispatch(a: Allocator, out: *List, cmd: []const u8, rest: []const u8) Error!void {
    const eq = std.mem.eql;
    if (eq(u8, cmd, "ready")) return ready(a, out);
    if (eq(u8, cmd, "open") or eq(u8, cmd, "openfolder")) {
        const folders = eq(u8, cmd, "openfolder");
        const title = if (folders)
            "Open a folder of MBOX mailboxes or PST parts (Thunderbird mail folder, Apple Mail export) - read-only"
        else
            "Open PST / OST / MBOX - select several PST parts to merge them (read-only)";
        const paths = app.shell.pickOpen(a, title, !folders, folders) orelse return out.appendSlice(a, "{\"cancelled\":true}");
        return openPaths(a, out, paths);
    }
    if (eq(u8, cmd, "close")) {
        closeSource();
        app.shell.setTitle("pstview");
        return out.appendSlice(a, "{}");
    }
    if (eq(u8, cmd, "theme")) {
        app.dark = eq(u8, argAt(rest, 0), "dark");
        return out.appendSlice(a, "{}");
    }
    if (eq(u8, cmd, "site")) {
        app.shell.openUrl(project_url);
        return out.appendSlice(a, "{}");
    }
    if (eq(u8, cmd, "selftest")) {
        const ok = eq(u8, argAt(rest, 0), "ok");
        std.debug.print("pstview selftest {s}: {s}\n", .{ if (ok) "passed" else "FAILED", argAt(rest, 1) });
        app.shell.quit(if (ok) 0 else 1);
        return out.appendSlice(a, "{}");
    }
    if (eq(u8, cmd, "hdrtext")) return analyseHeaderText(a, out, rest, "pasted text");
    if (eq(u8, cmd, "hdrfile")) return analyseHeaderFile(a, out);
    if (eq(u8, cmd, "savedoc")) return saveDoc(a, out);

    if (app.file == null) return failure(a, out, "No mailbox is open.", .{});

    if (eq(u8, cmd, "folder")) {
        const idx = argInt(rest, 0) orelse return failure(a, out, "bad folder", .{});
        selectFolder(idx);
        return listState(a, out);
    }
    if (eq(u8, cmd, "filter")) {
        app.gpa.free(app.query);
        app.query = app.gpa.dupe(u8, rest) catch &.{};
        applyFilter();
        return listState(a, out);
    }
    if (eq(u8, cmd, "sort")) {
        const col: i32 = @intCast(@min(argInt(rest, 0) orelse 0, columns.len - 1));
        if (col == app.sort_col) app.sort_desc = !app.sort_desc else {
            app.sort_col = col;
            app.sort_desc = col <= 1 or col == 5 or col == 7;
        }
        sortView();
        return listState(a, out);
    }
    if (eq(u8, cmd, "rows")) return rows(a, out, argInt(rest, 0) orelse 0, argInt(rest, 1) orelse 0);
    if (eq(u8, cmd, "msg")) {
        const mi = rowMsg(argInt(rest, 0)) orelse return failure(a, out, "No such message.", .{});
        return preview(a, out, app.msgs[mi].nid);
    }
    if (eq(u8, cmd, "doc")) {
        const mi = rowMsg(argInt(rest, 1)) orelse return failure(a, out, "Select a message first.", .{});
        return if (eq(u8, argAt(rest, 0), "props")) allProperties(a, out, app.msgs[mi].nid) else headerReport(a, out, app.msgs[mi].nid);
    }
    if (eq(u8, cmd, "export")) {
        const k = argAt(rest, 0);
        const kind: ExportKind = if (eq(u8, k, "msg")) .msg else if (eq(u8, k, "eml")) .eml else .none;
        return exportSelected(a, out, kind, argAt(rest, 1));
    }
    if (eq(u8, cmd, "saveatts")) {
        const mi = rowMsg(argInt(rest, 0)) orelse return failure(a, out, "Select a message first.", .{});
        return saveAttachments(a, out, app.msgs[mi].nid, if (argAt(rest, 1).len > 0) argInt(rest, 1) else null);
    }
    if (eq(u8, cmd, "analyse")) {
        analyseFolder();
        return listState(a, out);
    }
    if (eq(u8, cmd, "hash")) {
        const h = sourceSha256();
        const shown = h[0..@min(h.len, 3500)];
        return message(a, out, "{s}\n\nSize: {d} bytes\nSHA-256: {s}{s}", .{ app.file_path, app.file.?.totalSize(), shown, if (shown.len < h.len) " ... (all hashes are in the export report)" else "" });
    }
    if (eq(u8, cmd, "integrity") or eq(u8, cmd, "verify")) return integrity(a, out, eq(u8, cmd, "verify"));
    if (eq(u8, cmd, "recover")) return recoverDeleted(a, out);
    return failure(a, out, "Unknown command.", .{});
}

fn ready(a: Allocator, out: *List) Error!void {
    try out.append(a, '{');
    try kv(a, out, true, "version", build_options.version);
    try kv(a, out, false, "os", if (builtin.os.tag.isDarwin()) "macos" else "linux");
    try kv(a, out, false, "url", project_url);
    try out.print(a, ",\"selftest\":{}", .{app.selftest});
    app.page_ready = true;
    if (app.start_paths.len > 0) {
        const paths = app.start_paths;
        app.start_paths = &.{};
        try out.appendSlice(a, ",\"opened\":");
        try openPaths(a, out, paths);
    }
    try out.append(a, '}');
}

// ================================================================ time

fn fmtLocal(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    return pst.fmtTime(buf, v, platform.localOffset(v));
}

fn fmtLocalLong(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    const off = platform.localOffset(v);
    var tb: [32]u8 = undefined;
    const base = pst.fmtTime(&tb, v, off);
    return std.fmt.bufPrint(buf, "{s} (UTC{s}{d:0>2}:{d:0>2})", .{ base, if (off >= 0) "+" else "-", @divTrunc(@abs(off), 3600), @divTrunc(@mod(@abs(off), 3600), 60) }) catch base;
}

// ================================================================ source and folders

fn closeSource() void {
    if (app.file) |f| f.close();
    app.file = null;
    app.gpa.free(app.file_path);
    app.file_path = &.{};
    _ = app.file_arena.reset(.free_all);
    _ = app.folder_arena.reset(.free_all);
    app.folders = .empty;
    app.view = .empty;
    app.msgs = &.{};
    app.index = null;
    app.cur_folder = null;
    app.sha_hex = null;
    app.hidden = null;
    app.recovery = null;
    app.mailbox_ctx = null;
    app.source_name = "";
    app.source_desc = "";
    app.gpa.free(app.query);
    app.query = &.{};
}

/// Open one source, or several PST/OST parts as one merged mailbox, and describe it to the page.
fn openPaths(a: Allocator, out: *List, paths: []const []const u8) Error!void {
    closeSource();
    // several files are remembered as a ';' list, which Store.open accepts again
    const path = try std.mem.join(app.gpa, ";", paths);
    const f = store.Store.openMany(app.gpa, app.io, paths) catch |e| {
        defer app.gpa.free(path);
        app.shell.setTitle("pstview");
        return failure(a, out, "Cannot open:\n{s}\n\n{s}", .{ path[0..@min(path.len, 600)], store.openErrorText(e) });
    };
    app.file = f;
    app.file_path = path;
    const fa = app.file_arena.allocator();
    addFolder(fa, f.rootFolder(), "", -1, 0) catch {};
    if (f.isPst()) addHiddenBranch(fa); // orphan / FAI scan needs PST structures
    var nb: [64]u8 = undefined;
    app.source_name = fa.dupe(u8, if (paths.len == 1) std.fs.path.basename(paths[0]) else std.fmt.bufPrint(&nb, "{d} PST/OST parts", .{paths.len}) catch "mailbox") catch "";
    var db: [128]u8 = undefined;
    app.source_desc = fa.dupe(u8, f.describe(&db)) catch "";
    app.shell.setTitle(std.fmt.allocPrint(a, "{s} \u{2014} pstview (read-only)", .{app.source_name}) catch "pstview");
    const issues = f.issueCount();
    const status = if (issues > 0)
        try std.fmt.allocPrint(a, "Opened {s} ({s}) - {d} folders. {d} integrity issue(s) found - see Tools > Integrity log. Source opened read-only.", .{ app.source_name, app.source_desc, app.folders.items.len, issues })
    else
        try std.fmt.allocPrint(a, "Opened {s} ({s}) - {d} folders. No integrity issues so far. Source opened read-only.", .{ app.source_name, app.source_desc, app.folders.items.len });
    try mailbox(a, out, status);
}

/// The open source for the page: names, the folder tree and the folder to start in.
fn mailbox(a: Allocator, out: *List, status: []const u8) Error!void {
    try out.append(a, '{');
    try kv(a, out, true, "name", app.source_name);
    try kv(a, out, false, "desc", app.source_desc);
    try kv(a, out, false, "status", status);
    try out.print(a, ",\"pst\":{},\"start\":{d},\"folders\":[", .{ app.file.?.isPst(), startFolder() });
    for (app.folders.items, 0..) |f, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{{\"p\":{d},\"g\":\"{s}\",\"open\":{},\"sel\":{},\"label\":", .{ f.parent, @tagName(f.glyph), f.expanded, f.kind != .label });
        try jstr(a, out, f.label);
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]}");
}

/// The Inbox, or else the first folder that holds messages (-1: none).
fn startFolder() i64 {
    var pick: i64 = -1;
    for (app.folders.items, 0..) |f, i| {
        if (f.kind != .normal or f.count <= 0) continue;
        if (std.ascii.eqlIgnoreCase(f.name, "Inbox")) return @intCast(i);
        if (pick < 0) pick = @intCast(i);
    }
    return pick;
}

fn addFolder(a: Allocator, nid: u32, parent_path: []const u8, parent: i32, depth: u32) !void {
    if (depth > 64) return;
    const info = app.file.?.folderInfo(a, nid) catch return;
    const is_root = nid == app.file.?.rootFolder();
    var idx = parent;
    var path = parent_path;
    if (!is_root) {
        path = if (parent_path.len == 0) info.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent_path, info.name });
        // Exchange dumpster folders (in eDiscovery / server exports) hold deleted and purged items
        const dumpster = std.mem.eql(u8, info.name, "Recoverable Items");
        const shown = if (dumpster) "Recoverable Items (Exchange dumpster: deleted / purged items)" else if (info.name.len > 0) info.name else "(unnamed)";
        const label = if (info.count > 0) try std.fmt.allocPrint(a, "{s} ({d})", .{ shown, info.count }) else shown;
        var g = glyph.folderGlyph(info.name, info.container_class);
        if (depth == 1 and g == .folder and info.has_subfolders) g = .mailbox; // top of the mailbox
        idx = @intCast(app.folders.items.len);
        try app.folders.append(a, .{ .nid = nid, .path = path, .name = info.name, .label = label, .count = info.count, .parent = parent, .glyph = g, .expanded = depth <= 2 });
    }
    const kids = app.file.?.subFolders(a, nid) catch return;
    for (kids) |k| try addFolder(a, k, if (is_root) "" else path, idx, depth + 1);
}

fn addBranch(a: Allocator, parent: i32, kind: FolderKind, g: glyph.Glyph, nid: u32, path: []const u8, name: []const u8, count: usize, label: []const u8) i32 {
    const idx: i32 = @intCast(app.folders.items.len);
    app.folders.append(a, .{ .nid = nid, .path = path, .name = name, .label = label, .count = @intCast(count), .kind = kind, .parent = parent, .glyph = g, .expanded = parent < 0 }) catch return -1;
    return idx;
}

/// Scan the whole node index for items the folder tables don't show: the "Hidden items" branch.
fn addHiddenBranch(a: Allocator) void {
    const h = pst.hiddenScan(a, app.file.?.pst) catch return;
    app.hidden = h;
    const p = std.fmt.allocPrint;
    const total = h.orphans.len + h.fai.len + h.orphan_folders.len;
    const root = addBranch(a, -1, .label, .hidden, 0, "[Hidden items]", "Hidden items", 0, p(a, "[Hidden items] ({d})", .{total}) catch "[Hidden items]");
    if (root < 0) return;
    _ = addBranch(a, root, .orphans, .document, 0, "[Hidden items]/Orphaned messages", "Orphaned messages", h.orphans.len, p(a, "Orphaned messages ({d})", .{h.orphans.len}) catch "Orphaned messages");
    _ = addBranch(a, root, .fai, .document, 0, "[Hidden items]/Associated (FAI) items", "Associated (FAI) items", h.fai.len, p(a, "Associated (FAI) items ({d})", .{h.fai.len}) catch "Associated items");
    for (h.orphan_folders) |fnid| {
        const info = pst.folderInfo(a, app.file.?.pst, fnid) catch continue;
        const name = p(a, "Orphaned folder: {s}", .{info.name}) catch continue;
        _ = addBranch(a, root, .normal, .folder, fnid, p(a, "[Hidden items]/{s}", .{name}) catch name, name, @intCast(@max(info.count, 0)), p(a, "{s} ({d})", .{ name, info.count }) catch name);
    }
}

fn selectFolder(idx: usize) void {
    if (app.file == null or idx >= app.folders.items.len) return;
    _ = app.folder_arena.reset(.retain_capacity);
    app.view = .empty;
    app.index = null;
    app.cur_folder = idx;
    const a = app.folder_arena.allocator();
    const fo = app.folders.items[idx];
    app.msgs = switch (fo.kind) {
        .orphans => if (app.hidden) |h| h.orphans else &.{},
        .fai => if (app.hidden) |h| h.fai else &.{},
        .recovered => if (app.recovery) |r| r.deleted else &.{},
        .versions => if (app.recovery) |r| r.versions else &.{},
        .label => &.{},
        .normal => app.file.?.folderMessages(a, fo.nid) catch &.{},
    };
    applyFilter();
}

// ================================================================ message list

const columns = [_][]const u8{ "Received", "Modified", "From", "To", "Subject", "Size", "Class", "Risk (header analysis)", "Note" };

/// Build (once per folder) the search fields and header analysis of every message.
fn ensureIndex() *search.FolderIndex {
    if (app.index) |*ix| return ix;
    app.index = search.buildIndexCtx(app.folder_arena.allocator(), app.file.?, app.msgs, null, app.mailbox_ctx);
    return &app.index.?;
}

fn analyseFolder() void {
    if (app.cur_folder == null) return;
    if (app.mailbox_ctx == null) {
        app.mailbox_ctx = search.buildMailboxContext(app.file_arena.allocator(), app.file.?, null);
        app.index = null; // rebuild with mailbox-wide knowledge
    }
    _ = ensureIndex();
    app.sort_col = 7;
    app.sort_desc = true;
    applyFilter();
}

fn applyFilter() void {
    const a = app.folder_arena.allocator();
    const q = std.mem.trim(u8, app.query, " ");
    const terms = search.parse(a, q);
    const index: []search.Fields = if (terms.len > 0 and app.file != null) ensureIndex().fields else &.{};
    app.view.clearRetainingCapacity();
    for (app.msgs, 0..) |_, i| {
        if (terms.len > 0) {
            if (i >= index.len or !search.matches(index[i], terms)) continue;
        }
        app.view.append(a, @intCast(i)) catch break;
    }
    sortView();
}

fn riskOf(i: u32) u8 {
    const ix = app.index orelse return 0;
    if (i >= ix.analyses.len) return 0;
    return @intFromEnum(ix.analyses[i].risk);
}

fn sortKey(m: pst.MessageSummary, col: i32) i64 {
    return switch (col) {
        0 => m.delivery_time orelse m.submit_time orelse 0,
        1 => m.modified_time orelse 0,
        5 => m.size orelse 0,
        else => 0,
    };
}

fn sortView() void {
    const Ctx = struct {
        col: i32,
        desc: bool,
        fn order(col: i32, x: u32, y: u32) std.math.Order {
            const mx = app.msgs[x];
            const my = app.msgs[y];
            return switch (col) {
                0, 1, 5 => std.math.order(sortKey(mx, col), sortKey(my, col)),
                2 => std.ascii.orderIgnoreCase(mx.from, my.from),
                3 => std.ascii.orderIgnoreCase(mx.to, my.to),
                4 => std.ascii.orderIgnoreCase(mx.subject, my.subject),
                7 => std.math.order(riskOf(x), riskOf(y)),
                8 => std.ascii.orderIgnoreCase(mx.note, my.note),
                else => std.ascii.orderIgnoreCase(mx.message_class, my.message_class),
            };
        }
        fn lt(c: @This(), x: u32, y: u32) bool {
            return order(c.col, x, y) == (if (c.desc) std.math.Order.gt else std.math.Order.lt);
        }
    };
    std.mem.sort(u32, app.view.items, Ctx{ .col = app.sort_col, .desc = app.sort_desc }, Ctx.lt);
}

/// Size, sort order and status line of the list after a folder, filter or sort change.
fn listState(a: Allocator, out: *List) Error!void {
    const fname = if (app.cur_folder) |c| app.folders.items[c].path else "";
    const q = std.mem.trim(u8, app.query, " ");
    var status: []const u8 = "";
    if (app.index != null and app.sort_col == 7 and q.len == 0) {
        const ix = app.index.?;
        var counts: [5]usize = @splat(0);
        for (ix.analyses) |an| counts[@intFromEnum(an.risk)] += 1;
        const org = if (ix.ctx.org_domains.len > 0) ix.ctx.org_domains[0] else "?";
        status = try std.fmt.allocPrint(a, "Header analysis: {d} high, {d} medium, {d} low risk of {d} items. Organisation domain detected: {s}.", .{ counts[4], counts[3], counts[2], app.msgs.len, org });
    } else if (q.len > 0) {
        status = try std.fmt.allocPrint(a, "{s}: {d} of {d} items match \"{s}\"", .{ fname, app.view.items.len, app.msgs.len, q });
    } else status = try std.fmt.allocPrint(a, "{s}: {d} items", .{ fname, app.msgs.len });
    try out.print(a, "{{\"count\":{d},\"total\":{d},\"col\":{d},\"desc\":{},\"folder\":{d}", .{ app.view.items.len, app.msgs.len, app.sort_col, app.sort_desc, if (app.cur_folder) |c| @as(i64, @intCast(c)) else -1 });
    try kv(a, out, false, "status", status);
    try out.append(a, '}');
}

/// Rows `start .. start+count` of the view: the nine column texts and the risk level of each.
fn rows(a: Allocator, out: *List, start: usize, count: usize) Error!void {
    try out.print(a, "{{\"start\":{d},\"rows\":[", .{start});
    const end = @min(app.view.items.len, start +| @min(count, 2000));
    var r = start;
    while (r < end) : (r += 1) {
        const mi = app.view.items[r];
        const m = app.msgs[mi];
        var tb: [64]u8 = undefined;
        var rb: [400]u8 = undefined;
        if (r > start) try out.append(a, ',');
        try out.append(a, '[');
        try jstr(a, out, fmtLocal(&tb, m.delivery_time orelse m.submit_time));
        try out.append(a, ',');
        try jstr(a, out, fmtLocal(&tb, m.modified_time));
        try out.append(a, ',');
        try jstr(a, out, m.from);
        try out.append(a, ',');
        try jstr(a, out, m.to);
        try out.append(a, ',');
        try jstr(a, out, if (m.subject.len > 0) m.subject else "(no subject)");
        try out.append(a, ',');
        try jstr(a, out, if (m.size) |sz| std.fmt.bufPrint(&tb, "{d} KB", .{@divTrunc(sz + 1023, 1024)}) catch "" else "");
        try out.append(a, ',');
        try jstr(a, out, m.message_class);
        try out.append(a, ',');
        const risk: []const u8 = blk: {
            const ix = app.index orelse break :blk "";
            if (mi >= ix.analyses.len) break :blk "";
            const an = ix.analyses[mi];
            if (an.risk == .none) break :blk if (an.has_headers) "-" else "";
            break :blk std.fmt.bufPrint(&rb, "{s}: {s}", .{ an.risk.label(), an.summary() }) catch an.risk.label();
        };
        try jstr(a, out, risk);
        try out.append(a, ',');
        try jstr(a, out, m.note);
        try out.print(a, ",{d}]", .{riskOf(mi)});
    }
    try out.appendSlice(a, "]}");
}

// ================================================================ one message

fn headerContext() hdrs.Context {
    return app.mailbox_ctx orelse if (app.index) |ix| ix.ctx else .{};
}

fn isTextAttachment(att: *const pst.Attachment) bool {
    if (std.ascii.startsWithIgnoreCase(att.mime, "text/")) return !std.ascii.eqlIgnoreCase(att.mime, "text/html");
    const ext = if (std.mem.lastIndexOfScalar(u8, att.filename, '.')) |d| att.filename[d + 1 ..] else "";
    for ([_][]const u8{ "txt", "csv", "log", "ics", "vcf", "xml", "json", "md" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// The reading pane: the safe HTML document, the header analysis, the raw internet headers and
/// the attachment list of one message.
fn preview(a: Allocator, out: *List, nid: u32) Error!void {
    const m = app.file.?.loadMessage(a, nid) catch |e| return failure(a, out, "Error reading message: {s}", .{@errorName(e)});
    const doc = render.messageDocument(a, &m, fmtLocalLong) catch |e| return failure(a, out, "Cannot render message: {s}", .{@errorName(e)});
    const an = hdrs.analyse(a, hdrs.inputFromMessage(a, &m), headerContext());
    var analysis = hdrs.reportText(a, an, fmtLocalLong);
    if (app.mailbox_ctx == null and an.has_headers)
        analysis = try std.fmt.allocPrint(a, "{s}\n(Tools > Analyse headers in this folder adds internal-name impersonation checks.)\n", .{analysis});
    try out.print(a, "{{\"nid\":\"0x{x:0>8}\",\"risk\":{d}", .{ nid, @intFromEnum(an.risk) });
    try kv(a, out, false, "subject", m.subject(a) catch "");
    try kv(a, out, false, "html", themed(a, doc));
    try kv(a, out, false, "analysis", analysis);
    try kv(a, out, false, "headers", m.pc.string(a, pst.Tag.transport_headers) catch "");
    try out.appendSlice(a, ",\"atts\":[");
    for (m.attachments, 0..) |*att, i| {
        if (i > 0) try out.append(a, ',');
        var sb: [32]u8 = undefined;
        try out.append(a, '{');
        try kv(a, out, true, "name", if (att.filename.len > 0) att.filename else "(embedded item)");
        try kv(a, out, false, "size", std.fmt.bufPrint(&sb, "{d} KB", .{@divTrunc(att.size + 1023, 1024)}) catch "");
        try kv(a, out, false, "type", if (att.method == 5) "embedded message" else if (att.mime.len > 0) att.mime else render.mimeForName(att.filename));
        if (att.method != 5 and isTextAttachment(att)) {
            const d = att.data();
            try kv(a, out, false, "text", d[0..@min(d.len, 512 * 1024)]);
        }
        try out.append(a, '}');
    }
    try out.appendSlice(a, "]}");
}

/// The documents follow the system theme on their own (`color-scheme:light dark`, or a
/// `prefers-color-scheme` media query in the reports). Inside the page they must follow the
/// page's theme instead, which the View menu can set against the system: pin them to it.
fn themed(a: Allocator, doc: []const u8) []const u8 {
    const scheme = std.mem.replaceOwned(u8, a, doc, "color-scheme:light dark", if (app.dark) "color-scheme:dark" else "color-scheme:light") catch return doc;
    return std.mem.replaceOwned(u8, a, scheme, "@media (prefers-color-scheme:dark)", if (app.dark) "@media all" else "@media not all") catch scheme;
}

/// A report for the viewer; remembered so that "Save as" can write it.
fn showDoc(a: Allocator, out: *List, title: []const u8, file_name: []const u8, doc: []const u8) Error!void {
    app.gpa.free(app.last_doc);
    app.gpa.free(app.last_doc_name);
    app.last_doc = app.gpa.dupe(u8, doc) catch &.{};
    app.last_doc_name = app.gpa.dupe(u8, file_name) catch &.{};
    try out.append(a, '{');
    try kv(a, out, true, "title", title);
    try kv(a, out, false, "html", themed(a, doc));
    try out.append(a, '}');
}

fn headerReport(a: Allocator, out: *List, nid: u32) Error!void {
    const m = app.file.?.loadMessage(a, nid) catch |e| return failure(a, out, "Cannot read message: {s}", .{@errorName(e)});
    const an = hdrs.analyseDetailed(a, hdrs.inputFromMessage(a, &m), headerContext());
    const doc = hreport.html(a, an, app.file_path, fmtLocalLong) catch |e| return failure(a, out, "Cannot build header report: {s}", .{@errorName(e)});
    var pb: [24]u8 = undefined;
    const name = exp.safeName(a, std.fmt.bufPrint(&pb, "hdr-{x:0>8}", .{nid}) catch "hdr", if (an.subject.len > 0) an.subject else "headers", "html") catch "header analysis.html";
    try showDoc(a, out, try std.fmt.allocPrint(a, "Header analysis: {s}", .{an.summary()}), name, doc);
}

fn allProperties(a: Allocator, out: *List, nid: u32) Error!void {
    const m = app.file.?.loadMessage(a, nid) catch |e| return failure(a, out, "Cannot read message: {s}", .{@errorName(e)});
    const doc = propview.html(a, &m, app.file_path, fmtLocalLong);
    var pb: [24]u8 = undefined;
    const name = exp.safeName(a, std.fmt.bufPrint(&pb, "props-{x:0>8}", .{nid}) catch "props", m.subject(a) catch "item", "html") catch "properties.html";
    try showDoc(a, out, try std.fmt.allocPrint(a, "All properties of item 0x{x:0>8}", .{nid}), name, doc);
}

/// Analyse pasted or loaded header text (a whole message is fine: only its header block is used).
fn analyseHeaderText(a: Allocator, out: *List, text: []const u8, source: []const u8) Error!void {
    const head = hdrs.headerBlock(text);
    if (std.mem.indexOfScalar(u8, head, ':') == null)
        return failure(a, out, "No e-mail headers found.\n\nCopy the complete internet headers (Outlook: File > Properties > Internet headers; Gmail: Show original) and try again.", .{});
    const an = hdrs.analyseDetailed(a, hdrs.inputFromHeaders(a, head), app.mailbox_ctx orelse .{});
    const doc = hreport.html(a, an, source, fmtLocalLong) catch |e| return failure(a, out, "Cannot build header report: {s}", .{@errorName(e)});
    const name = exp.safeName(a, "hdr", if (an.subject.len > 0) an.subject else "headers", "html") catch "header analysis.html";
    try showDoc(a, out, try std.fmt.allocPrint(a, "Header analysis: {s}", .{an.summary()}), name, doc);
}

fn analyseHeaderFile(a: Allocator, out: *List) Error!void {
    const paths = app.shell.pickOpen(a, "Analyse headers from a .eml or .txt file (read-only)", false, false) orelse return out.appendSlice(a, "{\"cancelled\":true}");
    const data = Io.Dir.cwd().readFileAlloc(app.io, paths[0], a, .limited(256 * 1024 * 1024)) catch |e| return failure(a, out, "Cannot read file: {s}", .{@errorName(e)});
    return analyseHeaderText(a, out, data, paths[0]);
}

fn saveDoc(a: Allocator, out: *List) Error!void {
    if (app.last_doc.len == 0) return failure(a, out, "Nothing to save.", .{});
    const path = app.shell.pickSave(a, "Save report as", app.last_doc_name) orelse return out.appendSlice(a, "{\"cancelled\":true}");
    writePath(path, app.last_doc) catch |e| return failure(a, out, "Save failed: {s}", .{@errorName(e)});
    try message(a, out, "Saved:\n{s}", .{path});
}

// ================================================================ export and reports

fn writePath(path: []const u8, data: []const u8) !void {
    const f = try Io.Dir.createFileAbsolute(app.io, path, .{});
    defer f.close(app.io);
    try f.writeStreamingAll(app.io, data);
}

fn writeFile(a: Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    try writePath(try std.fs.path.join(a, &.{ dir, name }), data);
}

/// SHA-256 of the source (cached): one hash, or "path: hash; ..." for multi-file sources.
fn sourceSha256() []const u8 {
    if (app.sha_hex == null) {
        const a = app.file_arena.allocator();
        const files = app.file.?.sourceFiles(a, app.file_path) catch return "";
        if (files.len == 1) {
            const h = store.Store.sha256File(app.gpa, app.io, files[0].path) catch return "";
            app.sha_hex = a.dupe(u8, &h) catch return "";
        } else {
            var out: List = .empty;
            for (files) |sf| {
                const h = store.Store.sha256File(app.gpa, app.io, sf.path) catch continue;
                out.print(a, "{s}: {s}; ", .{ sf.path, &h }) catch {};
            }
            app.sha_hex = out.items;
        }
    }
    return app.sha_hex.?;
}

/// The page's selection: "all" or view rows "3,4,9" -> message indices.
fn selection(a: Allocator, sel: []const u8) []u32 {
    if (std.mem.eql(u8, sel, "all")) return a.dupe(u32, app.view.items) catch &.{};
    var out: std.ArrayList(u32) = .empty;
    var it = std.mem.splitScalar(u8, sel, ',');
    while (it.next()) |x| {
        const r = std.fmt.parseInt(usize, x, 10) catch continue;
        if (r < app.view.items.len) out.append(a, app.view.items[r]) catch break;
    }
    return out.items;
}

const ExportKind = enum { msg, eml, none };

/// Export the selected items as .msg / .eml with the HTML + CSV report, or (`none`) only the report.
fn exportSelected(a: Allocator, out: *List, kind: ExportKind, sel: []const u8) Error!void {
    var rows_idx = selection(a, sel);
    if (rows_idx.len == 0) {
        if (kind != .none) return failure(a, out, "Select one or more messages first.", .{});
        rows_idx = a.dupe(u32, app.view.items) catch &.{}; // whole (filtered) folder
    }
    const picked = app.shell.pickOpen(a, switch (kind) {
        .msg => "Export selected items as .msg to this folder",
        .eml => "Export selected items as .eml to this folder",
        .none => "Write report (HTML + CSV) to this folder",
    }, false, true) orelse return out.appendSlice(a, "{\"cancelled\":true}");
    const dir = picked[0];
    const sha = sourceSha256();
    var report: std.ArrayList(exp.ReportRow) = .empty;
    var ok: usize = 0;
    var failed: usize = 0;
    for (rows_idx, 0..) |mi, n| {
        const s = app.msgs[mi];
        var item_arena = std.heap.ArenaAllocator.init(app.gpa);
        defer item_arena.deinit();
        const ia = item_arena.allocator();
        var export_name: []const u8 = "";
        var atts: []const u8 = "";
        if (app.file.?.loadMessage(ia, s.nid)) |m_const| {
            var m = m_const;
            var al: List = .empty;
            for (m.attachments, 0..) |att, i| {
                if (i > 0) al.appendSlice(a, "; ") catch {};
                al.appendSlice(a, if (att.filename.len > 0) att.filename else "(embedded item)") catch {};
            }
            atts = al.items;
            if (kind != .none) {
                var tb: [64]u8 = undefined;
                var prefix_buf: [96]u8 = undefined;
                const ts = fmtLocal(&tb, s.delivery_time orelse s.submit_time orelse s.modified_time);
                const pfx: []u8 = a.dupe(u8, std.fmt.bufPrint(&prefix_buf, "{d:0>4} {s}", .{ n + 1, if (ts.len >= 16) ts[0..16] else ts }) catch "") catch &.{};
                for (pfx) |*c| if (c.* == ':') {
                    c.* = '-';
                };
                const name = exp.safeName(a, pfx, s.subject, if (kind == .msg) "msg" else "eml") catch "item";
                // .eml from an MBOX is the original message, byte for byte
                const raw: ?[]const u8 = if (kind == .msg) null else (app.file.?.rawMessage(ia, s.nid) catch null);
                const data = if (raw) |r| r else (if (kind == .msg) exp.buildMsg(ia, &m) else exp.buildEml(ia, &m, 0)) catch null;
                if (data) |d| {
                    if (writeFile(ia, dir, name, d)) {
                        export_name = name;
                        ok += 1;
                    } else |_| failed += 1;
                } else failed += 1;
            }
        } else |_| failed += 1;
        report.append(a, .{
            .folder = if (app.cur_folder) |c| app.folders.items[c].path else "",
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
            .attachments = atts,
            .export_file = export_name,
        }) catch {};
    }
    const now: i64 = Io.Clock.real.now(app.io).toSeconds();
    const off = platform.localOffset(now);
    const fpath = if (app.cur_folder) |c| app.folders.items[c].path else "";
    var fmt_buf: [128]u8 = undefined;
    const meta: exp.ReportMeta = .{
        .pst_path = app.file_path,
        .pst_size = app.file.?.totalSize(),
        .format = app.file.?.describe(&fmt_buf),
        .sha256_hex = sha,
        .generated_utc = now,
        .tz_label = std.fmt.allocPrint(a, "local time (UTC{s}{d}:{d:0>2} at report time)", .{ if (off >= 0) "+" else "-", @divTrunc(@abs(off), 3600), @divTrunc(@mod(@abs(off), 3600), 60) }) catch "local time",
        .tz_offset = off,
        .title = std.fmt.allocPrint(a, "Export report - {s}", .{fpath}) catch "Export report",
    };
    var report_failed = false;
    writeFile(a, dir, "pstview report.csv", exp.reportCsv(a, report.items, meta) catch "") catch {
        report_failed = true;
    };
    writeFile(a, dir, "pstview report.html", exp.reportHtml(a, report.items, meta) catch "") catch {
        report_failed = true;
    };
    if (report_failed) return failure(a, out, "The report could not be written to:\n{s}", .{dir});
    app.shell.openPath(dir);
    if (kind == .none) return message(a, out, "Report of {d} items written to:\n{s}", .{ report.items.len, dir });
    return message(a, out, "Exported {d} item(s), {d} failed.\nReport written alongside.\n\n{s}", .{ ok, failed, dir });
}

fn attachmentBytes(a: Allocator, att: *pst.Attachment, ext_out: *[]const u8) ?[]const u8 {
    if (att.method == 5) {
        var inner = (pst.embeddedMessage(a, att) catch null) orelse return null;
        ext_out.* = "msg";
        return exp.buildMsg(a, &inner) catch null;
    }
    ext_out.* = "";
    return att.data();
}

/// Save one attachment (`which`) through a save dialog, or all of them into a chosen folder.
fn saveAttachments(a: Allocator, out: *List, nid: u32, which: ?usize) Error!void {
    const m = app.file.?.loadMessage(a, nid) catch |e| return failure(a, out, "Cannot read message: {s}", .{@errorName(e)});
    if (m.attachments.len == 0) return message(a, out, "This message has no attachments.", .{});
    if (which) |i| {
        if (i >= m.attachments.len) return failure(a, out, "No such attachment.", .{});
        const att = &m.attachments[i];
        var ext: []const u8 = "";
        const data = attachmentBytes(a, att, &ext) orelse return failure(a, out, "The attachment could not be read.", .{});
        const name = if (ext.len > 0) (exp.safeName(a, "", att.filename, ext) catch "embedded.msg") else (if (att.filename.len > 0) std.fs.path.basename(att.filename) else "attachment.bin");
        const path = app.shell.pickSave(a, "Save attachment as", name) orelse return out.appendSlice(a, "{\"cancelled\":true}");
        writePath(path, data) catch |e| return failure(a, out, "Save failed: {s}", .{@errorName(e)});
        return message(a, out, "Saved:\n{s}", .{path});
    }
    const picked = app.shell.pickOpen(a, "Save all attachments to this folder", false, true) orelse return out.appendSlice(a, "{\"cancelled\":true}");
    var saved: usize = 0;
    for (m.attachments, 0..) |*att, i| {
        var ext: []const u8 = "";
        const data = attachmentBytes(a, att, &ext) orelse continue;
        var pb: [8]u8 = undefined;
        const pfx = std.fmt.bufPrint(&pb, "{d:0>2}", .{i + 1}) catch "";
        const fname = if (att.filename.len > 0) att.filename else "attachment";
        const dot = std.mem.lastIndexOfScalar(u8, fname, '.');
        const name = exp.safeName(a, pfx, if (ext.len > 0) fname else (if (dot) |d| fname[0..d] else fname), if (ext.len > 0) ext else (if (dot) |d| fname[d + 1 ..] else "bin")) catch continue;
        writeFile(a, picked[0], name, data) catch continue;
        saved += 1;
    }
    return message(a, out, "Saved {d} of {d} attachment(s) to:\n{s}", .{ saved, m.attachments.len, picked[0] });
}

// ================================================================ integrity and recovery

/// The integrity log, after reading every block when `verify` is set, as text for the page.
fn integrity(a: Allocator, out: *List, verify: bool) Error!void {
    if (app.file.? == .mbox)
        return message(a, out, "The integrity log and block verification apply to PST/OST files (MBOX has no internal checksums).\n\nUse File > Show SHA-256 of source file to fix the evidence state.", .{});
    var text: List = .empty;
    const parts = app.file.?.pstParts(a, app.file_path) catch &.{};
    if (verify) {
        var tot: pst.VerifyStats = .{};
        for (parts) |p| {
            const st = pst.verifyAll(p.file, null) catch continue;
            tot.nodes += st.nodes;
            tot.subnodes += st.subnodes;
            tot.blocks += st.blocks;
            tot.bytes += st.bytes;
        }
        try text.print(a, "Verified {d} nodes, {d} sub-nodes, {d} data blocks ({d} MB); every page and block checksum checked.\n\n", .{ tot.nodes, tot.subnodes, tot.blocks, tot.bytes / (1024 * 1024) });
    }
    if (app.hidden) |h| try text.print(a, "Hidden-item scan: {d} nodes in index, {d} folders reachable, {d} items listed in folder tables;\n{d} orphaned message(s), {d} associated (FAI) item(s), {d} orphaned folder(s).\n\n", .{ h.total_nodes, h.folders_reached, h.listed_messages, h.orphans.len, h.fai.len, h.orphan_folders.len });
    for (parts) |p| {
        if (parts.len > 1) try text.print(a, "======== {s}\n", .{p.name});
        try text.appendSlice(a, pst.issuesText(a, p.file) catch "");
        if (parts.len > 1) try text.append(a, '\n');
    }
    try out.append(a, '{');
    try kv(a, out, true, "title", if (verify) "Verify every block" else "Integrity log");
    try kv(a, out, false, "text", text.items);
    try kv(a, out, false, "status", try std.fmt.allocPrint(a, "Integrity log: {d} issue(s)", .{app.file.?.issueCount()}));
    try out.append(a, '}');
}

/// Scan every page of the PST/OST part(s) for stale index pages and list what they recover
/// (items no longer indexed, earlier versions) in a "[Recovered items]" branch.
fn recoverDeleted(a: Allocator, out: *List) Error!void {
    if (app.file.? == .mbox)
        return message(a, out, "Recovery from stale index pages applies to PST/OST files.\n\nFor Thunderbird mailboxes, messages deleted but not yet compacted are already listed and marked in their folders.", .{});
    if (app.recovery != null) return message(a, out, "Recovery has already run for this file - see the [Recovered items] branch.", .{});
    const fa = app.file_arena.allocator();
    const r = app.file.?.recoverDeleted(fa, app.file_path, null) catch |e| return failure(a, out, "Recovery failed: {s}", .{@errorName(e)});
    app.recovery = r;
    const p = std.fmt.allocPrint;
    const root = addBranch(fa, -1, .label, .recovered, 0, "[Recovered items]", "Recovered items", 0, p(fa, "[Recovered items] ({d})", .{r.deleted.len + r.versions.len}) catch "[Recovered items]");
    _ = addBranch(fa, root, .recovered, .recovered, 0, "[Recovered items]/No longer indexed", "No longer indexed", r.deleted.len, p(fa, "No longer indexed - deleted or moved ({d})", .{r.deleted.len}) catch "No longer indexed");
    _ = addBranch(fa, root, .versions, .journal, 0, "[Recovered items]/Earlier versions", "Earlier versions", r.versions.len, p(fa, "Earlier versions of existing items ({d})", .{r.versions.len}) catch "Earlier versions");
    const summary = try p(a, "Recovery scan finished.\n\n{d} item(s) no longer in the index (deleted, or moved and re-numbered) and {d} earlier version(s) of existing items were recovered from {d} stale node-tree and {d} stale block-tree page(s); {d} unindexed block(s) were verified intact by id and checksum.\n\nSee the [Recovered items] branch. Each item's Note names the stale page and the folder it was in.", .{ r.deleted.len, r.versions.len, r.stale_node_pages, r.stale_block_pages, r.blocks });
    try out.append(a, '{');
    try kv(a, out, true, "message", summary);
    try out.appendSlice(a, ",\"mailbox\":");
    try mailbox(a, out, try p(a, "Recovery: {d} no longer indexed, {d} earlier versions.", .{ r.deleted.len, r.versions.len }));
    try out.append(a, '}');
}
