//! pstview - native Windows PST viewer / exporter (read-only).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const w = @import("win.zig");
const pst = @import("pst.zig");
const exp = @import("export.zig");
const render = @import("render.zig");
const search = @import("search.zig");
const hdrs = @import("headers.zig");
const store = @import("store.zig");
const hreport = @import("headerreport.zig");
const itemview = @import("itemview.zig");
const mime = @import("mime.zig");
const rtf = @import("rtf.zig");
const ui = @import("ui.zig");
const install = @import("install.zig");
const webview2 = @import("webview2.zig");
const build_options = @import("build_options");
const L = w.L;

const ID_TREE = 100;
const ID_LIST = 101;
const ID_PREVIEW = 102;
const ID_SEARCH = 103;
const ID_STATUS = 104;

const CMD_OPEN = 1;
const CMD_EXPORT_MSG = 2;
const CMD_EXPORT_EML = 3;
const CMD_REPORT = 4;
const CMD_SAVE_ATT = 5;
const CMD_EXIT = 6;
const CMD_ABOUT = 7;
const CMD_SELECT_ALL = 8;
const CMD_HASH = 9;
const CMD_INTEGRITY = 10;
const CMD_VERIFY = 11;
const CMD_OPEN_MSG = 12;
const CMD_SAFE_HTML = 13;
const CMD_ANALYSE = 14;
const CMD_HDR_REPORT = 15;
const CMD_HDR_CLIP = 16;
const CMD_HDR_FILE = 17;
const CMD_OPEN_FOLDER = 18;
const CMD_PROPS = 19;
const CMD_RECOVER = 20;
const CMD_INSTALL = 21;
const CMD_UNINSTALL = 22;
const CMD_DEFAULT_APPS = 23;
const CMD_CLOSE = 24;
const CMD_THEME_SYSTEM = 30;
const CMD_THEME_LIGHT = 31;
const CMD_THEME_DARK = 32;

/// Posted after the main window is shown: offer to install (first run of the portable exe).
const WM_APP_FIRST_RUN = w.WM_APP + 1;

// message-window commands
const MW_HTML = 201;
const MW_EXPORT_MSG = 202;
const MW_EXPORT_EML = 203;
const MW_SAVE_ATT = 204;
const MW_SAVE_ALL = 205;
const MW_CLOSE = 206;
const MW_HDR = 207;
const MW_PROPS = 208;
const ID_MW_HEADER = 301;
const ID_MW_ATTS = 302;
const ID_MW_BODY = 303;
const ID_MW_IMG = 304;

const FolderKind = enum { normal, orphans, fai, label, recovered, versions };
const Folder = struct { nid: u32, path: []const u8, name: []const u8, count: i64, kind: FolderKind = .normal, item: ?w.HTREEITEM = null };

const columns = [_]struct { title: [:0]const u16, width: i32, right: bool = false }{
    .{ .title = L("Received"), .width = 140 },
    .{ .title = L("Modified"), .width = 140 },
    .{ .title = L("From"), .width = 180 },
    .{ .title = L("To"), .width = 180 },
    .{ .title = L("Subject"), .width = 380 },
    .{ .title = L("Size"), .width = 80, .right = true },
    .{ .title = L("Class"), .width = 120 },
    .{ .title = L("Risk (header analysis)"), .width = 320 },
    .{ .title = L("Note"), .width = 260 },
};

const App = struct {
    gpa: Allocator,
    io: Io,
    hinst: ?w.HINSTANCE = null,
    hwnd: ?w.HWND = null,
    tree: ?w.HWND = null,
    list: ?w.HWND = null,
    preview: ?w.HWND = null,
    search: ?w.HWND = null,
    status: ?w.HWND = null,
    font: ?w.HFONT = null,
    scale: f32 = 1.0,
    split_x: i32 = 300,
    split_y_frac: f32 = 0.45,
    dragging: bool = false,
    dragging_y: bool = false,
    // visual style (ui.zig)
    bold: ?w.HFONT = null,
    pane_brush: ?w.HBRUSH = null,
    white_brush: ?w.HBRUSH = null,
    hairline_brush: ?w.HBRUSH = null,
    glyph_font: ?w.HFONT = null,
    /// Left-pane header: source name and description.
    source_name: []u8 = &.{},
    source_desc: []u8 = &.{},
    /// No message selected: the preview is hidden and a hint painted in its place.
    preview_empty: bool = true,
    help_menu: ?w.HMENU = null,
    view_menu: ?w.HMENU = null,
    /// View > Theme: follow Windows (the default; not stored - pstview writes no settings), or fixed.
    theme: enum { system, light, dark } = .system,
    /// Text of the status bar parts (the parts are owner-drawn in the theme's colours).
    status_text: [3][512]u8 = undefined,
    status_len: [3]usize = .{ 0, 0, 0 },

    file: ?store.Store = null,
    file_path: []u8 = &.{},
    file_arena: std.heap.ArenaAllocator,
    folder_arena: std.heap.ArenaAllocator,
    preview_arena: std.heap.ArenaAllocator,
    folders: std.ArrayList(Folder) = .empty,
    cur_folder: ?usize = null,
    msgs: []pst.MessageSummary = &.{},
    view: std.ArrayList(u32) = .empty,
    sort_col: i32 = 0,
    sort_desc: bool = true,
    sha_hex: ?[]const u8 = null,
    hidden: ?pst.HiddenScan = null,
    recovery: ?store.Store.Recovery = null,
    temp_files: std.ArrayList([]u8) = .empty,
    index: ?search.FolderIndex = null,
    mailbox_ctx: ?hdrs.Context = null,
    mono: ?w.HFONT = null,
    wbuf: [2048]u16 = undefined,
};

var app: App = undefined;

// ================================================================ panic handler

/// A panic (a bug: ReleaseSafe safety check) would otherwise end the GUI process without a word,
/// because a windows-subsystem program has no console for the panic message. Show it first.
pub const panic = std.debug.FullPanic(guiPanic);

/// Message being read when a panic hits (0 = none) - named in the crash dialog so it can be reported.
var reading_nid: u32 = 0;
var panicking = std.atomic.Value(bool).init(false);

fn guiPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking.swap(true, .seq_cst)) {
        var tb: [1024]u8 = undefined;
        var nb: [64]u8 = undefined;
        const short = msg[0..@min(msg.len, 700)];
        const item = if (reading_nid != 0) std.fmt.bufPrint(&nb, " while reading message 0x{x:0>8}", .{reading_nid}) catch "" else "";
        const text = std.fmt.bufPrint(&tb, "pstview hit an internal error{s} and has to close. The source file was not changed.\n\n{s}\n\nPlease report this, with the details above, at https://github.com/publicarray/pstview/issues", .{ item, short }) catch short;
        var wb: [1200]u16 = undefined; // text is at most 1024 bytes, so at most 1024 UTF-16 units
        const n = std.unicode.wtf8ToWtf16Le(&wb, text) catch 0;
        wb[n] = 0;
        const wtext: [*:0]const u16 = if (n > 0) wb[0..n :0].ptr else toW(&wb, text);
        _ = w.MessageBoxW(null, wtext, L("pstview - internal error"), w.MB_ICONERROR | w.MB_TASKMODAL | w.MB_SETFOREGROUND);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

// ================================================================ text helpers

/// UTF-8 -> UTF-16 into a fixed buffer (truncating), NUL-terminated.
fn toW(buf: []u16, s: []const u8) [*:0]u16 {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(s) catch {
        for (s) |c| {
            if (n + 1 >= buf.len) break;
            buf[n] = @intCast(mime.cp1252Char(c));
            n += 1;
        }
        buf[n] = 0;
        return buf[0..n :0].ptr;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\r' or cp == '\n' or cp == '\t') {
            if (n + 1 >= buf.len) break;
            buf[n] = ' ';
            n += 1;
            continue;
        }
        if (cp >= 0x10000) {
            if (n + 2 >= buf.len) break;
            const v = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (v >> 10));
            buf[n + 1] = @intCast(0xDC00 + (v & 0x3FF));
            n += 2;
        } else {
            if (n + 1 >= buf.len) break;
            buf[n] = @intCast(cp);
            n += 1;
        }
    }
    buf[n] = 0;
    return buf[0..n :0].ptr;
}

fn toWAlloc(a: Allocator, raw: []const u8) ![:0]u16 {
    const s = mime.repairUtf8(a, raw) catch raw;
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch {
        const buf = try a.alloc(u16, s.len + 1);
        const p = toW(buf, s);
        return std.mem.span(p);
    };
}

/// Normalise line endings to CRLF (the Edit control needs them).
fn crlf(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len + s.len / 16);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\r') {
            try out.appendSlice(a, "\r\n");
            if (i + 1 < s.len and s[i + 1] == '\n') i += 1;
        } else if (c == '\n') {
            try out.appendSlice(a, "\r\n");
        } else try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// Index just past the element that starts at `start` (a tag named `name`), honouring nesting.
fn skipElement(html: []const u8, start: usize, name: []const u8) usize {
    var depth: usize = 0;
    var i = start;
    while (i < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, i, '<') orelse return html.len;
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return html.len;
        const t = html[lt + 1 .. gt];
        const closing = t.len > 0 and t[0] == '/';
        const tn = if (closing) t[1..] else t;
        if (std.ascii.startsWithIgnoreCase(tn, name) and (tn.len == name.len or !std.ascii.isAlphanumeric(tn[name.len]))) {
            if (closing) {
                depth -|= 1;
                if (depth == 0) return gt + 1;
            } else if (t.len == 0 or t[t.len - 1] != '/') depth += 1;
        }
        i = gt + 1;
    }
    return html.len;
}

fn isHiddenTag(tag: []const u8) bool {
    var buf: [512]u8 = undefined;
    var n: usize = 0;
    for (tag) |ch| {
        if (n >= buf.len) break;
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') continue;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    const s = buf[0..n];
    return std.mem.indexOf(u8, s, "display:none") != null or std.mem.indexOf(u8, s, "visibility:hidden") != null or
        std.mem.indexOf(u8, s, "max-height:0") != null or std.mem.indexOf(u8, s, "mso-hide:all") != null;
}

/// HTML -> readable text for the preview pane: drops comments (incl. Outlook <!--[if mso]> blocks),
/// head/style/script, hidden preheader text; decodes entities; tidies whitespace.
fn htmlToText(a: Allocator, html: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var last_space = false;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            if (std.mem.startsWith(u8, html[i..], "<!--")) {
                const e = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
                i = @min(e + 3, html.len);
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const tag = html[i + 1 .. end];
            const ls = struct {
                fn f(t: []const u8, p: []const u8) bool {
                    if (!std.ascii.startsWithIgnoreCase(t, p)) return false;
                    return t.len == p.len or !std.ascii.isAlphanumeric(t[p.len]);
                }
            }.f;
            if (tag.len > 0 and (tag[0] == '!' or tag[0] == '?')) {
                i = end + 1;
                continue;
            }
            inline for (.{ "style", "script", "head", "title", "xml" }) |skip| {
                if (ls(tag, skip)) {
                    i = skipElement(html, i, skip);
                    break;
                }
            } else {
                // hidden elements (newsletter preheaders etc.)
                if (tag.len > 0 and tag[0] != '/' and isHiddenTag(tag)) {
                    var ne: usize = 0;
                    while (ne < tag.len and std.ascii.isAlphanumeric(tag[ne])) ne += 1;
                    if (ne > 0 and tag[tag.len - 1] != '/') {
                        i = skipElement(html, i, tag[0..ne]);
                        continue;
                    }
                }
                if (ls(tag, "br") or ls(tag, "/p") or ls(tag, "p") or ls(tag, "/div") or ls(tag, "/tr") or ls(tag, "/li") or ls(tag, "/table") or ls(tag, "/h1") or ls(tag, "/h2") or ls(tag, "/h3") or ls(tag, "/h4") or ls(tag, "hr")) {
                    try raw.append(a, '\n');
                    last_space = true;
                } else if (ls(tag, "li")) {
                    try raw.appendSlice(a, "\n - ");
                    last_space = true;
                } else if (ls(tag, "td") or ls(tag, "th")) {
                    if (!last_space) try raw.append(a, ' ');
                    last_space = true;
                }
                i = end + 1;
            }
            continue;
        }
        if (c == '&') {
            const semi = std.mem.indexOfScalarPos(u8, html, i, ';');
            if (semi) |s| if (s - i <= 10) {
                const ent = html[i + 1 .. s];
                var cp: ?u21 = null;
                if (ent.len > 1 and ent[0] == '#') {
                    cp = if (ent[1] == 'x' or ent[1] == 'X')
                        std.fmt.parseInt(u21, ent[2..], 16) catch null
                    else
                        std.fmt.parseInt(u21, ent[1..], 10) catch null;
                } else {
                    const named = [_]struct { e: []const u8, c: u21 }{
                        .{ .e = "nbsp", .c = ' ' },      .{ .e = "amp", .c = '&' },      .{ .e = "lt", .c = '<' },
                        .{ .e = "gt", .c = '>' },        .{ .e = "quot", .c = '"' },     .{ .e = "apos", .c = '\'' },
                        .{ .e = "rsquo", .c = 0x2019 },  .{ .e = "lsquo", .c = 0x2018 }, .{ .e = "rdquo", .c = 0x201D },
                        .{ .e = "ldquo", .c = 0x201C },  .{ .e = "ndash", .c = 0x2013 }, .{ .e = "mdash", .c = 0x2014 },
                        .{ .e = "hellip", .c = 0x2026 }, .{ .e = "copy", .c = 0xA9 },    .{ .e = "reg", .c = 0xAE },
                        .{ .e = "trade", .c = 0x2122 },  .{ .e = "bull", .c = 0x2022 },  .{ .e = "zwnj", .c = 0x200C },
                        .{ .e = "zwj", .c = 0x200D },    .{ .e = "shy", .c = 0xAD },
                    };
                    for (named) |n| if (std.mem.eql(u8, ent, n.e)) {
                        cp = n.c;
                        break;
                    };
                }
                if (cp) |v| {
                    i = s + 1;
                    // invisible padding characters used in newsletter preheaders
                    if (v == 0x200C or v == 0x200D or v == 0xAD or v == 0x34F or v == 0x200B or v == 0xFEFF) continue;
                    if (v == ' ' or v == 0xA0) {
                        if (!last_space) try raw.append(a, ' ');
                        last_space = true;
                        continue;
                    }
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(v, &b) catch 0;
                    try raw.appendSlice(a, b[0..n]);
                    last_space = false;
                    continue;
                }
            };
        }
        if (c == '\r' or c == '\n' or c == '\t' or c == ' ') {
            if (!last_space) try raw.append(a, ' ');
            last_space = true;
            i += 1;
            continue;
        }
        last_space = false;
        try raw.append(a, c);
        i += 1;
    }
    // tidy: trim each line, collapse runs of blank lines to one
    var out: std.ArrayList(u8) = .empty;
    var blank_run: usize = 0;
    var it = std.mem.splitScalar(u8, raw.items, '\n');
    var first = true;
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\xC2\xA0");
        if (t.len == 0) {
            blank_run += 1;
            if (blank_run > 1 or first) continue;
        } else blank_run = 0;
        if (!first) try out.append(a, '\n');
        first = false;
        try out.appendSlice(a, t);
    }
    return out.toOwnedSlice(a);
}

fn fmtLocal(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    return pst.fmtTime(buf, v, w.localOffset(v));
}

/// A notice in pstview's own dialog (silent, selectable text) over the active pstview window.
/// `flags` takes the MB_ICON* value of the message box it replaces.
fn msgBox(text: []const u8, title: []const u8, flags: u32) i32 {
    const kind: ui.DialogKind = switch (flags & 0xF0) {
        w.MB_ICONERROR => .err,
        0x30 => .warning,
        else => .info,
    };
    const heading = if (std.mem.eql(u8, title, "pstview")) "" else if (std.mem.startsWith(u8, title, "pstview - ")) title["pstview - ".len..] else title;
    const owner = w.GetActiveWindow() orelse app.hwnd;
    return ui.dialog(owner, app.hinst, .{ .kind = kind, .heading = heading, .body = text });
}

/// Status bar parts: 0 = read-only seal (owner-drawn), 1 = source, 2 = messages.
const SB_PART_SEAL = 0;
const SB_PART_SOURCE = 1;
const SB_PART_TEXT = 2;

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    setStatusPart(SB_PART_TEXT, s);
}

fn setStatusPart(part: usize, s: []const u8) void {
    const n = @min(s.len, app.status_text[part].len);
    @memcpy(app.status_text[part][0..n], s[0..n]);
    app.status_len[part] = n;
    const st = app.status.?;
    _ = w.SendMessageW(st, w.SB_SETTEXTW, part | w.SBT_OWNERDRAW | w.SBT_NOBORDERS, 0);
    _ = w.InvalidateRect(st, null, 1);
    _ = w.UpdateWindow(st); // progress texts are set while the window is busy
}

fn statusParts() void {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(app.hwnd.?, &rc);
    const seal = sc(118);
    const parts = [3]i32{ seal, @max(seal + sc(200), @min(seal + sc(460), rc.right - sc(260))), -1 };
    _ = w.SendMessageW(app.status.?, w.SB_SETPARTS, parts.len, @intCast(@intFromPtr(&parts)));
    _ = w.SendMessageW(app.status.?, w.SB_SETTEXTW, SB_PART_SEAL | w.SBT_OWNERDRAW | w.SBT_NOBORDERS, 0);
}

/// A status bar part. The first is an amber dot and "Read-only" - the one amber mark in the
/// window; the others are text.
fn drawSeal(di: *const w.DRAWITEMSTRUCT) void {
    const dc = di.hDC orelse return;
    const r = di.rcItem;
    _ = w.FillRect(dc, &r, app.pane_brush);
    if (di.itemID != SB_PART_SEAL and di.itemID < app.status_text.len) {
        _ = w.SetBkMode(dc, w.TRANSPARENT);
        if (app.font) |f| _ = w.SelectObject(dc, @ptrCast(f));
        paintText(dc, null, ui.ink_soft, app.status_text[di.itemID][0..app.status_len[di.itemID]], .{ .left = r.left + sc(8), .top = r.top, .right = r.right - sc(4), .bottom = r.bottom }, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_END_ELLIPSIS);
        return;
    }
    const d = sc(8);
    const cy = @divTrunc(r.top + r.bottom, 2);
    const x = r.left + sc(8);
    if (w.CreateSolidBrush(w.rgb(ui.amber))) |br| {
        const ob = w.SelectObject(dc, @ptrCast(br));
        const op = w.SelectObject(dc, w.GetStockObject(w.NULL_PEN));
        _ = w.Ellipse(dc, x, cy - @divTrunc(d, 2), x + d, cy - @divTrunc(d, 2) + d);
        _ = w.SelectObject(dc, op);
        _ = w.SelectObject(dc, ob);
        _ = w.DeleteObject(@ptrCast(br));
    }
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    _ = w.SetTextColor(dc, w.rgb(ui.ink));
    var tr: w.RECT = .{ .left = x + d + sc(8), .top = r.top, .right = r.right, .bottom = r.bottom };
    const t = L("Read-only");
    _ = w.DrawTextW(dc, t.ptr, @intCast(t.len), &tr, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_NOPREFIX);
}

fn waitCursor(on: bool) void {
    _ = w.SetCursor(w.LoadCursorW(null, if (on) w.IDC_WAIT else w.IDC_ARROW));
}

// ================================================================ file / folder dialogs

fn pickFolder(a: Allocator, title: []const u8) ?[]u8 {
    var name: [260]u16 = undefined;
    const tw = toWAlloc(a, title) catch return null;
    var bi: w.BROWSEINFOW = .{ .hwndOwner = app.hwnd, .pszDisplayName = &name, .lpszTitle = tw, .ulFlags = w.BIF_RETURNONLYFSDIRS | w.BIF_NEWDIALOGSTYLE | w.BIF_EDITBOX };
    const pidl = w.SHBrowseForFolderW(&bi) orelse return null;
    defer w.CoTaskMemFree(pidl);
    var path: [1024]u16 = @splat(0);
    if (w.SHGetPathFromIDListW(pidl, &path) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &path, 0) orelse 0;
    return std.unicode.utf16LeToUtf8Alloc(a, path[0..len]) catch null;
}

fn openDialog() void {
    var file: [32768]u16 = @splat(0);
    const filter = L("Mail files (*.pst;*.ost;*.mbox;*.mbx)\x00*.pst;*.ost;*.mbox;*.mbx\x00Outlook data files (*.pst;*.ost)\x00*.pst;*.ost\x00MBOX files (*.mbox;*.mbx)\x00*.mbox;*.mbx\x00All files - e.g. Thunderbird mailboxes (*.*)\x00*.*\x00");
    var ofn: w.OPENFILENAMEW = .{ .hwndOwner = app.hwnd, .lpstrFilter = filter.ptr, .lpstrFile = &file, .nMaxFile = file.len, .Flags = w.OFN_FILEMUSTEXIST | w.OFN_PATHMUSTEXIST | w.OFN_EXPLORER | w.OFN_HIDEREADONLY | w.OFN_ALLOWMULTISELECT, .lpstrTitle = L("Open PST / OST / MBOX - select several PST parts to merge them (read-only)") };
    if (w.GetOpenFileNameW(&ofn) == 0) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // one file: "C:\dir\file.pst\0\0"; several: "C:\dir\0a.pst\0b.pst\0\0"
    var parts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < file.len and file[i] != 0) {
        const e = std.mem.indexOfScalarPos(u16, &file, i, 0) orelse break;
        parts.append(a, std.unicode.utf16LeToUtf8Alloc(a, file[i..e]) catch return) catch return;
        i = e + 1;
    }
    if (parts.items.len == 0) return;
    if (parts.items.len == 1) return openPaths(parts.items);
    var paths: std.ArrayList([]const u8) = .empty;
    for (parts.items[1..]) |name| paths.append(a, std.fs.path.join(a, &.{ parts.items[0], name }) catch return) catch return;
    openPaths(paths.items);
}

fn openPst(path: []const u8) void {
    openPaths(&.{path});
}

/// Open a folder of mailboxes: Thunderbird profile/Mail folder, Apple Mail export, or any folder of MBOX files.
fn openFolderDialog() void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const path = pickFolder(arena.allocator(), "Open a folder of MBOX mailboxes (Thunderbird mail folder, Apple Mail export .mbox, or any folder of .mbox files) - read-only") orelse return;
    openPst(path);
}

fn writeFile(a: Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name });
    const f = try Io.Dir.createFileAbsolute(app.io, path, .{});
    defer f.close(app.io);
    try f.writeStreamingAll(app.io, data);
}

// ================================================================ PST loading

fn closePst() void {
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
    _ = w.SendMessageW(app.tree.?, w.TVM_DELETEITEM, 0, @bitCast(@intFromPtr(w.TVI_ROOT)));
    _ = w.SendMessageW(app.list.?, w.LVM_SETITEMCOUNT, 0, 0);
    _ = w.SetWindowTextW(app.preview.?, L(""));
    app.gpa.free(app.source_name);
    app.gpa.free(app.source_desc);
    app.source_name = &.{};
    app.source_desc = &.{};
    setPreviewEmpty(true);
    _ = w.SetWindowTextW(app.hwnd.?, L("pstview"));
    setStatusPart(SB_PART_SOURCE, "");
    setStatusPart(SB_PART_TEXT, "");
    showMailboxView(false);
}

/// Mailbox panes when a source is open, the welcome screen otherwise.
fn showMailboxView(on: bool) void {
    inline for (.{ app.tree, app.search, app.list }) |h| _ = w.ShowWindow(h.?, if (on) w.SW_SHOW else w.SW_HIDE);
    if (!on) _ = w.ShowWindow(app.preview.?, w.SW_HIDE) else if (!app.preview_empty) _ = w.ShowWindow(app.preview.?, w.SW_SHOW);
    if (ui.welcome.hwnd) |h| _ = w.ShowWindow(h, if (on) w.SW_HIDE else w.SW_SHOW);
    layout();
    _ = w.InvalidateRect(app.hwnd.?, null, 1);
}

/// Hide the preview (and paint a hint in its place) while no message is selected.
fn setPreviewEmpty(empty: bool) void {
    if (app.preview_empty == empty) return;
    app.preview_empty = empty;
    _ = w.ShowWindow(app.preview.?, if (empty or app.file == null) w.SW_HIDE else w.SW_SHOW);
    _ = w.InvalidateRect(app.hwnd.?, null, 1);
}

/// Select the Inbox, or else the first folder that holds messages.
fn selectStartFolder() void {
    var pick: ?usize = null;
    for (app.folders.items, 0..) |f, i| {
        if (f.kind != .normal or f.item == null) continue;
        if (std.ascii.eqlIgnoreCase(f.name, "Inbox") and f.count > 0) {
            pick = i;
            break;
        }
        if (pick == null and f.count > 0) pick = i;
    }
    const i = pick orelse return;
    _ = w.SendMessageW(app.tree.?, w.TVM_SELECTITEM, w.TVGN_CARET, @bitCast(@intFromPtr(app.folders.items[i].item.?)));
}

/// Open one source, or several PST/OST parts as one merged mailbox.
fn openPaths(paths: []const []const u8) void {
    closePst();
    waitCursor(true);
    defer waitCursor(false);
    // several files are remembered as a ';' list, which Store.open accepts again
    const path = std.mem.join(app.gpa, ";", paths) catch return;
    const f = store.Store.openMany(app.gpa, app.io, paths) catch |e| {
        var b: [1024]u8 = undefined;
        _ = msgBox(std.fmt.bufPrint(&b, "Cannot open:\n{s}\n\n{s}", .{ path[0..@min(path.len, 600)], store.openErrorText(e) }) catch "error", "pstview", w.MB_ICONERROR);
        app.gpa.free(path);
        return;
    };
    app.file = f;
    app.file_path = path;
    const a = app.file_arena.allocator();
    addFolder(a, app.file.?.rootFolder(), "", null, 0) catch |e| {
        _ = msgBox(@errorName(e), "Error reading folders", w.MB_ICONERROR);
    };
    if (f.isPst()) addHiddenBranch(a); // orphan / FAI scan needs PST structures
    var b: [600]u8 = undefined;
    var tb: [700]u16 = undefined;
    const shown_name = if (paths.len == 1) std.fs.path.basename(paths[0]) else std.fmt.bufPrint(&b, "{d} PST/OST parts", .{paths.len}) catch "mailbox";
    app.source_name = app.gpa.dupe(u8, shown_name) catch &.{};
    var db: [128]u8 = undefined;
    app.source_desc = app.gpa.dupe(u8, f.describe(&db)) catch &.{};
    var b2: [700]u8 = undefined;
    _ = w.SetWindowTextW(app.hwnd.?, toW(&tb, std.fmt.bufPrint(&b2, "{s} \u{2014} pstview (read-only)", .{app.source_name}) catch "pstview"));
    setStatusPart(SB_PART_SOURCE, app.source_desc);
    showMailboxView(true);
    selectStartFolder();
    const issues = f.issueCount();
    if (issues > 0)
        setStatus("Opened {s} ({s}) - {d} folders. {d} integrity issue(s) found - see Tools > Integrity log. Source opened read-only.", .{ std.fs.path.basename(path), f.describe(&db), app.folders.items.len, issues })
    else
        setStatus("Opened {s} ({s}) - {d} folders. No integrity issues so far. Source opened read-only.", .{ std.fs.path.basename(path), f.describe(&db), app.folders.items.len });
}

fn insertTreeItem(a: Allocator, parent: ?w.HTREEITEM, label: []const u8, idx: usize, expanded: bool, glyph: ui.Glyph) ?w.HTREEITEM {
    const lw = toWAlloc(a, label) catch return null;
    var ins: w.TVINSERTSTRUCTW = .{ .hParent = parent orelse w.TVI_ROOT, .hInsertAfter = w.TVI_LAST, .item = .{
        .mask = w.TVIF_TEXT | w.TVIF_PARAM | w.TVIF_STATE | w.TVIF_IMAGE | w.TVIF_SELECTEDIMAGE,
        .iImage = @intFromEnum(glyph),
        .iSelectedImage = @intFromEnum(glyph),
        .pszText = lw,
        .lParam = @intCast(idx),
        .state = if (expanded) w.TVIS_EXPANDED else 0,
        .stateMask = w.TVIS_EXPANDED,
    } };
    const r = w.SendMessageW(app.tree.?, w.TVM_INSERTITEMW, 0, @bitCast(@intFromPtr(&ins)));
    const item: ?w.HTREEITEM = if (r != 0) @ptrFromInt(@as(usize, @bitCast(r))) else null;
    if (idx < app.folders.items.len) app.folders.items[idx].item = item;
    return item;
}

/// Scan the whole node index for items the folder tables don't show, and add a "Hidden items" branch.
fn addHiddenBranch(a: Allocator) void {
    setStatus("Scanning for hidden and orphaned items...", .{});
    const h = pst.hiddenScan(a, app.file.?.pst) catch |e| {
        setStatus("Hidden-item scan failed: {s}", .{@errorName(e)});
        return;
    };
    app.hidden = h;
    const root_idx = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Hidden items]", .name = "Hidden items", .count = 0, .kind = .label }) catch return;
    const total = h.orphans.len + h.fai.len + h.orphan_folders.len;
    const root_label = std.fmt.allocPrint(a, "[Hidden items] ({d})", .{total}) catch "[Hidden items]";
    const root = insertTreeItem(a, null, root_label, root_idx, true, .hidden);

    const oi = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Hidden items]/Orphaned messages", .name = "Orphaned messages", .count = @intCast(h.orphans.len), .kind = .orphans }) catch return;
    _ = insertTreeItem(a, root, std.fmt.allocPrint(a, "Orphaned messages ({d})", .{h.orphans.len}) catch "Orphaned messages", oi, false, .document);

    const fi = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Hidden items]/Associated (FAI) items", .name = "Associated (FAI) items", .count = @intCast(h.fai.len), .kind = .fai }) catch return;
    _ = insertTreeItem(a, root, std.fmt.allocPrint(a, "Associated (FAI) items ({d})", .{h.fai.len}) catch "Associated items", fi, false, .document);

    for (h.orphan_folders) |fnid| {
        const info = pst.folderInfo(a, app.file.?.pst, fnid) catch continue;
        const idx = app.folders.items.len;
        const name = std.fmt.allocPrint(a, "Orphaned folder: {s}", .{info.name}) catch continue;
        app.folders.append(a, .{ .nid = fnid, .path = std.fmt.allocPrint(a, "[Hidden items]/{s}", .{name}) catch name, .name = name, .count = info.count }) catch continue;
        _ = insertTreeItem(a, root, std.fmt.allocPrint(a, "{s} ({d})", .{ name, info.count }) catch name, idx, false, .folder);
    }
}

fn addFolder(a: Allocator, nid: u32, parent_path: []const u8, parent_item: ?w.HTREEITEM, depth: u32) !void {
    if (depth > 64) return;
    // a damaged file can list a folder as its own sub-folder: each folder is shown once
    if (depth > 0 and nid == app.file.?.rootFolder()) return;
    for (app.folders.items) |seen| if (seen.kind == .normal and seen.nid == nid) return;
    const info = app.file.?.folderInfo(a, nid) catch return;
    const is_root = nid == app.file.?.rootFolder();
    var item = parent_item;
    var path = parent_path;
    if (!is_root) {
        path = if (parent_path.len == 0) info.name else try std.fmt.allocPrint(a, "{s}/{s}", .{ parent_path, info.name });
        const idx = app.folders.items.len;
        try app.folders.append(a, .{ .nid = nid, .path = path, .name = info.name, .count = info.count });
        // Exchange dumpster folders (in eDiscovery / server exports) hold deleted and purged items
        const dumpster = std.mem.eql(u8, info.name, "Recoverable Items");
        const shown = if (dumpster) "Recoverable Items (Exchange dumpster: deleted / purged items)" else info.name;
        const label = if (info.count > 0) try std.fmt.allocPrint(a, "{s} ({d})", .{ shown, info.count }) else shown;
        var glyph = ui.folderGlyph(info.name, info.container_class);
        if (depth == 1 and glyph == .folder and info.has_subfolders) glyph = .mailbox; // top of the mailbox
        const lw = try toWAlloc(a, if (label.len > 0) label else "(unnamed)");
        var ins: w.TVINSERTSTRUCTW = .{ .hParent = parent_item orelse w.TVI_ROOT, .hInsertAfter = w.TVI_LAST, .item = .{
            .mask = w.TVIF_TEXT | w.TVIF_PARAM | w.TVIF_STATE | w.TVIF_IMAGE | w.TVIF_SELECTEDIMAGE,
            .iImage = @intFromEnum(glyph),
            .iSelectedImage = @intFromEnum(glyph),
            .pszText = lw,
            .lParam = @intCast(idx),
            .state = if (depth <= 2) w.TVIS_EXPANDED else 0,
            .stateMask = w.TVIS_EXPANDED,
        } };
        const r = w.SendMessageW(app.tree.?, w.TVM_INSERTITEMW, 0, @bitCast(@intFromPtr(&ins)));
        item = if (r != 0) @ptrFromInt(@as(usize, @bitCast(r))) else parent_item;
        if (r != 0) app.folders.items[idx].item = item;
    }
    const kids = app.file.?.subFolders(a, nid) catch return;
    for (kids) |k| try addFolder(a, k, if (is_root) "" else path, item, depth + 1);
}

fn selectFolder(idx: usize) void {
    if (app.file == null or idx >= app.folders.items.len) return;
    waitCursor(true);
    defer waitCursor(false);
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
        .normal => app.file.?.folderMessages(a, fo.nid) catch |e| blk: {
            setStatus("Error reading folder: {s}", .{@errorName(e)});
            break :blk &.{};
        },
    };
    applyFilter();
    _ = w.SetWindowTextW(app.preview.?, L(""));
    setPreviewEmpty(true);
}

// ================================================================ list view model

fn searchText(a: Allocator) []const u8 {
    const n = w.GetWindowTextLengthW(app.search.?);
    if (n <= 0) return "";
    const buf = a.alloc(u16, @intCast(n + 1)) catch return "";
    const got = w.GetWindowTextW(app.search.?, buf.ptr, n + 1);
    return std.unicode.utf16LeToUtf8Alloc(a, buf[0..@intCast(got)]) catch "";
}

fn indexProgress(done: usize, total: usize) void {
    setStatus("Reading sender / recipients / internet headers... {d}/{d}", .{ done, total });
}

/// Build (once per folder) the search fields and header analysis of every message.
fn ensureIndex() *search.FolderIndex {
    if (app.index) |*ix| return ix;
    waitCursor(true);
    defer waitCursor(false);
    app.index = search.buildIndexCtx(app.folder_arena.allocator(), app.file.?, app.msgs, &indexProgress, app.mailbox_ctx);
    return &app.index.?;
}

fn mailboxProgress(done: usize, total: usize) void {
    _ = total;
    setStatus("Learning internal names and domain from the whole mailbox... {d} messages", .{done});
}

fn analyseFolder() void {
    if (app.file == null or app.cur_folder == null) return;
    if (app.mailbox_ctx == null) {
        waitCursor(true);
        app.mailbox_ctx = search.buildMailboxContext(app.file_arena.allocator(), app.file.?, &mailboxProgress);
        waitCursor(false);
        app.index = null; // rebuild with mailbox-wide knowledge
    }
    const ix = ensureIndex();
    var counts: [5]usize = @splat(0);
    for (ix.analyses) |an| counts[@intFromEnum(an.risk)] += 1;
    app.sort_col = 7;
    app.sort_desc = true;
    applyFilter();
    const org = if (ix.ctx.org_domains.len > 0) ix.ctx.org_domains[0] else "?";
    setStatus("Header analysis: {d} high, {d} medium, {d} low risk of {d} items. Organisation domain detected: {s}. Sorted by Risk.", .{ counts[4], counts[3], counts[2], app.msgs.len, org });
}

fn applyFilter() void {
    const a = app.folder_arena.allocator();
    const q = std.mem.trim(u8, searchText(a), " ");
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
    _ = w.SendMessageW(app.list.?, w.LVM_SETITEMCOUNT, app.view.items.len, 0);
    _ = w.SendMessageW(app.list.?, w.LVM_REDRAWITEMS, 0, @intCast(app.view.items.len));
    const fname = if (app.cur_folder) |c| app.folders.items[c].path else "";
    if (q.len > 0)
        setStatus("{s}: {d} of {d} items match \"{s}\"", .{ fname, app.view.items.len, app.msgs.len, q })
    else
        setStatus("{s}: {d} items", .{ fname, app.msgs.len });
}

fn sortKeyTime(m: pst.MessageSummary, col: i32) i64 {
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
        fn lt(c: @This(), x: u32, y: u32) bool {
            const mx = app.msgs[x];
            const my = app.msgs[y];
            const r: bool = switch (c.col) {
                0, 1, 5 => sortKeyTime(mx, c.col) < sortKeyTime(my, c.col),
                2 => std.ascii.lessThanIgnoreCase(mx.from, my.from),
                3 => std.ascii.lessThanIgnoreCase(mx.to, my.to),
                4 => std.ascii.lessThanIgnoreCase(mx.subject, my.subject),
                7 => riskOf(x) < riskOf(y),
                8 => std.ascii.lessThanIgnoreCase(mx.note, my.note),
                else => std.ascii.lessThanIgnoreCase(mx.message_class, my.message_class),
            };
            return if (c.desc) !r and x != y and !eq(c.col, x, y) else r;
        }
        fn eq(col: i32, x: u32, y: u32) bool {
            const mx = app.msgs[x];
            const my = app.msgs[y];
            return switch (col) {
                0, 1, 5 => sortKeyTime(mx, col) == sortKeyTime(my, col),
                2 => std.ascii.eqlIgnoreCase(mx.from, my.from),
                3 => std.ascii.eqlIgnoreCase(mx.to, my.to),
                4 => std.ascii.eqlIgnoreCase(mx.subject, my.subject),
                7 => riskOf(x) == riskOf(y),
                8 => std.ascii.eqlIgnoreCase(mx.note, my.note),
                else => std.ascii.eqlIgnoreCase(mx.message_class, my.message_class),
            };
        }
        fn riskOf(i: u32) u8 {
            const ix = app.index orelse return 0;
            if (i >= ix.analyses.len) return 0;
            return @intFromEnum(ix.analyses[i].risk);
        }
    };
    std.mem.sort(u32, app.view.items, Ctx{ .col = app.sort_col, .desc = app.sort_desc }, Ctx.lt);
}

fn dispInfo(di: *w.NMLVDISPINFOW) void {
    if ((di.item.mask & w.LVIF_TEXT) == 0) return;
    const row: usize = @intCast(di.item.iItem);
    if (row >= app.view.items.len) return;
    const mi = app.view.items[row];
    const m = app.msgs[mi];
    var tb: [64]u8 = undefined;
    var rb: [400]u8 = undefined;
    const s: []const u8 = switch (di.item.iSubItem) {
        7 => blk: {
            const ix = app.index orelse break :blk "";
            if (mi >= ix.analyses.len) break :blk "";
            const an = ix.analyses[mi];
            if (an.risk == .none) break :blk if (an.has_headers) "-" else "";
            break :blk std.fmt.bufPrint(&rb, "{s}: {s}", .{ an.risk.label(), an.summary() }) catch an.risk.label();
        },
        0 => fmtLocal(&tb, m.delivery_time orelse m.submit_time),
        1 => fmtLocal(&tb, m.modified_time),
        2 => m.from,
        3 => m.to,
        4 => if (m.subject.len > 0) m.subject else "(no subject)",
        5 => if (m.size) |sz| std.fmt.bufPrint(&tb, "{d} KB", .{@divTrunc(sz + 1023, 1024)}) catch "" else "",
        6 => m.message_class,
        8 => m.note,
        else => "",
    };
    di.item.pszText = toW(&app.wbuf, s);
}

fn selectedRows(a: Allocator) []u32 {
    var out: std.ArrayList(u32) = .empty;
    var i: isize = -1;
    while (true) {
        const r = w.SendMessageW(app.list.?, w.LVM_GETNEXTITEM, @bitCast(i), w.LVNI_SELECTED);
        if (r < 0) break;
        out.append(a, app.view.items[@intCast(r)]) catch break;
        i = r;
    }
    return out.toOwnedSlice(a) catch &.{};
}

fn focusedRow() ?u32 {
    const r = w.SendMessageW(app.list.?, w.LVM_GETNEXTITEM, @bitCast(@as(isize, -1)), w.LVNI_FOCUSED);
    if (r < 0 or r >= app.view.items.len) return null;
    return app.view.items[@intCast(r)];
}

// ================================================================ preview

fn showPreview() void {
    const mi = focusedRow() orelse return;
    reading_nid = app.msgs[mi].nid;
    defer reading_nid = 0;
    _ = app.preview_arena.reset(.retain_capacity);
    const a = app.preview_arena.allocator();
    const text = buildPreview(a, app.msgs[mi].nid) catch |e| std.fmt.allocPrint(a, "Error reading message: {s}", .{@errorName(e)}) catch "error";
    setRich(a, app.preview.?, text);
    setPreviewEmpty(false);
}

/// Put syntax-coloured text into a Rich Edit control.
fn setRich(a: Allocator, h: w.HWND, text: []const u8) void {
    const doc = rtf.colorize(a, text, "Consolas", 19);
    const z = a.dupeSentinel(u8, doc, 0) catch return;
    var st: w.SETTEXTEX = .{};
    _ = w.SendMessageW(h, w.EM_SETTEXTEX, @intFromPtr(&st), @intCast(@intFromPtr(z.ptr)));
}

/// Header analysis for one message; uses the folder's organisation directory when it has been built.
fn headerAnalysisText(a: Allocator, m: *const pst.Message) []const u8 {
    const ctx: hdrs.Context = app.mailbox_ctx orelse if (app.index) |ix| ix.ctx else .{};
    const an = hdrs.analyse(a, hdrs.inputFromMessage(a, m), ctx);
    const txt = hdrs.reportText(a, an, fmtLocalLong);
    if (app.mailbox_ctx == null and an.has_headers)
        return std.fmt.allocPrint(a, "{s}  (Tools > Analyse headers in this folder adds internal-name impersonation checks.)\n", .{txt}) catch txt;
    return txt;
}

fn buildPreview(a: Allocator, nid: u32) ![]u8 {
    const m = try app.file.?.loadMessage(a, nid);
    var out: std.ArrayList(u8) = .empty;
    var tb: [64]u8 = undefined;
    var tb2: [64]u8 = undefined;
    try out.print(a, "Subject:   {s}\n", .{try m.subject(a)});
    try out.print(a, "From:      {s} <{s}>\n", .{ try m.senderName(a), try m.senderEmail(a) });
    inline for (.{ .{ 1, "To:        " }, .{ 2, "Cc:        " }, .{ 3, "Bcc:       " } }) |kv| {
        var first = true;
        for (m.recipients) |r| {
            if (r.kind != kv[0]) continue;
            try out.appendSlice(a, if (first) kv[1] else "; ");
            first = false;
            try out.print(a, "{s} <{s}>", .{ r.name, r.email });
        }
        if (!first) try out.append(a, '\n');
    }
    inline for (.{ .{ pst.Tag.delivery_time, "Received:  " }, .{ pst.Tag.client_submit_time, "Sent:      " }, .{ pst.Tag.creation_time, "Created:   " }, .{ pst.Tag.last_modified, "Modified:  " } }) |kv| {
        if (m.pc.time(kv[0])) |t| try out.print(a, "{s}{s} local  ({s} UTC)\n", .{ kv[1], fmtLocal(&tb, t), pst.fmtTime(&tb2, t, 0) });
    }
    try out.print(a, "Class:     {s}\n", .{try m.pc.string(a, pst.Tag.message_class)});
    for (itemview.rows(a, &m, fmtLocalLong)) |row| {
        const label = try std.fmt.allocPrint(a, "{s}:", .{row.label});
        try out.print(a, "{s: <10} {s}\n", .{ label, row.value });
    }
    const mid = try m.pc.string(a, pst.Tag.internet_message_id);
    if (mid.len > 0) try out.print(a, "Msg-ID:    {s}\n", .{mid});
    try out.print(a, "PST NID:   0x{x:0>8}\n", .{m.nid});
    if (m.attachments.len > 0) {
        try out.appendSlice(a, "Attach:    ");
        for (m.attachments, 0..) |att, i| {
            if (i > 0) try out.appendSlice(a, "; ");
            try out.print(a, "{s} ({d} KB)", .{ if (att.filename.len > 0) att.filename else "(embedded item)", @divTrunc(att.size + 1023, 1024) });
        }
        try out.append(a, '\n');
    }
    try out.append(a, '\n');
    try out.appendSlice(a, headerAnalysisText(a, &m));
    try out.appendSlice(a, "\n----------------------------------------------------------------------\n\n");
    var body = try m.bodyText(a);
    if (body.len == 0) {
        const html = try m.bodyHtmlUtf8(a);
        if (html.len > 0) body = try htmlToText(a, html);
    }
    try out.appendSlice(a, body);
    const raw_hdrs = try m.pc.string(a, pst.Tag.transport_headers);
    if (raw_hdrs.len > 0) {
        try out.appendSlice(a, "\n\n---------------------------- Internet headers ----------------------------\n");
        try out.appendSlice(a, raw_hdrs);
    }
    return out.toOwnedSlice(a);
}

// ================================================================ export & reports

/// SHA-256 of the source (cached): one hash, or "path: hash; ..." for multi-file sources (MBOX folders).
fn pstSha256() []const u8 {
    if (app.sha_hex == null) {
        setStatus("Computing SHA-256 of source file(s)...", .{});
        const a = app.file_arena.allocator();
        const files = app.file.?.sourceFiles(a, app.file_path) catch return "";
        if (files.len == 1) {
            const h = store.Store.sha256File(app.gpa, app.io, files[0].path) catch return "";
            app.sha_hex = a.dupe(u8, &h) catch return "";
        } else {
            var out: std.ArrayList(u8) = .empty;
            for (files) |sf| {
                const h = store.Store.sha256File(app.gpa, app.io, sf.path) catch continue;
                out.print(a, "{s}: {s}; ", .{ sf.path, &h }) catch {};
            }
            app.sha_hex = out.items;
        }
    }
    return app.sha_hex.?;
}

const ExportKind = enum { msg, eml, none };

fn exportSelected(kind: ExportKind) void {
    if (app.file == null) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var rows_idx = selectedRows(a);
    if (rows_idx.len == 0) {
        if (kind == .none) {
            rows_idx = a.dupe(u32, app.view.items) catch return; // whole (filtered) folder
        } else {
            _ = msgBox("Select one or more messages first (Ctrl+A selects all).", "pstview", w.MB_ICONINFORMATION);
            return;
        }
    }
    const dir = pickFolder(a, switch (kind) {
        .msg => "Export selected items as .msg to:",
        .eml => "Export selected items as .eml to:",
        .none => "Write report (HTML + CSV) to:",
    }) orelse return;

    waitCursor(true);
    defer waitCursor(false);
    const sha = pstSha256();
    var rows: std.ArrayList(exp.ReportRow) = .empty;
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
            var al: std.ArrayList(u8) = .empty;
            for (m.attachments, 0..) |att, i| {
                if (i > 0) al.appendSlice(a, "; ") catch {};
                al.appendSlice(a, if (att.filename.len > 0) att.filename else "(embedded item)") catch {};
            }
            atts = al.items;
            if (kind != .none) {
                var tb: [64]u8 = undefined;
                const t = s.delivery_time orelse s.submit_time orelse s.modified_time;
                var prefix_buf: [96]u8 = undefined;
                const ts = fmtLocal(&tb, t);
                const prefix = std.fmt.bufPrint(&prefix_buf, "{d:0>4} {s}", .{ n + 1, if (ts.len >= 16) ts[0..16] else ts }) catch "";
                const pfx: []u8 = a.dupe(u8, prefix) catch &.{};
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
        rows.append(a, .{
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
        if (n % 20 == 0) setStatus("Exporting {d}/{d}...", .{ n + 1, rows_idx.len });
    }
    // report
    const now: i64 = std.Io.Clock.real.now(app.io).toSeconds();
    const off = w.localOffset(now);
    const tz_label = std.fmt.allocPrint(a, "local time (UTC{s}{d}:{d:0>2} at report time; daylight saving applied for each date)", .{ if (off >= 0) "+" else "-", @divTrunc(@abs(off), 3600), @divTrunc(@mod(@abs(off), 3600), 60) }) catch "local time";
    const fpath = if (app.cur_folder) |c| app.folders.items[c].path else "";
    var fmt_buf: [128]u8 = undefined;
    const meta: exp.ReportMeta = .{
        .pst_path = app.file_path,
        .pst_size = app.file.?.totalSize(),
        .format = app.file.?.describe(&fmt_buf),
        .sha256_hex = sha,
        .generated_utc = now,
        .tz_label = tz_label,
        .tz_offset = off,
        .offset_at = &w.localOffset,
        .title = std.fmt.allocPrint(a, "Export report - {s}", .{fpath}) catch "Export report",
    };
    // Report times use each item's own DST-correct local offset via a per-row conversion.
    for (rows.items) |*r| {
        _ = r;
    }
    const csv = exp.reportCsv(a, rows.items, meta) catch "";
    const html = exp.reportHtml(a, rows.items, meta) catch "";
    writeFile(a, dir, "pstview report.csv", csv) catch {};
    writeFile(a, dir, "pstview report.html", html) catch {};

    var b: [512]u8 = undefined;
    const summary = if (kind == .none)
        std.fmt.bufPrint(&b, "Report of {d} items written to:\n{s}", .{ rows.items.len, dir }) catch ""
    else
        std.fmt.bufPrint(&b, "Exported {d} item(s), {d} failed.\nReport written alongside.\n\n{s}", .{ ok, failed, dir }) catch "";
    setStatus("{s}", .{summary});
    _ = msgBox(summary, "pstview", w.MB_ICONINFORMATION);
    const dw = toWAlloc(a, dir) catch return;
    _ = w.ShellExecuteW(app.hwnd, L("open"), dw, null, null, w.SW_SHOW);
}

fn saveAttachments() void {
    const mi = focusedRow() orelse {
        _ = msgBox("Select a message first.", "pstview", w.MB_ICONINFORMATION);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const m = app.file.?.loadMessage(a, app.msgs[mi].nid) catch return;
    if (m.attachments.len == 0) {
        _ = msgBox("This message has no attachments.", "pstview", w.MB_ICONINFORMATION);
        return;
    }
    const dir = pickFolder(a, "Save attachments to:") orelse return;
    var saved: usize = 0;
    for (m.attachments, 0..) |*att, i| {
        var pb: [16]u8 = undefined;
        const pfx = std.fmt.bufPrint(&pb, "{d:0>2}", .{i + 1}) catch "";
        if (att.method == 5) {
            if (pst.embeddedMessage(a, att) catch null) |inner_c| {
                var inner = inner_c;
                const data = exp.buildMsg(a, &inner) catch continue;
                const name = exp.safeName(a, pfx, if (att.filename.len > 0) att.filename else (inner.subject(a) catch "embedded"), "msg") catch continue;
                writeFile(a, dir, name, data) catch continue;
                saved += 1;
            }
            continue;
        }
        const fname = if (att.filename.len > 0) att.filename else "attachment.bin";
        const dot = std.mem.lastIndexOfScalar(u8, fname, '.');
        const stem = if (dot) |d| fname[0..d] else fname;
        const ext = if (dot) |d| fname[d + 1 ..] else "bin";
        const name = exp.safeName(a, pfx, stem, ext) catch continue;
        writeFile(a, dir, name, att.data()) catch continue;
        saved += 1;
    }
    var b: [256]u8 = undefined;
    _ = msgBox(std.fmt.bufPrint(&b, "Saved {d} of {d} attachment(s).", .{ saved, m.attachments.len }) catch "", "pstview", w.MB_ICONINFORMATION);
}

// ================================================================ window

fn sc(v: i32) i32 {
    return @intFromFloat(@as(f32, @floatFromInt(v)) * app.scale);
}

/// Pane geometry of the main window (client coordinates), shared by layout and painting.
const Geo = struct {
    W: i32,
    H: i32,
    /// Right edge of the left pane; a hairline is drawn here.
    sx: i32,
    /// Height of the left-pane header (source name and description).
    head_h: i32,
    search: w.RECT,
    list: w.RECT,
    preview: w.RECT,
};

fn geometry() Geo {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(app.hwnd.?, &rc);
    var src: w.RECT = undefined;
    _ = w.GetWindowRect(app.status.?, &src);
    const W = rc.right;
    const H = rc.bottom - (src.bottom - src.top);
    const sx = std.math.clamp(app.split_x, sc(180), @max(sc(180), W - sc(360)));
    const rx = sx + sc(4); // splitter grab zone: hairline at sx, then white
    const bar_h = sc(52);
    const avail = @max(H - bar_h - sc(5), sc(10));
    const want: i32 = @intFromFloat(@as(f32, @floatFromInt(avail)) * app.split_y_frac);
    const list_h = std.math.clamp(want, @min(sc(90), avail), @max(@min(sc(90), avail), avail - sc(90)));
    return .{
        .W = W,
        .H = H,
        .sx = sx,
        .head_h = sc(66),
        .search = .{ .left = rx, .top = 0, .right = W, .bottom = bar_h },
        .list = .{ .left = rx, .top = bar_h, .right = W, .bottom = bar_h + list_h },
        .preview = .{ .left = rx, .top = bar_h + list_h + sc(5), .right = W, .bottom = H },
    };
}

/// The rounded search field painted in the search bar; the borderless EDIT sits inside it.
fn searchPill(g: Geo) w.RECT {
    return .{ .left = g.search.left + sc(10), .top = g.search.top + sc(10), .right = g.search.right - sc(14), .bottom = g.search.bottom - sc(10) };
}

fn moveTo(h: ?w.HWND, r: w.RECT) void {
    _ = w.MoveWindow(h.?, r.left, r.top, r.right - r.left, r.bottom - r.top, 1);
}

fn layout() void {
    if (app.hwnd == null or app.status == null or app.tree == null) return;
    _ = w.SendMessageW(app.status.?, w.WM_SIZE, 0, 0);
    statusParts();
    const g = geometry();
    if (ui.welcome.hwnd) |h| _ = w.MoveWindow(h, 0, 0, g.W, g.H, 1);
    _ = w.MoveWindow(app.tree.?, 0, g.head_h, g.sx, g.H - g.head_h, 1);
    const pill = searchPill(g);
    const eh = sc(20);
    _ = w.MoveWindow(app.search.?, pill.left + sc(36), @divTrunc(pill.top + pill.bottom - eh, 2), pill.right - pill.left - sc(48), eh, 1);
    moveTo(app.list, g.list);
    moveTo(app.preview, g.preview);
    // generous margins inside the reading pane
    var pr: w.RECT = .{ .left = sc(24), .top = sc(14), .right = g.preview.right - g.preview.left - sc(24), .bottom = g.preview.bottom - g.preview.top - sc(6) };
    _ = w.SendMessageW(app.preview.?, w.EM_SETRECT, 0, @intCast(@intFromPtr(&pr)));
    _ = w.InvalidateRect(app.hwnd.?, null, 0);
}

fn fillRect(dc: w.HDC, r: w.RECT, brush: ?w.HBRUSH) void {
    _ = w.FillRect(dc, &r, brush);
}

fn paintText(dc: w.HDC, font: ?w.HFONT, color: u32, text: []const u8, r: w.RECT, flags: u32) void {
    var wb: [600]u16 = undefined;
    const p = toW(&wb, text);
    var rr = r;
    if (font) |f| _ = w.SelectObject(dc, @ptrCast(f));
    _ = w.SetTextColor(dc, w.rgb(color));
    _ = w.DrawTextW(dc, p, @intCast(std.mem.len(p)), &rr, flags | w.DT_NOPREFIX);
}

/// The chrome between the panes: left-pane header, search field, hairlines and the empty-preview hint.
fn paintMain(dc: w.HDC) void {
    if (app.file == null) return; // the welcome screen covers the client area
    const g = geometry();
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    // left-pane header: what is open
    fillRect(dc, .{ .left = 0, .top = 0, .right = g.sx, .bottom = g.head_h }, app.pane_brush);
    const tx = sc(18);
    paintText(dc, app.bold, ui.ink, app.source_name, .{ .left = tx, .top = sc(14), .right = g.sx - sc(12), .bottom = sc(36) }, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);
    paintText(dc, app.font, ui.muted, app.source_desc, .{ .left = tx, .top = sc(37), .right = g.sx - sc(12), .bottom = sc(58) }, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);
    // splitter: hairline, then white up to the right-hand panes
    fillRect(dc, .{ .left = g.sx, .top = 0, .right = g.sx + 1, .bottom = g.H }, app.hairline_brush);
    fillRect(dc, .{ .left = g.sx + 1, .top = 0, .right = g.search.left, .bottom = g.H }, app.white_brush);
    // search bar with a rounded field
    fillRect(dc, g.search, app.white_brush);
    const pill = searchPill(g);
    if (w.CreatePen(w.PS_SOLID, 1, w.rgb(ui.hairline))) |pen| {
        const op = w.SelectObject(dc, @ptrCast(pen));
        const ob = w.SelectObject(dc, @ptrCast(app.pane_brush));
        _ = w.RoundRect(dc, pill.left, pill.top, pill.right, pill.bottom, sc(8), sc(8));
        _ = w.SelectObject(dc, ob);
        _ = w.SelectObject(dc, op);
        _ = w.DeleteObject(@ptrCast(pen));
    }
    if (app.glyph_font) |gf| {
        _ = w.SelectObject(dc, @ptrCast(gf));
        _ = w.SetTextColor(dc, w.rgb(ui.muted));
        var gr: w.RECT = .{ .left = pill.left + sc(10), .top = pill.top, .right = pill.left + sc(32), .bottom = pill.bottom };
        const mag = [1]u16{0xE721};
        _ = w.DrawTextW(dc, &mag, 1, &gr, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_NOPREFIX);
    }
    // list | reading pane
    fillRect(dc, .{ .left = g.list.left, .top = g.list.bottom, .right = g.W, .bottom = g.preview.top }, app.white_brush);
    fillRect(dc, .{ .left = g.list.left, .top = g.list.bottom, .right = g.W, .bottom = g.list.bottom + 1 }, app.hairline_brush);
    if (app.preview_empty) {
        fillRect(dc, g.preview, app.white_brush);
        paintText(dc, app.font, ui.muted, if (app.view.items.len > 0) "Select a message to read it." else "", g.preview, w.DT_SINGLELINE | w.DT_CENTER | w.DT_VCENTER);
    }
}

/// Splitter under the cursor: vertical (tree | messages) or horizontal (list | reading pane).
fn splitterAt(x: i32, y: i32) enum { none, vertical, horizontal } {
    if (app.file == null) return .none;
    const g = geometry();
    if (x >= g.sx - sc(2) and x <= g.search.left + sc(1) and y < g.H) return .vertical;
    if (x > g.search.left and y >= g.list.bottom - sc(2) and y <= g.preview.top + sc(1)) return .horizontal;
    return .none;
}

fn createChildren(hwnd: w.HWND) void {
    app.scale = @as(f32, @floatFromInt(w.GetDpiForWindow(hwnd))) / 96.0;
    app.split_x = sc(290);
    app.font = w.CreateFontW(-sc(14), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    app.bold = w.CreateFontW(-sc(15), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI Semibold"));
    const font = app.font;
    const mono = w.CreateFontW(-sc(13), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Consolas"));
    app.mono = mono;
    if (w.GetDC(null)) |sdc| {
        app.glyph_font = ui.iconFont(sdc, -sc(14));
        _ = w.ReleaseDC(null, sdc);
    }
    app.pane_brush = w.CreateSolidBrush(w.rgb(ui.pane));
    app.white_brush = w.CreateSolidBrush(w.rgb(ui.white));
    app.hairline_brush = w.CreateSolidBrush(w.rgb(ui.hairline));


    app.tree = w.CreateWindowExW(0, L("SysTreeView32"), null, w.WS_CHILD | w.WS_TABSTOP | w.TVS_HASBUTTONS | w.TVS_LINESATROOT | w.TVS_SHOWSELALWAYS | w.TVS_FULLROWSELECT, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_TREE), app.hinst, null);
    app.search = w.CreateWindowExW(0, L("EDIT"), null, w.WS_CHILD | w.WS_TABSTOP | w.ES_AUTOHSCROLL, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_SEARCH), app.hinst, null);
    app.list = w.CreateWindowExW(0, L("SysListView32"), null, w.WS_CHILD | w.WS_TABSTOP | w.LVS_REPORT | w.LVS_SHOWSELALWAYS | w.LVS_OWNERDATA, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_LIST), app.hinst, null);
    app.preview = w.CreateWindowExW(0, L(w.RICHEDIT_CLASS), null, w.WS_CHILD | w.WS_TABSTOP | w.WS_VSCROLL | w.ES_MULTILINE | w.ES_READONLY | w.ES_AUTOVSCROLL | w.ES_NOHIDESEL, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_PREVIEW), app.hinst, null);
    app.status = w.CreateWindowExW(0, L("msctls_statusbar32"), null, w.WS_CHILD | w.WS_VISIBLE, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_STATUS), app.hinst, null);
    _ = w.SetWindowTheme(app.status.?, L(""), L("")); // unthemed: takes the palette's background colour
    _ = w.SetWindowSubclass(app.list.?, ui.listSubclass, 1, 0);

    inline for (.{ app.tree, app.search, app.list, app.status }) |h| _ = w.SendMessageW(h.?, w.WM_SETFONT, @intFromPtr(font), 1);
    _ = w.SendMessageW(app.preview.?, w.WM_SETFONT, @intFromPtr(mono), 1);
    _ = w.SendMessageW(app.preview.?, w.EM_EXLIMITTEXT, 0, 0x7FFFFFFE);
    _ = w.SendMessageW(app.search.?, w.EM_SETCUEBANNER, 1, @intCast(@intFromPtr(L("Search    from:   to:   subject:   risk:high    * ? wildcards, \"phrases\"").ptr)));

    // folder tree: Explorer style, glyph icons, airy rows on the pane colour
    _ = w.SetWindowTheme(app.tree.?, L("Explorer"), null);
    _ = w.SendMessageW(app.tree.?, w.TVM_SETEXTENDEDSTYLE, w.TVS_EX_DOUBLEBUFFER | w.TVS_EX_FADEINOUTEXPANDOS, w.TVS_EX_DOUBLEBUFFER | w.TVS_EX_FADEINOUTEXPANDOS);
    _ = w.SendMessageW(app.tree.?, w.TVM_SETBKCOLOR, 0, @intCast(w.rgb(ui.pane)));
    _ = w.SendMessageW(app.tree.?, w.TVM_SETTEXTCOLOR, 0, @intCast(w.rgb(ui.ink)));
    _ = w.SendMessageW(app.tree.?, w.TVM_SETITEMHEIGHT, @intCast(sc(30)), 0);
    if (ui.glyphList(sc(16))) |il| _ = w.SendMessageW(app.tree.?, w.TVM_SETIMAGELIST, 0, @bitCast(@intFromPtr(il)));

    // message list: Explorer style, no grid, taller rows (a 1-pixel-wide image list sets the height)
    _ = w.SetWindowTheme(app.list.?, L("Explorer"), null);
    _ = w.SendMessageW(app.list.?, w.LVM_SETEXTENDEDLISTVIEWSTYLE, 0, @intCast(w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER));
    _ = w.SendMessageW(app.list.?, w.LVM_SETTEXTCOLOR, 0, @intCast(w.rgb(ui.ink)));
    if (w.ImageList_Create(1, sc(30), w.ILC_COLOR32, 1, 0)) |il| _ = w.SendMessageW(app.list.?, w.LVM_SETIMAGELIST, w.LVSIL_SMALL, @bitCast(@intFromPtr(il)));
    for (columns, 0..) |c, i| {
        var col: w.LVCOLUMNW = .{ .mask = w.LVCF_TEXT | w.LVCF_WIDTH | w.LVCF_FMT | w.LVCF_SUBITEM, .cx = sc(c.width), .pszText = c.title, .iSubItem = @intCast(i), .fmt = if (c.right) w.LVCFMT_RIGHT else 0 };
        _ = w.SendMessageW(app.list.?, w.LVM_INSERTCOLUMNW, i, @intCast(@intFromPtr(&col)));
    }

    const menu = w.CreateMenu().?;
    const file = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_OPEN, L("&Open PST / OST / MBOX file...\tCtrl+O"));
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_OPEN_FOLDER, L("Open MBOX &folder (Thunderbird / Apple Mail)..."));
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_CLOSE, L("&Close mailbox"));
    _ = w.AppendMenuW(file, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_EXPORT_MSG, L("Export selected as .&msg..."));
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_EXPORT_EML, L("Export selected as .&eml..."));
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_SAVE_ATT, L("Save &attachments of message..."));
    _ = w.AppendMenuW(file, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_REPORT, L("&Report (HTML + CSV) of selection / folder..."));
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_HASH, L("Show SHA-256 of source file"));
    _ = w.AppendMenuW(file, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(file, w.MF_STRING, CMD_EXIT, L("E&xit"));
    const edit = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(edit, w.MF_STRING, CMD_OPEN_MSG, L("&Open message\tEnter / double-click"));
    _ = w.AppendMenuW(edit, w.MF_STRING, CMD_SAFE_HTML, L("View &HTML (safe)\tCtrl+H"));
    _ = w.AppendMenuW(edit, w.MF_STRING, CMD_HDR_REPORT, L("Header analysis &report\tCtrl+I"));
    _ = w.AppendMenuW(edit, w.MF_STRING, CMD_PROPS, L("All &properties (MAPI, incl. named)"));
    _ = w.AppendMenuW(edit, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(edit, w.MF_STRING, CMD_SELECT_ALL, L("Select &all\tCtrl+A"));
    const view = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(view, w.MF_STRING, CMD_THEME_SYSTEM, L("Theme: follow &Windows"));
    _ = w.AppendMenuW(view, w.MF_STRING, CMD_THEME_LIGHT, L("Theme: &light"));
    _ = w.AppendMenuW(view, w.MF_STRING, CMD_THEME_DARK, L("Theme: &dark"));
    app.view_menu = view;
    const tools = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_ANALYSE, L("&Analyse headers in this folder (risk, spoofing)\tCtrl+R"));
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_HDR_REPORT, L("Header analysis &report for selected message\tCtrl+I"));
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_HDR_CLIP, L("Analyse headers from &clipboard (paste)"));
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_HDR_FILE, L("Analyse headers from .eml / .txt &file..."));
    _ = w.AppendMenuW(tools, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_RECOVER, L("&Recover deleted items (scan the whole file)..."));
    _ = w.AppendMenuW(tools, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_INTEGRITY, L("&Integrity log"));
    _ = w.AppendMenuW(tools, w.MF_STRING, CMD_VERIFY, L("&Verify every block (checksums)..."));
    const help = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(help, w.MF_STRING, CMD_INSTALL, L("&Install pstview for this user..."));
    _ = w.AppendMenuW(help, w.MF_STRING, CMD_DEFAULT_APPS, L("Choose &default apps for mailbox files..."));
    _ = w.AppendMenuW(help, w.MF_STRING, CMD_UNINSTALL, L("&Uninstall pstview..."));
    _ = w.AppendMenuW(help, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(help, w.MF_STRING, CMD_ABOUT, L("&About pstview"));
    app.help_menu = help;
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(file), L("&File"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(edit), L("&Message"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(view), L("&View"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(tools), L("&Tools"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(help), L("&Help"));
    _ = w.SetMenu(hwnd, menu);

    ui.createWelcome(hwnd, app.hinst, app.scale, "v" ++ build_options.version, .{ CMD_OPEN, CMD_OPEN_FOLDER, CMD_INSTALL });
    applyTheme();
    if (ui.welcome.hwnd) |h| _ = w.ShowWindow(h, w.SW_SHOW);
    w.DragAcceptFiles(hwnd, 1);
}

/// Ink title bar with paper text (Windows 11; ignored elsewhere).
fn inkCaption(hwnd: w.HWND) void {
    const cap = w.rgb(ui.bar);
    const cap_text = w.rgb(ui.on_bar);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_CAPTION_COLOR, &cap, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_BORDER_COLOR, &cap, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_TEXT_COLOR, &cap_text, 4);
}

/// Put the main window in the light or dark theme: palette, brushes, the controls' colours and
/// visual styles, menu bar and the text already shown. Message windows take the theme when opened.
fn applyTheme() void {
    const dark = switch (app.theme) {
        .system => ui.systemDark(),
        .light => false,
        .dark => true,
    };
    ui.setDark(dark);
    rtf.dark = dark;
    ui.menu_font = app.font;
    inline for (.{ &app.pane_brush, &app.white_brush, &app.hairline_brush }) |b| if (b.*) |h| {
        _ = w.DeleteObject(@ptrCast(h));
    };
    app.pane_brush = w.CreateSolidBrush(w.rgb(ui.pane));
    app.white_brush = w.CreateSolidBrush(w.rgb(ui.white));
    app.hairline_brush = w.CreateSolidBrush(w.rgb(ui.hairline));
    const hwnd = app.hwnd.?;
    inkCaption(hwnd);

    const tree = app.tree.?;
    ui.themeControl(tree, L("Explorer"));
    _ = w.SendMessageW(tree, w.TVM_SETBKCOLOR, 0, @intCast(w.rgb(ui.pane)));
    _ = w.SendMessageW(tree, w.TVM_SETTEXTCOLOR, 0, @intCast(w.rgb(ui.ink)));
    if (ui.glyphList(sc(16))) |il| _ = w.SendMessageW(tree, w.TVM_SETIMAGELIST, 0, @bitCast(@intFromPtr(il)));

    const list = app.list.?;
    ui.themeControl(list, L("Explorer"));
    _ = w.SendMessageW(list, w.LVM_SETBKCOLOR, 0, @intCast(w.rgb(ui.white)));
    _ = w.SendMessageW(list, w.LVM_SETTEXTBKCOLOR, 0, @intCast(w.rgb(ui.white)));
    _ = w.SendMessageW(list, w.LVM_SETTEXTCOLOR, 0, @intCast(w.rgb(ui.ink)));
    const header: usize = @bitCast(w.SendMessageW(list, w.LVM_GETHEADER, 0, 0));
    if (header != 0) ui.themeHeader(@ptrFromInt(header));

    _ = w.SendMessageW(app.preview.?, w.EM_SETBKGNDCOLOR, 0, @intCast(w.rgb(ui.white)));
    ui.themeControl(app.preview.?, null);
    _ = w.SendMessageW(app.status.?, w.SB_SETBKCOLOR, 0, @intCast(w.rgb(ui.pane)));
    ui.retheme();

    if (app.view_menu) |m| _ = w.CheckMenuRadioItem(m, CMD_THEME_SYSTEM, CMD_THEME_DARK, CMD_THEME_SYSTEM + @as(u32, @intFromEnum(app.theme)), 0);
    _ = w.DrawMenuBar(hwnd);
    _ = w.RedrawWindow(hwnd, null, null, 0x1 | 0x4 | 0x80 | 0x400); // INVALIDATE | ERASE | ALLCHILDREN | FRAME
    if (!app.preview_empty) showPreview(); // the text's colours belong to the theme
}

fn popupAt(hwnd: w.HWND, items: []const struct { id: usize, text: [:0]const u16 }) usize {
    const m = w.CreatePopupMenu() orelse return 0;
    defer _ = w.DestroyMenu(m);
    for (items) |it| {
        if (it.id == 0) _ = w.AppendMenuW(m, w.MF_SEPARATOR, 0, null) else _ = w.AppendMenuW(m, w.MF_STRING, it.id, it.text);
    }
    var pt: w.POINT = undefined;
    _ = w.GetCursorPos(&pt);
    const r = w.TrackPopupMenu(m, w.TPM_RIGHTBUTTON | w.TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, null);
    return @intCast(@max(r, 0));
}

fn listContextMenu() void {
    if (app.file == null or app.view.items.len == 0) return;
    const n_sel = w.SendMessageW(app.list.?, w.LVM_GETSELECTEDCOUNT, 0, 0);
    const cmd = popupAt(app.hwnd.?, &.{
        .{ .id = CMD_OPEN_MSG, .text = L("&Open message") },
        .{ .id = CMD_SAFE_HTML, .text = L("View &HTML (safe)") },
        .{ .id = CMD_HDR_REPORT, .text = L("Header analysis &report") },
        .{ .id = CMD_PROPS, .text = L("All &properties (MAPI)") },
        .{ .id = 0, .text = L("") },
        .{ .id = CMD_EXPORT_MSG, .text = if (n_sel > 1) L("Export selected as .&msg...") else L("Export as .&msg...") },
        .{ .id = CMD_EXPORT_EML, .text = if (n_sel > 1) L("Export selected as .&eml...") else L("Export as .&eml...") },
        .{ .id = CMD_SAVE_ATT, .text = L("Save &attachments...") },
        .{ .id = 0, .text = L("") },
        .{ .id = CMD_REPORT, .text = L("&Report (HTML + CSV) of selection...") },
        .{ .id = CMD_SELECT_ALL, .text = L("Select a&ll") },
    });
    if (cmd != 0) onCommand(@intCast(cmd), 0);
}

// ================================================================ safe HTML view

fn fmtLocalLong(buf: []u8, t: ?i64) []const u8 {
    const v = t orelse return "";
    const off = w.localOffset(v);
    var tb: [32]u8 = undefined;
    const base = pst.fmtTime(&tb, v, off);
    return std.fmt.bufPrint(buf, "{s} (UTC{s}{d:0>2}:{d:0>2})", .{ base, if (off >= 0) "+" else "-", @divTrunc(@abs(off), 3600), @divTrunc(@mod(@abs(off), 3600), 60) }) catch base;
}

fn tempDir(a: Allocator) ![]u8 {
    var buf: [600]u16 = undefined;
    const n = w.GetTempPathW(buf.len, &buf);
    const base = try std.unicode.utf16LeToUtf8Alloc(a, buf[0..n]);
    const dir = try std.fmt.allocPrint(a, "{s}pstview", .{base});
    Io.Dir.cwd().createDirPath(app.io, dir) catch {};
    return dir;
}

/// Show the HTML file `full` in pstview's own viewer window (WebView2, part of Windows). Without
/// a WebView2 runtime the page opens in the default browser. Returns true for the in-app viewer.
fn openHtml(a: Allocator, full: []const u8, title: []const u8) bool {
    const fw = toWAlloc(a, full) catch return false;
    in_app: {
        const dir = tempDir(a) catch break :in_app;
        const data = toWAlloc(a, std.fmt.allocPrint(a, "{s}\\webview", .{dir}) catch break :in_app) catch break :in_app;
        const tw = toWAlloc(a, std.fmt.allocPrint(a, "{s} - pstview", .{if (title.len > 0) title else "(no subject)"}) catch break :in_app) catch break :in_app;
        webview2.setCaptionColors(w.rgb(ui.bar), w.rgb(ui.on_bar));
        if (webview2.show(app.gpa, app.hinst, tw, full, data, sc(1100), sc(820))) return true;
    }
    _ = w.ShellExecuteW(app.hwnd, L("open"), fw, null, null, w.SW_SHOW);
    return false;
}

/// Render the message as a sanitised, self-contained HTML page (scripts and network blocked by CSP)
/// and show it in the viewer window.
fn viewSafeHtml(nid: u32) void {
    reading_nid = nid;
    defer reading_nid = 0;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    waitCursor(true);
    defer waitCursor(false);
    const m = app.file.?.loadMessage(a, nid) catch |e| {
        _ = msgBox(@errorName(e), "Cannot read message", w.MB_ICONERROR);
        return;
    };
    const doc = render.messageDocument(a, &m, fmtLocalLong) catch |e| {
        _ = msgBox(@errorName(e), "Cannot render message", w.MB_ICONERROR);
        return;
    };
    const dir = tempDir(a) catch return;
    var pb: [24]u8 = undefined;
    const name = exp.safeName(a, std.fmt.bufPrint(&pb, "{x:0>8}", .{nid}) catch "", m.subject(a) catch "", "html") catch return;
    writeFile(a, dir, name, doc) catch |e| {
        _ = msgBox(@errorName(e), "Cannot write temp file", w.MB_ICONERROR);
        return;
    };
    const full = std.fmt.allocPrint(app.gpa, "{s}\\{s}", .{ dir, name }) catch return;
    app.temp_files.append(app.gpa, full) catch {};
    _ = openHtml(a, full, m.subject(a) catch "");
    setStatus("Safe HTML view opened (scripts and remote content blocked). Temp file is deleted when pstview closes.", .{});
}

// ================================================================ header analysis reports

/// Write a header-analysis report to a temp file and open it in the browser.
fn openHeaderReport(a: Allocator, an: hdrs.Analysis, source: []const u8, tag: []const u8) void {
    const doc = hreport.html(a, an, source, fmtLocalLong) catch |e| {
        _ = msgBox(@errorName(e), "Cannot build header report", w.MB_ICONERROR);
        return;
    };
    const dir = tempDir(a) catch return;
    const name = exp.safeName(a, tag, if (an.subject.len > 0) an.subject else "headers", "html") catch return;
    writeFile(a, dir, name, doc) catch |e| {
        _ = msgBox(@errorName(e), "Cannot write temp file", w.MB_ICONERROR);
        return;
    };
    const full = std.fmt.allocPrint(app.gpa, "{s}\\{s}", .{ dir, name }) catch return;
    app.temp_files.append(app.gpa, full) catch {};
    _ = openHtml(a, full, "Header analysis");
    setStatus("Header analysis: {s}. Report made offline; temp file is deleted when pstview closes.", .{an.summary()});
}

/// Every MAPI property of the item (message, recipients, attachments) as an HTML page.
fn showAllProperties(nid: u32) void {
    reading_nid = nid;
    defer reading_nid = 0;
    if (app.file == null) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    waitCursor(true);
    defer waitCursor(false);
    const m = app.file.?.loadMessage(a, nid) catch |e| {
        _ = msgBox(@errorName(e), "Cannot read message", w.MB_ICONERROR);
        return;
    };
    const doc = @import("propview.zig").html(a, &m, app.file_path, fmtLocalLong);
    const dir = tempDir(a) catch return;
    var pb: [24]u8 = undefined;
    const name = exp.safeName(a, std.fmt.bufPrint(&pb, "props-{x:0>8}", .{nid}) catch "props", m.subject(a) catch "item", "html") catch return;
    writeFile(a, dir, name, doc) catch |e| {
        _ = msgBox(@errorName(e), "Cannot write temp file", w.MB_ICONERROR);
        return;
    };
    const full = std.fmt.allocPrint(app.gpa, "{s}\\{s}", .{ dir, name }) catch return;
    app.temp_files.append(app.gpa, full) catch {};
    _ = openHtml(a, full, "All properties");
    setStatus("All properties of item 0x{x:0>8} opened (temp file deleted when pstview closes).", .{nid});
}

fn headerReportForMessage(nid: u32) void {
    reading_nid = nid;
    defer reading_nid = 0;
    if (app.file == null) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    waitCursor(true);
    defer waitCursor(false);
    const m = app.file.?.loadMessage(a, nid) catch |e| {
        _ = msgBox(@errorName(e), "Cannot read message", w.MB_ICONERROR);
        return;
    };
    const ctx: hdrs.Context = app.mailbox_ctx orelse if (app.index) |ix| ix.ctx else .{};
    const an = hdrs.analyseDetailed(a, hdrs.inputFromMessage(a, &m), ctx);
    var pb: [24]u8 = undefined;
    openHeaderReport(a, an, app.file_path, std.fmt.bufPrint(&pb, "hdr-{x:0>8}", .{nid}) catch "hdr");
}

/// Analyse pasted or loaded header text (a whole message is fine: only its header block is used).
fn analyseHeaderText(a: Allocator, text: []const u8, source: []const u8) void {
    const head = hdrs.headerBlock(text);
    if (std.mem.indexOfScalar(u8, head, ':') == null) {
        _ = msgBox("No e-mail headers found.\n\nCopy the complete internet headers (Outlook: File > Properties > Internet headers; Gmail: Show original) and try again.", "Analyse headers", w.MB_ICONINFORMATION);
        return;
    }
    const ctx: hdrs.Context = app.mailbox_ctx orelse .{};
    openHeaderReport(a, hdrs.analyseDetailed(a, hdrs.inputFromHeaders(a, head), ctx), source, "hdr-pasted");
}

fn clipboardText(a: Allocator) ?[]u8 {
    if (w.OpenClipboard(app.hwnd) == 0) return null;
    defer _ = w.CloseClipboard();
    const h = w.GetClipboardData(w.CF_UNICODETEXT) orelse return null;
    const p = w.GlobalLock(h) orelse return null;
    defer _ = w.GlobalUnlock(h);
    const wp: [*:0]const u16 = @ptrCast(@alignCast(p));
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(wp)) catch null;
}

fn analyseClipboard() void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = clipboardText(a) orelse {
        _ = msgBox("The clipboard holds no text.\n\nCopy a message's internet headers first, then choose this command again.", "Analyse headers", w.MB_ICONINFORMATION);
        return;
    };
    analyseHeaderText(a, text, "pasted from the clipboard");
}

fn analyseHeaderFile() void {
    var file: [1024]u16 = @splat(0);
    const filter = L("Messages and header text (*.eml;*.txt)\x00*.eml;*.txt\x00All files (*.*)\x00*.*\x00");
    var ofn: w.OPENFILENAMEW = .{ .hwndOwner = app.hwnd, .lpstrFilter = filter.ptr, .lpstrFile = &file, .nMaxFile = file.len, .Flags = w.OFN_FILEMUSTEXIST | w.OFN_PATHMUSTEXIST | w.OFN_EXPLORER | w.OFN_HIDEREADONLY, .lpstrTitle = L("Analyse headers from file (read-only)") };
    if (w.GetOpenFileNameW(&ofn) == 0) return;
    const len = std.mem.indexOfScalar(u16, &file, 0) orelse 0;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = std.unicode.utf16LeToUtf8Alloc(a, file[0..len]) catch return;
    const data = Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(256 * 1024 * 1024)) catch |e| {
        _ = msgBox(@errorName(e), "Cannot read file", w.MB_ICONERROR);
        return;
    };
    analyseHeaderText(a, data, path);
}

fn cleanupTempFiles() void {
    for (app.temp_files.items) |p| {
        Io.Dir.deleteFileAbsolute(app.io, p) catch {};
        app.gpa.free(p);
    }
    app.temp_files.deinit(app.gpa);
    // the viewer's browser profile (best effort: the browser processes may still be closing)
    if (webview2.used()) {
        var arena = std.heap.ArenaAllocator.init(app.gpa);
        defer arena.deinit();
        const dir = tempDir(arena.allocator()) catch return;
        Io.Dir.cwd().deleteTree(app.io, std.fmt.allocPrint(arena.allocator(), "{s}\\webview", .{dir}) catch return) catch {};
    }
}

// ================================================================ message window

const MsgWin = struct {
    arena: std.heap.ArenaAllocator,
    msg: pst.Message,
    nid: u32,
    hwnd: ?w.HWND = null,
    header: ?w.HWND = null,
    atts: ?w.HWND = null,
    body: ?w.HWND = null,
    img: ?w.HWND = null,
    image: ?*w.GpImage = null,
    image_w: u32 = 0,
    image_h: u32 = 0,
    body_text_w: [:0]const u16 = L(""),
};

fn mwFromHwnd(hwnd: w.HWND) ?*MsgWin {
    const v = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (v == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(v)));
}

fn openMessageWindow(nid: u32) void {
    reading_nid = nid;
    defer reading_nid = 0;
    if (app.file == null) return;
    const st = app.gpa.create(MsgWin) catch return;
    st.* = .{ .arena = std.heap.ArenaAllocator.init(app.gpa), .msg = undefined, .nid = nid };
    const a = st.arena.allocator();
    st.msg = app.file.?.loadMessage(a, nid) catch |e| {
        _ = msgBox(@errorName(e), "Cannot read message", w.MB_ICONERROR);
        st.arena.deinit();
        app.gpa.destroy(st);
        return;
    };
    const subj = st.msg.subject(a) catch "";
    const title = toWAlloc(a, std.fmt.allocPrint(a, "{s} - pstview", .{if (subj.len > 0) subj else "(no subject)"}) catch "pstview") catch L("pstview");
    _ = w.CreateWindowExW(0, L("pstview.msg"), title, w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN | w.WS_VISIBLE, w.CW_USEDEFAULT, w.CW_USEDEFAULT, sc(1000), sc(760), null, null, app.hinst, st);
}

fn mwBuildHeader(st: *MsgWin, a: Allocator) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const m = &st.msg;
    var tb: [96]u8 = undefined;
    out.print(a, "Subject:  {s}\n", .{m.subject(a) catch ""}) catch {};
    out.print(a, "From:     {s} <{s}>\n", .{ m.senderName(a) catch "", m.senderEmail(a) catch "" }) catch {};
    inline for (.{ .{ 1, "To:       " }, .{ 2, "Cc:       " }, .{ 3, "Bcc:      " } }) |kv| {
        var first = true;
        for (m.recipients) |r| {
            if (r.kind != kv[0]) continue;
            out.appendSlice(a, if (first) kv[1] else "; ") catch {};
            first = false;
            out.print(a, "{s} <{s}>", .{ r.name, r.email }) catch {};
        }
        if (!first) out.append(a, '\n') catch {};
    }
    if (m.pc.time(pst.Tag.delivery_time)) |t| out.print(a, "Received: {s}\n", .{fmtLocalLong(&tb, t)}) catch {};
    if (m.pc.time(pst.Tag.client_submit_time)) |t| out.print(a, "Sent:     {s}\n", .{fmtLocalLong(&tb, t)}) catch {};
    if (m.pc.time(pst.Tag.last_modified)) |t| out.print(a, "Modified: {s}\n", .{fmtLocalLong(&tb, t)}) catch {};
    out.print(a, "Class:    {s}    PST NID: 0x{x:0>8}", .{ m.pc.string(a, pst.Tag.message_class) catch "", m.nid }) catch {};
    for (itemview.rows(a, m, fmtLocalLong)) |row| out.print(a, "\n{s}: {s}", .{ row.label, row.value }) catch {};
    return crlf(a, out.items) catch out.items;
}

fn lvInsert(lv: w.HWND, row: usize, cols: []const []const u8, a: Allocator) void {
    for (cols, 0..) |c, ci| {
        const tw = toWAlloc(a, c) catch L("");
        var it: w.LVITEMW = .{ .mask = w.LVIF_TEXT, .iItem = @intCast(row), .iSubItem = @intCast(ci), .pszText = @constCast(tw.ptr) };
        if (ci == 0)
            _ = w.SendMessageW(lv, w.LVM_INSERTITEMW, 0, @intCast(@intFromPtr(&it)))
        else
            _ = w.SendMessageW(lv, w.LVM_SETITEMTEXTW, row, @intCast(@intFromPtr(&it)));
    }
}

fn isTextAttachment(att: *const pst.Attachment) bool {
    if (std.ascii.startsWithIgnoreCase(att.mime, "text/")) return !std.ascii.eqlIgnoreCase(att.mime, "text/html");
    const ext = if (std.mem.lastIndexOfScalar(u8, att.filename, '.')) |d| att.filename[d + 1 ..] else "";
    for ([_][]const u8{ "txt", "csv", "log", "ics", "vcf", "xml", "json", "md" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn mwCreate(hwnd: w.HWND, st: *MsgWin) void {
    st.hwnd = hwnd;
    const a = st.arena.allocator();
    const font = app.font;
    st.header = w.CreateWindowExW(0, L(w.RICHEDIT_CLASS), null, w.WS_CHILD | w.WS_VISIBLE | w.ES_MULTILINE | w.ES_READONLY | w.ES_AUTOVSCROLL | w.WS_VSCROLL, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_MW_HEADER), app.hinst, null);
    st.atts = w.CreateWindowExW(0, L("SysListView32"), null, w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.LVS_REPORT | w.LVS_SHOWSELALWAYS | w.LVS_SINGLESEL, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_MW_ATTS), app.hinst, null);
    st.body = w.CreateWindowExW(0, L("EDIT"), null, w.WS_CHILD | w.WS_VISIBLE | w.WS_VSCROLL | w.ES_MULTILINE | w.ES_READONLY | w.ES_AUTOVSCROLL | w.ES_NOHIDESEL, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_MW_BODY), app.hinst, null);
    st.img = w.CreateWindowExW(0, L("pstview.img"), null, w.WS_CHILD, 0, 0, 0, 0, hwnd, @ptrFromInt(ID_MW_IMG), app.hinst, null);
    inline for (.{ st.header, st.atts }) |h| _ = w.SendMessageW(h.?, w.WM_SETFONT, @intFromPtr(font), 1);
    _ = w.SendMessageW(st.body.?, w.WM_SETFONT, @intFromPtr(app.mono), 1);
    _ = w.SendMessageW(st.body.?, w.EM_SETLIMITTEXT, 0x7FFFFFFE, 0);
    _ = w.SendMessageW(st.atts.?, w.LVM_SETEXTENDEDLISTVIEWSTYLE, 0, @intCast(w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER));
    _ = w.SetWindowTheme(st.atts.?, L("Explorer"), null);
    _ = w.SendMessageW(st.body.?, w.EM_SETMARGINS, w.EC_LEFTMARGIN | w.EC_RIGHTMARGIN, @intCast((@as(u32, @intCast(sc(16))) << 16) | @as(u32, @intCast(sc(16)))));
    inkCaption(hwnd);
    // theme (as it is when the window opens)
    _ = w.SendMessageW(st.header.?, w.EM_SETBKGNDCOLOR, 0, @intCast(w.rgb(ui.white)));
    _ = w.SendMessageW(st.atts.?, w.LVM_SETBKCOLOR, 0, @intCast(w.rgb(ui.white)));
    _ = w.SendMessageW(st.atts.?, w.LVM_SETTEXTBKCOLOR, 0, @intCast(w.rgb(ui.white)));
    _ = w.SendMessageW(st.atts.?, w.LVM_SETTEXTCOLOR, 0, @intCast(w.rgb(ui.ink)));
    _ = w.SetWindowSubclass(st.atts.?, ui.listSubclass, 1, 0);
    if (ui.dark) {
        inline for (.{ st.header, st.atts, st.body }) |h| ui.themeControl(h.?, null);
        const hdr: usize = @bitCast(w.SendMessageW(st.atts.?, w.LVM_GETHEADER, 0, 0));
        if (hdr != 0) ui.themeHeader(@ptrFromInt(hdr));
    }
    const cols = [_]struct { t: [:0]const u16, wd: i32 }{ .{ .t = L("Part / attachment"), .wd = 420 }, .{ .t = L("Size"), .wd = 90 }, .{ .t = L("Type"), .wd = 200 }, .{ .t = L("Preview"), .wd = 160 } };
    for (cols, 0..) |c, i| {
        var col: w.LVCOLUMNW = .{ .mask = w.LVCF_TEXT | w.LVCF_WIDTH | w.LVCF_SUBITEM, .cx = sc(c.wd), .pszText = c.t, .iSubItem = @intCast(i) };
        _ = w.SendMessageW(st.atts.?, w.LVM_INSERTCOLUMNW, i, @intCast(@intFromPtr(&col)));
    }
    lvInsert(st.atts.?, 0, &.{ "Message body (text)", "", "", "shown below" }, a);
    for (st.msg.attachments, 0..) |*att, i| {
        var sb: [32]u8 = undefined;
        const kind: []const u8 = if (att.method == 5) "embedded message" else if (render.isImage(att)) "image - click to view" else if (isTextAttachment(att)) "text - click to view" else "save to open";
        lvInsert(st.atts.?, i + 1, &.{
            if (att.filename.len > 0) att.filename else "(embedded item)",
            std.fmt.bufPrint(&sb, "{d} KB", .{@divTrunc(att.size + 1023, 1024)}) catch "",
            if (att.mime.len > 0) att.mime else render.mimeForName(att.filename),
            kind,
        }, a);
    }
    const head_txt = std.fmt.allocPrint(a, "{s}\n\n{s}", .{ mwBuildHeader(st, a), headerAnalysisText(a, &st.msg) }) catch mwBuildHeader(st, a);
    setRich(a, st.header.?, head_txt);
    var body = st.msg.bodyText(a) catch "";
    if (body.len == 0) {
        const html = st.msg.bodyHtmlUtf8(a) catch "";
        if (html.len > 0) body = htmlToText(a, html) catch "";
    }
    st.body_text_w = toWAlloc(a, crlf(a, body) catch body) catch L("");
    _ = w.SetWindowTextW(st.body.?, st.body_text_w);

    const menu = w.CreateMenu().?;
    const mm = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_HTML, L("View &HTML (safe)\tCtrl+H"));
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_HDR, L("Header analysis &report\tCtrl+I"));
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_PROPS, L("All &properties (MAPI, incl. named)"));
    _ = w.AppendMenuW(mm, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_EXPORT_MSG, L("Export as .&msg..."));
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_EXPORT_EML, L("Export as .&eml..."));
    _ = w.AppendMenuW(mm, w.MF_SEPARATOR, 0, null);
    _ = w.AppendMenuW(mm, w.MF_STRING, MW_CLOSE, L("&Close\tEsc"));
    const am = w.CreatePopupMenu().?;
    _ = w.AppendMenuW(am, w.MF_STRING, MW_SAVE_ATT, L("&Save selected attachment..."));
    _ = w.AppendMenuW(am, w.MF_STRING, MW_SAVE_ALL, L("Save &all attachments..."));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(mm), L("&Message"));
    _ = w.AppendMenuW(menu, w.MF_POPUP, @intFromPtr(am), L("&Attachments"));
    _ = w.SetMenu(hwnd, menu);
}

fn mwLayout(st: *MsgWin) void {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(st.hwnd.?, &rc);
    const W = rc.right;
    const H = rc.bottom;
    const hh = sc(230);
    const n_rows: i32 = @intCast(st.msg.attachments.len + 1);
    const ah = @min(sc(26) + n_rows * sc(20), sc(170));
    // 1-pixel gaps let the hairline-coloured window background act as separators
    _ = w.MoveWindow(st.header.?, 0, 0, W, hh, 1);
    _ = w.MoveWindow(st.atts.?, 0, hh + 1, W, ah, 1);
    _ = w.MoveWindow(st.body.?, 0, hh + ah + 2, W, H - hh - ah - 2, 1);
    _ = w.MoveWindow(st.img.?, 0, hh + ah + 2, W, H - hh - ah - 2, 1);
    var hr: w.RECT = .{ .left = sc(18), .top = sc(12), .right = W - sc(18), .bottom = hh - sc(6) };
    _ = w.SendMessageW(st.header.?, w.EM_SETRECT, 0, @intCast(@intFromPtr(&hr)));
}

fn mwSelectedAtt(st: *MsgWin) ?usize {
    const r = w.SendMessageW(st.atts.?, w.LVM_GETNEXTITEM, @bitCast(@as(isize, -1)), w.LVNI_SELECTED);
    if (r <= 0) return null; // row 0 = body
    const i: usize = @intCast(r - 1);
    return if (i < st.msg.attachments.len) i else null;
}

fn mwShowPart(st: *MsgWin) void {
    const a = st.arena.allocator();
    if (st.image) |img| {
        _ = w.GdipDisposeImage(img);
        st.image = null;
    }
    const sel = mwSelectedAtt(st) orelse {
        _ = w.SetWindowTextW(st.body.?, st.body_text_w);
        _ = w.ShowWindow(st.img.?, w.SW_HIDE);
        _ = w.ShowWindow(st.body.?, w.SW_SHOW);
        return;
    };
    const att = &st.msg.attachments[sel];
    if (render.isImage(att)) {
        if (w.decodeImage(att.data())) |img| {
            st.image = img;
            _ = w.GdipGetImageWidth(img, &st.image_w);
            _ = w.GdipGetImageHeight(img, &st.image_h);
            _ = w.ShowWindow(st.body.?, w.SW_HIDE);
            _ = w.ShowWindow(st.img.?, w.SW_SHOW);
            _ = w.InvalidateRect(st.img.?, null, 1);
            return;
        }
    }
    var info: std.ArrayList(u8) = .empty;
    info.print(a, "Attachment: {s}\nSize: {d} bytes   Type: {s}\n\n", .{ att.filename, att.data().len, if (att.mime.len > 0) att.mime else render.mimeForName(att.filename) }) catch {};
    if (isTextAttachment(att)) {
        const d = att.data();
        info.appendSlice(a, d[0..@min(d.len, 2 * 1024 * 1024)]) catch {};
    } else if (att.method == 5) {
        info.appendSlice(a, "Embedded message. Use Attachments > Save to export it as .msg.") catch {};
    } else {
        info.appendSlice(a, "Not opened automatically (attachments may be unsafe).\nUse Attachments > Save selected attachment... to export it, then inspect it in a safe environment.") catch {};
    }
    _ = w.SetWindowTextW(st.body.?, toWAlloc(a, crlf(a, info.items) catch info.items) catch L(""));
    _ = w.ShowWindow(st.img.?, w.SW_HIDE);
    _ = w.ShowWindow(st.body.?, w.SW_SHOW);
}

fn saveDialog(a: Allocator, owner: w.HWND, default_name: []const u8) ?[]u8 {
    var file: [1024]u16 = @splat(0);
    const dn = toW(&file, default_name);
    _ = dn;
    var ofn: w.OPENFILENAMEW = .{ .hwndOwner = owner, .lpstrFile = &file, .nMaxFile = file.len, .Flags = w.OFN_OVERWRITEPROMPT | w.OFN_PATHMUSTEXIST | w.OFN_EXPLORER | w.OFN_HIDEREADONLY, .lpstrFilter = L("All files (*.*)\x00*.*\x00").ptr };
    if (w.GetSaveFileNameW(&ofn) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &file, 0) orelse 0;
    return std.unicode.utf16LeToUtf8Alloc(a, file[0..len]) catch null;
}

fn writePath(path: []const u8, data: []const u8) !void {
    const f = try Io.Dir.createFileAbsolute(app.io, path, .{});
    defer f.close(app.io);
    try f.writeStreamingAll(app.io, data);
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

fn mwCommand(st: *MsgWin, id: u16) void {
    const a = st.arena.allocator();
    switch (id) {
        MW_HTML => viewSafeHtml(st.nid),
        MW_HDR => headerReportForMessage(st.nid),
        MW_PROPS => showAllProperties(st.nid),
        MW_CLOSE => _ = w.DestroyWindow(st.hwnd.?),
        MW_EXPORT_MSG, MW_EXPORT_EML => {
            const is_msg = id == MW_EXPORT_MSG;
            const name = exp.safeName(a, "", st.msg.subject(a) catch "", if (is_msg) "msg" else "eml") catch "message";
            const path = saveDialog(a, st.hwnd.?, name) orelse return;
            const data = (if (is_msg) exp.buildMsg(a, &st.msg) else exp.buildEml(a, &st.msg, 0)) catch |e| {
                _ = msgBox(@errorName(e), "Export failed", w.MB_ICONERROR);
                return;
            };
            writePath(path, data) catch |e| {
                _ = msgBox(@errorName(e), "Export failed", w.MB_ICONERROR);
            };
        },
        MW_SAVE_ATT => {
            const i = mwSelectedAtt(st) orelse {
                _ = msgBox("Select an attachment in the list first.", "pstview", w.MB_ICONINFORMATION);
                return;
            };
            const att = &st.msg.attachments[i];
            var ext: []const u8 = "";
            const data = attachmentBytes(a, att, &ext) orelse return;
            const name = if (ext.len > 0) (exp.safeName(a, "", att.filename, ext) catch "embedded.msg") else (exp.safeFileName(a, "", if (att.filename.len > 0) att.filename else "attachment.bin") catch "attachment.bin");
            const path = saveDialog(a, st.hwnd.?, name) orelse return;
            writePath(path, data) catch |e| {
                _ = msgBox(@errorName(e), "Save failed", w.MB_ICONERROR);
            };
        },
        MW_SAVE_ALL => {
            if (st.msg.attachments.len == 0) return;
            const dir = pickFolder(a, "Save all attachments to:") orelse return;
            var saved: usize = 0;
            for (st.msg.attachments, 0..) |*att, i| {
                var ext: []const u8 = "";
                const data = attachmentBytes(a, att, &ext) orelse continue;
                var pb: [8]u8 = undefined;
                const pfx = std.fmt.bufPrint(&pb, "{d:0>2}", .{i + 1}) catch "";
                const fname = if (att.filename.len > 0) att.filename else "attachment";
                const name = (if (ext.len > 0) exp.safeName(a, pfx, fname, ext) else exp.safeFileName(a, pfx, fname)) catch continue;
                writeFile(a, dir, name, data) catch continue;
                saved += 1;
            }
            var b: [128]u8 = undefined;
            _ = msgBox(std.fmt.bufPrint(&b, "Saved {d} of {d} attachment(s).", .{ saved, st.msg.attachments.len }) catch "", "pstview", w.MB_ICONINFORMATION);
        },
        else => {},
    }
}

fn mwProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (ui.menuBarMessage(hwnd, msg, lp)) |r| return r;
    switch (msg) {
        w.WM_NCPAINT, w.WM_NCACTIVATE => {
            const r = w.DefWindowProcW(hwnd, msg, wp, lp);
            ui.paintMenuBarLine(hwnd);
            return r;
        },
        w.WM_ERASEBKGND => {
            // shows through the 1-pixel gaps between the panes as separators
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(hwnd, &rc);
            _ = w.FillRect(@ptrFromInt(wp), &rc, app.hairline_brush);
            return 1;
        },
        w.WM_CREATE => {
            const cs: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lp)));
            const st: *MsgWin = @ptrCast(@alignCast(cs.*.?));
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(st)));
            mwCreate(hwnd, st);
            return 0;
        },
        w.WM_SIZE => {
            if (mwFromHwnd(hwnd)) |st| mwLayout(st);
            return 0;
        },
        w.WM_CTLCOLORSTATIC => {
            // the read-only body would otherwise be painted grey
            const dc: w.HDC = @ptrFromInt(wp);
            _ = w.SetBkColor(dc, w.rgb(ui.white));
            _ = w.SetTextColor(dc, w.rgb(ui.ink));
            return @bitCast(@intFromPtr(app.white_brush));
        },
        w.WM_COMMAND => {
            if (mwFromHwnd(hwnd)) |st| mwCommand(st, @truncate(wp));
            return 0;
        },
        w.WM_NOTIFY => {
            const nm: *w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lp)));
            const st = mwFromHwnd(hwnd) orelse return 0;
            if (nm.idFrom == ID_MW_ATTS) switch (nm.code) {
                w.LVN_ITEMCHANGED => {
                    const lv: *w.NMLISTVIEW = @ptrCast(@alignCast(nm));
                    if ((lv.uNewState & w.LVIS_SELECTED) != 0) mwShowPart(st);
                },
                w.NM_DBLCLK => if (mwSelectedAtt(st) != null) mwCommand(st, MW_SAVE_ATT),
                w.NM_RCLICK => {
                    const cmd = popupAt(hwnd, &.{
                        .{ .id = MW_SAVE_ATT, .text = L("&Save attachment...") },
                        .{ .id = MW_SAVE_ALL, .text = L("Save &all attachments...") },
                        .{ .id = 0, .text = L("") },
                        .{ .id = MW_HTML, .text = L("View message &HTML (safe)") },
                    });
                    if (cmd != 0) mwCommand(st, @intCast(cmd));
                },
                else => {},
            };
            return 0;
        },
        w.WM_NCDESTROY => {
            if (mwFromHwnd(hwnd)) |st| {
                if (st.image) |img| _ = w.GdipDisposeImage(img);
                st.arena.deinit();
                app.gpa.destroy(st);
                _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            }
            return w.DefWindowProcW(hwnd, msg, wp, lp);
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Image preview pane: scales the image to fit (never enlarges past 100%), keeps aspect ratio.
fn imgProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_ERASEBKGND => return 1,
        w.WM_SIZE => {
            _ = w.InvalidateRect(hwnd, null, 1);
            return 0;
        },
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const hdc = w.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w.EndPaint(hwnd, &ps);
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(hwnd, &rc);
            _ = w.FillRect(hdc, &rc, app.pane_brush);
            _ = w.SetTextColor(hdc, w.rgb(ui.ink_soft));
            const parent = w.GetParent(hwnd) orelse return 0;
            const st = mwFromHwnd(parent) orelse return 0;
            const img = st.image orelse return 0;
            const iw: f32 = @floatFromInt(@max(st.image_w, 1));
            const ih: f32 = @floatFromInt(@max(st.image_h, 1));
            const cw: f32 = @floatFromInt(@max(rc.right - sc(16), 1));
            const ch: f32 = @floatFromInt(@max(rc.bottom - sc(36), 1));
            const s = @min(@min(cw / iw, ch / ih), 1.0);
            const dw: i32 = @intFromFloat(iw * s);
            const dh: i32 = @intFromFloat(ih * s);
            const x = @divTrunc(rc.right - dw, 2);
            const y = sc(8);
            var g: ?*w.GpGraphics = null;
            if (w.GdipCreateFromHDC(hdc, &g) == 0) {
                _ = w.GdipSetInterpolationMode(g.?, 7);
                _ = w.GdipDrawImageRectI(g.?, img, x, y, dw, dh);
                _ = w.GdipDeleteGraphics(g.?);
            }
            var tb: [96]u8 = undefined;
            var wb: [96]u16 = undefined;
            const label = std.fmt.bufPrint(&tb, "{d} x {d} px  ({d}%)", .{ st.image_w, st.image_h, @as(i32, @intFromFloat(s * 100)) }) catch "";
            const lw = toW(&wb, label);
            var lr: w.RECT = .{ .left = 0, .top = rc.bottom - sc(24), .right = rc.right, .bottom = rc.bottom };
            _ = w.SetBkMode(hdc, 1);
            _ = w.SelectObject(hdc, app.font);
            _ = w.DrawTextW(hdc, lw, -1, &lr, 0x1 | 0x20 | 0x4); // center | singleline | vcenter
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn mboxProgress(done: u64, total: u64) void {
    setStatus("Scanning MBOX... {d}%", .{if (total > 0) done * 100 / total else 0});
}

fn recoverProgress(done: u64, total: u64) void {
    setStatus("Scanning the file for stale index pages... {d}%", .{if (total > 0) done * 100 / total else 0});
}

/// Scan every page of the PST/OST part(s) for stale index pages and list what they recover
/// (items no longer indexed, earlier versions) in a "[Recovered items]" branch.
fn recoverDeletedItems() void {
    if (app.file == null) return;
    if (app.file.? == .mbox) {
        _ = msgBox("Recovery from stale index pages applies to PST/OST files.\n\nFor Thunderbird mailboxes, messages deleted but not yet compacted are already listed and marked in their folders.", "pstview", w.MB_ICONINFORMATION);
        return;
    }
    if (app.recovery != null) {
        _ = msgBox("Recovery has already run for this file - see the [Recovered items] branch.", "pstview", w.MB_ICONINFORMATION);
        return;
    }
    waitCursor(true);
    const a = app.file_arena.allocator();
    const r = app.file.?.recoverDeleted(a, app.file_path, &recoverProgress) catch |e| {
        waitCursor(false);
        _ = msgBox(@errorName(e), "Recovery failed", w.MB_ICONERROR);
        return;
    };
    waitCursor(false);
    app.recovery = r;
    const root_idx = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Recovered items]", .name = "Recovered items", .count = 0, .kind = .label }) catch return;
    const root = insertTreeItem(a, null, std.fmt.allocPrint(a, "[Recovered items] ({d})", .{r.deleted.len + r.versions.len}) catch "[Recovered items]", root_idx, true, .recovered);
    const di = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Recovered items]/No longer indexed", .name = "No longer indexed", .count = @intCast(r.deleted.len), .kind = .recovered }) catch return;
    _ = insertTreeItem(a, root, std.fmt.allocPrint(a, "No longer indexed - deleted or moved ({d})", .{r.deleted.len}) catch "No longer indexed", di, false, .recovered);
    const vi = app.folders.items.len;
    app.folders.append(a, .{ .nid = 0, .path = "[Recovered items]/Earlier versions", .name = "Earlier versions", .count = @intCast(r.versions.len), .kind = .versions }) catch return;
    _ = insertTreeItem(a, root, std.fmt.allocPrint(a, "Earlier versions of existing items ({d})", .{r.versions.len}) catch "Earlier versions", vi, false, .journal);
    var b: [600]u8 = undefined;
    const summary = std.fmt.bufPrint(&b, "Recovery scan finished.\n\n{d} item(s) no longer in the index (deleted, or moved and re-numbered) and {d} earlier version(s) of existing items were recovered from {d} stale node-tree and {d} stale block-tree page(s); {d} unindexed block(s) were verified intact by id and checksum.\n\nSee the [Recovered items] branch. Each item's Note names the stale page and the folder it was in.", .{ r.deleted.len, r.versions.len, r.stale_node_pages, r.stale_block_pages, r.blocks }) catch "Recovery finished.";
    setStatus("Recovery: {d} no longer indexed, {d} earlier versions.", .{ r.deleted.len, r.versions.len });
    _ = msgBox(summary, "pstview", w.MB_ICONINFORMATION);
}

fn verifyProgress(done: usize, total: usize) void {
    setStatus("Verifying every block... {d}/{d} nodes", .{ done, total });
}

/// Show the integrity log (and optional verify summary) in the preview pane.
fn showIntegrityLog(st: ?pst.VerifyStats) void {
    _ = app.preview_arena.reset(.retain_capacity);
    const a = app.preview_arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    if (st) |s| out.print(a, "Verified {d} nodes, {d} sub-nodes, {d} data blocks ({d} MB); every page and block checksum checked.\n\n", .{ s.nodes, s.subnodes, s.blocks, s.bytes / (1024 * 1024) }) catch {};
    if (app.hidden) |h| out.print(a, "Hidden-item scan: {d} nodes in index, {d} folders reachable, {d} items listed in folder tables;\n{d} orphaned message(s), {d} associated (FAI) item(s), {d} orphaned folder(s).\n\n", .{ h.total_nodes, h.folders_reached, h.listed_messages, h.orphans.len, h.fai.len, h.orphan_folders.len }) catch {};
    const parts = app.file.?.pstParts(a, app.file_path) catch &.{};
    for (parts) |p| {
        if (parts.len > 1) out.print(a, "======== {s}\n", .{p.name}) catch {};
        out.appendSlice(a, pst.issuesText(a, p.file) catch "") catch {};
        if (parts.len > 1) out.append(a, '\n') catch {};
    }
    setRich(a, app.preview.?, out.items);
    setStatus("Integrity log: {d} issue(s)", .{app.file.?.issueCount()});
}

fn selectAll() void {
    var it: w.LVITEMW = .{ .state = w.LVIS_SELECTED, .stateMask = w.LVIS_SELECTED };
    _ = w.SendMessageW(app.list.?, w.LVM_SETITEMSTATE, @bitCast(@as(isize, -1)), @intCast(@intFromPtr(&it)));
}

// ================================================================ install / uninstall (install.zig)

fn appIcon() ?w.HICON {
    return @ptrCast(w.LoadImageW(app.hinst, 1, w.IMAGE_ICON, sc(32), sc(32), 0));
}

/// Help menu: Install only from a portable copy; Default apps / Uninstall only when installed.
fn updateInstallMenu(hm: w.HMENU) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = install.defaultLayout(a) catch return;
    const installed = install.isInstalled(a, l);
    _ = w.EnableMenuItem(hm, CMD_INSTALL, if (install.runningInstalled(a, l)) w.MF_GRAYED else w.MF_ENABLED);
    _ = w.EnableMenuItem(hm, CMD_DEFAULT_APPS, if (installed) w.MF_ENABLED else w.MF_GRAYED);
    _ = w.EnableMenuItem(hm, CMD_UNINSTALL, if (installed) w.MF_ENABLED else w.MF_GRAYED);
}

/// Show the welcome screen's install offer only for a portable copy that is not installed.
fn refreshInstallOffer() void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = install.defaultLayout(a) catch return ui.showInstallOffer(false);
    ui.showInstallOffer(!install.isInstalled(a, l) and !install.runningInstalled(a, l));
}

/// Offer to install: on the first run of a portable copy (unless declined for good), or on request.
fn offerInstall(requested: bool) void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = install.defaultLayout(a) catch return;
    if (install.runningInstalled(a, l)) return;
    const updating = install.isInstalled(a, l);
    if (!requested and (updating or install.promptDismissed(a))) return;
    const instruction = if (updating) L("Update the installed copy of pstview?") else L("Install pstview on this PC?");
    const content = toWAlloc(a, if (updating)
        std.fmt.allocPrint(a, "Replaces the copy installed in {s} with this version ({s}). File handlers and the Start menu entry are refreshed.", .{ l.dir, build_options.version }) catch return
    else
        std.fmt.allocPrint(a, "pstview is running as a portable app. Installing copies it to {s}, adds it to the Start menu and lets Explorer open .pst, .ost and .mbox files with it. No administrator rights are needed; uninstall any time from Settings > Apps.\n\nThe portable copy keeps working either way - nothing is written to this PC unless you install.", .{l.dir}) catch return) catch return;
    const r = ui.taskDialog(app.hwnd, appIcon(), instruction, content, &.{
        .{ .id = 100, .text = if (updating) L("Update for this user") else L("Install for this user\nStart menu entry, file handlers and an uninstaller") },
        .{ .id = 101, .text = L("Keep using it portable\nNothing is written to this PC") },
    }, if (requested) null else L("Don't offer this again"));
    if (r.button == 100) return doInstall(a, l);
    if (r.verified) install.dismissPrompt(a);
}

fn doInstall(a: Allocator, l: install.Layout) void {
    waitCursor(true);
    install.install(a, app.io, l, build_options.version) catch |e| {
        waitCursor(false);
        const why = switch (e) {
            error.CopyFailed => std.fmt.allocPrint(a, "pstview could not be copied to {s}.\n\nIf the installed copy is running, close it and try again.", .{l.dir}) catch "copy failed",
            error.InstallDir => std.fmt.allocPrint(a, "The folder {s} could not be created.", .{l.dir}) catch "folder",
            else => @errorName(e),
        };
        _ = msgBox(why, "pstview - install failed", w.MB_ICONERROR);
        return;
    };
    waitCursor(false);
    refreshInstallOffer();
    setStatus("pstview is installed for this user ({s}).", .{l.dir});
    const r = ui.taskDialog(app.hwnd, appIcon(), L("pstview is installed"), L("Start it from the Start menu. Explorer now offers pstview under \"Open with\" for .pst, .ost, .mbox and .mbx files; to make it the default, Windows asks you to confirm in Settings > Default apps.\n\nThis portable copy is no longer needed and can be deleted."), &.{
        .{ .id = 100, .text = L("Done") },
        .{ .id = 101, .text = L("Choose default apps\nOpens Settings > Default apps for pstview") },
    }, null);
    if (r.button == 101) openDefaultApps();
}

fn openDefaultApps() void {
    _ = w.ShellExecuteW(app.hwnd, L("open"), L("ms-settings:defaultapps?registeredAppUser=pstview"), null, null, w.SW_SHOWNORMAL);
}

/// Confirm and uninstall (Help menu, or `pstview.exe --uninstall` from Settings > Apps).
/// Returns true when pstview should exit because the running exe is the one being removed.
fn uninstallInteractive(owner: ?w.HWND) bool {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = install.defaultLayout(a) catch return false;
    const content = toWAlloc(a, std.fmt.allocPrint(a, "Removes pstview from {s}, its Start menu entry, its file handlers and its entry in Settings > Apps.\n\nMailbox files, exports and reports are not touched.", .{l.dir}) catch return false) catch return false;
    const r = ui.taskDialog(owner, appIcon(), L("Uninstall pstview?"), content, &.{
        .{ .id = 100, .text = L("Uninstall") },
        .{ .id = 101, .text = L("Keep pstview") },
    }, null);
    if (r.button != 100) return false;
    const res = install.uninstall(a, l) catch |e| {
        _ = msgBox(@errorName(e), "pstview - uninstall failed", w.MB_ICONERROR);
        return false;
    };
    if (res == .after_exit) {
        _ = msgBox("pstview has been uninstalled for this user and closes now.", "pstview", w.MB_ICONINFORMATION);
        return true;
    }
    _ = msgBox("pstview has been uninstalled for this user.", "pstview", w.MB_ICONINFORMATION);
    if (app.hwnd != null) refreshInstallOffer();
    return false;
}

/// List view text while it has no rows.
fn emptyMarkup(m: *w.NMLVEMPTYMARKUP) LRESULT {
    if (app.file == null) return 0;
    const text: []const u8 = if (app.cur_folder == null) "Select a folder." else if (app.msgs.len > 0) "No messages match the search." else "This folder is empty.";
    m.dwFlags = w.EMF_CENTERED;
    _ = toW(&m.szMarkup, text);
    return 1;
}

/// Help > About: pstview's own window (system message boxes chime).
fn showAbout() void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const detail: []const u8 = blk: {
        const l = install.defaultLayout(a) catch break :blk "";
        if (install.runningInstalled(a, l)) break :blk std.fmt.allocPrint(a, "Installed for this user in {s}", .{l.dir}) catch "";
        const self = install.selfPath(a) catch break :blk "Portable copy";
        break :blk std.fmt.allocPrint(a, "Portable copy: {s}", .{std.fs.path.dirname(self) orelse self}) catch "";
    };
    _ = ui.dialog(app.hwnd, app.hinst, .{
        .kind = .about,
        .version = "Version " ++ build_options.version,
        .body = "Read-only viewer and exporter for Outlook PST / OST and MBOX mailboxes.\n\n" ++
            "Opens PST and OST files (including Outlook 2013+ OSTs and multi-part Acronis exports) and MBOX mailboxes from Google Takeout, Thunderbird and Apple Mail without write access - nothing is written next to the source.\n\n" ++
            "Exports .msg and .eml with HTML and CSV reports that record the source's SHA-256. Times are shown in this computer's time zone (daylight-saving aware) and in UTC.",
        .detail = detail,
        .link = L("<a>github.com/publicarray/pstview</a>"),
        .link_url = L("https://github.com/publicarray/pstview"),
    });
}

fn onCommand(id: u16, code: u16) void {
    switch (id) {
        CMD_OPEN => openDialog(),
        CMD_OPEN_FOLDER => openFolderDialog(),
        CMD_CLOSE => closePst(),
        CMD_THEME_SYSTEM, CMD_THEME_LIGHT, CMD_THEME_DARK => {
            app.theme = @enumFromInt(id - CMD_THEME_SYSTEM);
            applyTheme();
        },
        CMD_INSTALL => offerInstall(true),
        CMD_DEFAULT_APPS => openDefaultApps(),
        CMD_UNINSTALL => if (uninstallInteractive(app.hwnd)) {
            _ = w.DestroyWindow(app.hwnd.?);
        },
        CMD_EXPORT_MSG => exportSelected(.msg),
        CMD_EXPORT_EML => exportSelected(.eml),
        CMD_REPORT => exportSelected(.none),
        CMD_SAVE_ATT => saveAttachments(),
        CMD_SELECT_ALL => selectAll(),
        CMD_HASH => if (app.file != null) {
            waitCursor(true);
            const h = pstSha256();
            waitCursor(false);
            var b: [4096]u8 = undefined;
            const shown = h[0..@min(h.len, 3500)];
            _ = msgBox(std.fmt.bufPrint(&b, "{s}\n\nSize: {d} bytes\nSHA-256: {s}{s}", .{ app.file_path, app.file.?.totalSize(), shown, if (shown.len < h.len) " ... (all hashes are in the export report)" else "" }) catch "", "Source file hash", w.MB_ICONINFORMATION);
            setStatus("SHA-256 {s}", .{shown});
        },
        CMD_OPEN_MSG => if (focusedRow()) |mi| openMessageWindow(app.msgs[mi].nid),
        CMD_SAFE_HTML => if (focusedRow()) |mi| viewSafeHtml(app.msgs[mi].nid),
        CMD_ANALYSE => analyseFolder(),
        CMD_HDR_REPORT => if (focusedRow()) |mi| headerReportForMessage(app.msgs[mi].nid) else {
            _ = msgBox("Select a message first.", "pstview", w.MB_ICONINFORMATION);
        },
        CMD_PROPS => if (focusedRow()) |mi| showAllProperties(app.msgs[mi].nid) else {
            _ = msgBox("Select a message first.", "pstview", w.MB_ICONINFORMATION);
        },
        CMD_HDR_CLIP => analyseClipboard(),
        CMD_RECOVER => recoverDeletedItems(),
        CMD_HDR_FILE => analyseHeaderFile(),
        CMD_INTEGRITY, CMD_VERIFY => if (app.file != null and app.file.? == .mbox) {
            _ = msgBox("The integrity log and block verification apply to PST/OST files (MBOX has no internal checksums).\n\nUse File > Show SHA-256 of source file to fix the evidence state.", "pstview", w.MB_ICONINFORMATION);
        } else if (id == CMD_INTEGRITY) {
            if (app.file != null) showIntegrityLog(null);
        } else if (app.file != null) {
            // every PST/OST behind the source (all parts of a merged set)
            waitCursor(true);
            var tot: pst.VerifyStats = .{};
            var arena = std.heap.ArenaAllocator.init(app.gpa);
            defer arena.deinit();
            for (app.file.?.pstParts(arena.allocator(), app.file_path) catch &.{}) |p| {
                const st = pst.verifyAll(p.file, &verifyProgress) catch continue;
                tot.nodes += st.nodes;
                tot.subnodes += st.subnodes;
                tot.blocks += st.blocks;
                tot.bytes += st.bytes;
            }
            waitCursor(false);
            showIntegrityLog(tot);
        },
        CMD_EXIT => _ = w.DestroyWindow(app.hwnd.?),
        CMD_ABOUT => showAbout(),
        ID_SEARCH => if (code == w.EN_CHANGE) applyFilter(),
        else => {},
    }
}

fn onNotify(nm: *w.NMHDR) LRESULT {
    if (nm.idFrom == ID_LIST) {
        switch (nm.code) {
            w.LVN_GETDISPINFOW => dispInfo(@ptrCast(@alignCast(nm))),
            w.LVN_GETEMPTYMARKUP => return emptyMarkup(@ptrCast(@alignCast(nm))),
            w.LVN_ITEMCHANGED => {
                const lv: *w.NMLISTVIEW = @ptrCast(@alignCast(nm));
                if ((lv.uNewState & w.LVIS_FOCUSED) != 0 or (lv.uNewState & w.LVIS_SELECTED) != 0) showPreview();
            },
            w.LVN_COLUMNCLICK => {
                const lv: *w.NMLISTVIEW = @ptrCast(@alignCast(nm));
                if (lv.iSubItem == app.sort_col) app.sort_desc = !app.sort_desc else {
                    app.sort_col = lv.iSubItem;
                    app.sort_desc = lv.iSubItem <= 1 or lv.iSubItem == 5;
                }
                sortView();
                _ = w.SendMessageW(app.list.?, w.LVM_REDRAWITEMS, 0, @intCast(app.view.items.len));
                showPreview();
            },
            w.NM_DBLCLK => onCommand(CMD_OPEN_MSG, 0),
            w.LVN_KEYDOWN => {
                const kd: *align(1) w.NMLVKEYDOWN = @ptrCast(nm);
                if (kd.wVKey == w.VK_RETURN) onCommand(CMD_OPEN_MSG, 0);
            },
            w.NM_RCLICK => listContextMenu(),
            else => {},
        }
    } else if (nm.idFrom == ID_TREE and nm.code == w.TVN_SELCHANGEDW) {
        const tv: *w.NMTREEVIEWW = @ptrCast(@alignCast(nm));
        selectFolder(@intCast(tv.itemNew.lParam));
    }
    return 0;
}

const LRESULT = w.LRESULT;

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) LRESULT {
    if (ui.menuBarMessage(hwnd, msg, lp)) |r| return r;
    switch (msg) {
        w.WM_NCPAINT, w.WM_NCACTIVATE => {
            const r = w.DefWindowProcW(hwnd, msg, wp, lp);
            ui.paintMenuBarLine(hwnd);
            return r;
        },
        w.WM_ERASEBKGND => {
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(hwnd, &rc);
            _ = w.FillRect(@ptrFromInt(wp), &rc, app.white_brush);
            return 1;
        },
        w.WM_SETTINGCHANGE => {
            // Windows switched between light and dark
            if (app.theme == .system and app.tree != null and ui.systemDark() != ui.dark) applyTheme();
            return 0;
        },
        w.WM_CREATE => {
            app.hwnd = hwnd;
            createChildren(hwnd);
            return 0;
        },
        w.WM_SIZE => {
            layout();
            return 0;
        },
        w.WM_COMMAND => {
            onCommand(@truncate(wp), @truncate(wp >> 16));
            return 0;
        },
        w.WM_NOTIFY => return onNotify(@ptrFromInt(@as(usize, @bitCast(lp)))),
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const dc = w.BeginPaint(hwnd, &ps) orelse return 0;
            paintMain(dc);
            _ = w.EndPaint(hwnd, &ps);
            return 0;
        },
        w.WM_CTLCOLOREDIT => {
            // the search field: same fill as the rounded box around it
            const dc: w.HDC = @ptrFromInt(wp);
            _ = w.SetBkColor(dc, w.rgb(ui.pane));
            _ = w.SetTextColor(dc, w.rgb(ui.ink));
            return @bitCast(@intFromPtr(app.pane_brush)); // handles may be sign-extended: bitCast, not intCast
        },
        w.WM_DRAWITEM => {
            const di: *const w.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (di.CtlID == ID_STATUS) drawSeal(di);
            return 1;
        },
        w.WM_INITMENUPOPUP => {
            if (app.help_menu) |hm| if (@intFromPtr(hm) == wp) updateInstallMenu(hm);
            return 0;
        },
        WM_APP_FIRST_RUN => {
            offerInstall(false);
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lp));
            const y: i32 = @as(i16, @truncate(lp >> 16));
            switch (splitterAt(x, y)) {
                .vertical => app.dragging = true,
                .horizontal => app.dragging_y = true,
                .none => return 0,
            }
            _ = w.SetCapture(hwnd);
            return 0;
        },
        w.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lp));
            const y: i32 = @as(i16, @truncate(lp >> 16));
            if (app.dragging) {
                app.split_x = x;
                layout();
            } else if (app.dragging_y) {
                const g = geometry();
                const avail = @max(g.H - g.list.top - sc(5), 1);
                app.split_y_frac = std.math.clamp(@as(f32, @floatFromInt(y - g.list.top)) / @as(f32, @floatFromInt(avail)), 0.1, 0.9);
                layout();
            }
            const over = if (app.dragging) .vertical else if (app.dragging_y) .horizontal else splitterAt(x, y);
            switch (over) {
                .vertical => _ = w.SetCursor(w.LoadCursorW(null, w.IDC_SIZEWE)),
                .horizontal => _ = w.SetCursor(w.LoadCursorW(null, w.IDC_SIZENS)),
                .none => {},
            }
            return 0;
        },
        w.WM_LBUTTONUP => {
            if (app.dragging or app.dragging_y) {
                app.dragging = false;
                app.dragging_y = false;
                _ = w.ReleaseCapture();
            }
            return 0;
        },
        w.WM_DROPFILES => {
            const hdrop: *anyopaque = @ptrFromInt(wp);
            var arena = std.heap.ArenaAllocator.init(app.gpa);
            defer arena.deinit();
            var paths: std.ArrayList([]const u8) = .empty;
            const count = w.DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
            for (0..count) |k| {
                var buf: [1024]u16 = @splat(0);
                const n = w.DragQueryFileW(hdrop, @intCast(k), &buf, buf.len);
                if (n > 0) paths.append(arena.allocator(), std.unicode.utf16LeToUtf8Alloc(arena.allocator(), buf[0..n]) catch continue) catch {};
            }
            w.DragFinish(hdrop);
            if (paths.items.len > 0) openPaths(paths.items); // several PST parts are merged into one mailbox
            return 0;
        },
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

pub fn main(init: std.process.Init) !void {
    app = .{
        .gpa = init.gpa,
        .io = init.io,
        .file_arena = std.heap.ArenaAllocator.init(init.gpa),
        .folder_arena = std.heap.ArenaAllocator.init(init.gpa),
        .preview_arena = std.heap.ArenaAllocator.init(init.gpa),
    };
    mime.charset_hook = &w.charsetToUtf8; // decode any charset in headers via Windows code pages
    store.mbox.scan_progress = &mboxProgress;
    _ = w.CoInitializeEx(null, 0x2); // apartment-threaded, needed by the folder picker
    const icc: w.INITCOMMONCONTROLSEX = .{ .dwICC = w.ICC_LISTVIEW_CLASSES | w.ICC_TREEVIEW_CLASSES | w.ICC_BAR_CLASSES | w.ICC_LINK_CLASS };
    _ = w.InitCommonControlsEx(&icc);
    _ = w.LoadLibraryW(L("Msftedit.dll")); // Rich Edit 4.1+ for coloured previews
    app.hinst = w.GetModuleHandleW(null);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Settings > Apps runs the installed exe with --uninstall
    if (args.len > 1 and std.mem.eql(u8, args[1], "--uninstall")) {
        _ = uninstallInteractive(null);
        return;
    }

    const cls = L("pstview.main");
    const wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = app.hinst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .hIcon = w.LoadIconW(app.hinst, 1),
        .hbrBackground = @ptrFromInt(w.COLOR_WINDOW + 1),
        .lpszClassName = cls,
    };
    _ = w.RegisterClassExW(&wc);
    const mwc: w.WNDCLASSEXW = .{
        .lpfnWndProc = mwProc,
        .hInstance = app.hinst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .hIcon = w.LoadIconW(app.hinst, 1),
        .hbrBackground = w.CreateSolidBrush(w.rgb(ui.hairline)), // shows through 1-pixel gaps as separators
        .lpszClassName = L("pstview.msg"),
    };
    _ = w.RegisterClassExW(&mwc);
    const iwc: w.WNDCLASSEXW = .{
        .style = w.CS_HREDRAW | w.CS_VREDRAW,
        .lpfnWndProc = imgProc,
        .hInstance = app.hinst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .lpszClassName = L("pstview.img"),
    };
    _ = w.RegisterClassExW(&iwc);
    var gdip_token: usize = 0;
    const gdip_in: w.GdiplusStartupInput = .{};
    _ = w.GdiplusStartup(&gdip_token, &gdip_in, null);

    const hwnd = w.CreateWindowExW(w.WS_EX_ACCEPTFILES, cls, L("pstview"), w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 1400, 900, null, null, app.hinst, null) orelse return error.CreateWindowFailed;
    _ = w.ShowWindow(hwnd, w.SW_SHOW);
    _ = w.UpdateWindow(hwnd);

    refreshInstallOffer();
    if (args.len > 1) openPst(args[1]) else _ = w.PostMessageW(hwnd, WM_APP_FIRST_RUN, 0, 0);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        // Ctrl+A in the list selects all, Ctrl+O opens
        if (msg.message == w.WM_KEYDOWN and (w.GetKeyState(0x11) & @as(i16, -0x8000)) != 0) {
            if (msg.wParam == 'A' and msg.hwnd == app.list) {
                selectAll();
                continue;
            }
            if (msg.wParam == 'O') {
                openDialog();
                continue;
            }
            if (msg.wParam == 'R') {
                analyseFolder();
                continue;
            }
            if (msg.wParam == 'H' or msg.wParam == 'I') {
                const root = if (msg.hwnd) |h| w.GetAncestor(h, w.GA_ROOT) else null;
                if (root != null and root != app.hwnd) {
                    _ = w.SendMessageW(root.?, w.WM_COMMAND, if (msg.wParam == 'H') MW_HTML else MW_HDR, 0);
                } else onCommand(if (msg.wParam == 'H') CMD_SAFE_HTML else CMD_HDR_REPORT, 0);
                continue;
            }
        }
        // Esc closes a message window
        if (msg.message == w.WM_KEYDOWN and msg.wParam == w.VK_ESCAPE) {
            const root = if (msg.hwnd) |h| w.GetAncestor(h, w.GA_ROOT) else null;
            if (root != null and root != app.hwnd) {
                _ = w.DestroyWindow(root.?);
                continue;
            }
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    closePst();
    cleanupTempFiles();
}
