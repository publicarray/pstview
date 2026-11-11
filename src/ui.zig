//! Visual style for the GUI, after design/design-philosophy.md ("Sealed Signal"): an ink-navy
//! ground, paper-white for content, and a single amber accent used only where something needs
//! attention. Flat colour, hairline separators, generous spacing; native controls throughout.

const std = @import("std");
const w = @import("win.zig");
const L = w.L;

// ---- palette (0xRRGGBB; convert with w.rgb)
pub const ink: u32 = 0x13233F;
pub const ink_soft: u32 = 0x606C80;
pub const paper: u32 = 0xF6F4EE;
pub const amber: u32 = 0xF5B700;
/// Left pane and chrome: a lighter paper.
pub const pane: u32 = 0xF9F8F5;
pub const hairline: u32 = 0xE3E1DA;
/// Secondary text.
pub const muted: u32 = 0x7C8595;
pub const white: u32 = 0xFFFFFF;

// ---- folder glyphs (Segoe Fluent Icons / Segoe MDL2 Assets, both ship with Windows)

pub const Glyph = enum(u8) { folder, mailbox, inbox, sent, drafts, deleted, junk, archive, calendar, contacts, tasks, notes, journal, search, hidden, recovered, document };

const glyph_cp = std.enums.directEnumArray(Glyph, struct { u16, u32 }, 0, .{
    .folder = .{ 0xE8B7, ink_soft },
    .mailbox = .{ 0xE7B8, ink },
    .inbox = .{ 0xE715, ink_soft },
    .sent = .{ 0xE724, ink_soft },
    .drafts = .{ 0xE70F, ink_soft },
    .deleted = .{ 0xE74D, ink_soft },
    .junk = .{ 0xE7BA, ink_soft },
    .archive = .{ 0xE7B8, ink_soft },
    .calendar = .{ 0xE787, ink_soft },
    .contacts = .{ 0xE77B, ink_soft },
    .tasks = .{ 0xE9D5, ink_soft },
    .notes = .{ 0xE70B, ink_soft },
    .journal = .{ 0xE81C, ink_soft },
    .search = .{ 0xE721, ink_soft },
    .hidden = .{ 0xED1A, ink_soft },
    // the one amber figure: items brought back from deleted space
    .recovered = .{ 0xE777, 0xC98F00 },
    .document = .{ 0xE8A5, ink_soft },
});

/// Glyph for a mailbox folder, from its container class and well-known names.
pub fn folderGlyph(name: []const u8, class: []const u8) Glyph {
    const ic = std.ascii.startsWithIgnoreCase;
    if (ic(class, "IPF.Appointment")) return .calendar;
    if (ic(class, "IPF.Contact")) return .contacts;
    if (ic(class, "IPF.Task")) return .tasks;
    if (ic(class, "IPF.StickyNote")) return .notes;
    if (ic(class, "IPF.Journal")) return .journal;
    const eq = std.ascii.eqlIgnoreCase;
    const names = [_]struct { []const u8, Glyph }{
        .{ "Inbox", .inbox },                .{ "Sent Items", .sent },          .{ "Sent", .sent },
        .{ "Sent Mail", .sent },             .{ "Outbox", .sent },              .{ "Drafts", .drafts },
        .{ "Deleted Items", .deleted },      .{ "Trash", .deleted },            .{ "Bin", .deleted },
        .{ "Junk Email", .junk },            .{ "Junk E-mail", .junk },         .{ "Junk", .junk },
        .{ "Spam", .junk },                  .{ "Archive", .archive },          .{ "Calendar", .calendar },
        .{ "Contacts", .contacts },          .{ "Tasks", .tasks },              .{ "Notes", .notes },
        .{ "Journal", .journal },            .{ "Recoverable Items", .deleted }, .{ "Search Folders", .search },
        .{ "Finder", .search },
    };
    for (names) |n| if (eq(name, n[0])) return n[1];
    return .folder;
}

/// Image list with every `Glyph`, `px` pixels square, drawn in its palette colour with alpha.
pub fn glyphList(px: i32) ?w.HIMAGELIST {
    const n: i32 = @intCast(std.enums.values(Glyph).len);
    const il = w.ImageList_Create(px, px, w.ILC_COLOR32, n, 0) orelse return null;
    const dc = w.CreateCompatibleDC(null) orelse return il;
    defer _ = w.DeleteDC(dc);
    const font = iconFont(dc, -px) orelse return il;
    defer _ = w.DeleteObject(font);
    for (std.enums.values(Glyph)) |g| {
        const cp, const color = glyph_cp[@intFromEnum(g)];
        const bmp = glyphBitmap(dc, font, px, cp, color) orelse continue;
        _ = w.ImageList_Add(il, bmp, null);
        _ = w.DeleteObject(bmp);
    }
    return il;
}

/// The icon font: Segoe Fluent Icons (Windows 11), else Segoe MDL2 Assets (Windows 10).
pub fn iconFont(dc: w.HDC, height: i32) ?w.HFONT {
    for ([_][:0]const u16{ L("Segoe Fluent Icons"), L("Segoe MDL2 Assets") }) |face| {
        const f = w.CreateFontW(height, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, face) orelse continue;
        const old = w.SelectObject(dc, @ptrCast(f));
        var buf: [64]u16 = undefined;
        buf[0] = 0;
        const len = w.GetTextFaceW(dc, buf.len, &buf);
        _ = w.SelectObject(dc, old);
        if (len > 0 and std.mem.eql(u16, std.mem.sliceTo(&buf, 0), face)) return f;
        _ = w.DeleteObject(f);
    }
    return null;
}

/// One glyph as a premultiplied 32-bit bitmap: draw it white on black with greyscale
/// anti-aliasing, then use the coverage as alpha for `color`.
fn glyphBitmap(dc: w.HDC, font: w.HFONT, px: i32, cp: u16, color: u32) ?w.HBITMAP {
    var bits: ?*anyopaque = null;
    const bmi: w.BITMAPINFOHEADER = .{ .biWidth = px, .biHeight = -px };
    const bmp = w.CreateDIBSection(dc, &bmi, 0, &bits, null, 0) orelse return null;
    const pixels: [*]u32 = @ptrCast(@alignCast(bits.?));
    const count: usize = @intCast(px * px);
    @memset(pixels[0..count], 0);
    const old_bmp = w.SelectObject(dc, @ptrCast(bmp));
    const old_font = w.SelectObject(dc, @ptrCast(font));
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    _ = w.SetTextColor(dc, 0xFFFFFF);
    var rc: w.RECT = .{ .left = 0, .top = 0, .right = px, .bottom = px };
    const s = [1]u16{cp};
    _ = w.DrawTextW(dc, &s, 1, &rc, w.DT_CENTER | w.DT_VCENTER | w.DT_SINGLELINE | w.DT_NOPREFIX);
    _ = w.GdiFlush();
    _ = w.SelectObject(dc, old_font);
    _ = w.SelectObject(dc, old_bmp);
    const r: u32 = (color >> 16) & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;
    for (pixels[0..count]) |*p| {
        const cov = @max((p.* >> 16) & 0xFF, @max((p.* >> 8) & 0xFF, p.* & 0xFF));
        p.* = (cov << 24) | ((r * cov / 255) << 16) | ((g * cov / 255) << 8) | (b * cov / 255);
    }
    return bmp;
}

// ---- task dialogs

pub const Button = struct { id: i32, text: [:0]const u16 };
pub const DialogResult = struct { button: i32, verified: bool };

/// A task dialog with command-link buttons (falls back to a message box if comctl32 v6 is missing).
pub fn taskDialog(owner: ?w.HWND, icon: ?w.HICON, instruction: [:0]const u16, content: [:0]const u16, buttons: []const Button, verification: ?[:0]const u16) DialogResult {
    var tb: [8]w.TASKDIALOG_BUTTON = undefined;
    const nb = @min(buttons.len, tb.len);
    for (buttons[0..nb], 0..) |bt, i| tb[i] = .{ .nButtonID = bt.id, .pszButtonText = bt.text.ptr };
    const cfg: w.TASKDIALOGCONFIG = .{
        .hwndParent = owner,
        .dwFlags = w.TDF_USE_COMMAND_LINKS | w.TDF_ALLOW_DIALOG_CANCELLATION | w.TDF_POSITION_RELATIVE_TO_WINDOW | (if (icon != null) w.TDF_USE_HICON_MAIN else 0),
        .dwCommonButtons = w.TDCBF_CANCEL_BUTTON,
        .pszWindowTitle = L("pstview"),
        .hMainIcon = if (icon) |i| @ptrCast(i) else null,
        .pszMainInstruction = instruction.ptr,
        .pszContent = content.ptr,
        .cButtons = @intCast(nb),
        .pButtons = &tb,
        .nDefaultButton = if (nb > 0) buttons[0].id else 0,
        .pszVerificationText = if (verification) |v| v.ptr else null,
    };
    var pressed: i32 = w.IDCANCEL;
    var checked: w.BOOL = 0;
    if (w.TaskDialogIndirect(&cfg, &pressed, null, &checked) < 0) {
        // no comctl32 v6: a plain yes/no on the first button
        const r = w.MessageBoxW(owner, content.ptr, instruction.ptr, 0x4 | 0x20); // MB_YESNO | MB_ICONQUESTION
        return .{ .button = if (r == 6 and nb > 0) buttons[0].id else w.IDCANCEL, .verified = false };
    }
    return .{ .button = pressed, .verified = checked != 0 };
}

// ---- the welcome screen (shown while no mailbox is open)

pub const Welcome = struct {
    hwnd: ?w.HWND = null,
    open_file: ?w.HWND = null,
    open_folder: ?w.HWND = null,
    install: ?w.HWND = null,
    scale: f32 = 1,
    version: []const u8 = "",
    title_font: ?w.HFONT = null,
    text_font: ?w.HFONT = null,
    small_font: ?w.HFONT = null,
    icon: ?w.HICON = null,
    paper_brush: ?w.HBRUSH = null,

    fn sc(self: *const Welcome, v: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * self.scale));
    }
};

pub var welcome: Welcome = .{};

pub const WELCOME_CLASS = L("pstview.welcome");

/// Create the welcome window and its command links. `ids` are the WM_COMMAND ids sent to `main`.
pub fn createWelcome(main: w.HWND, inst: ?w.HINSTANCE, scale: f32, version: []const u8, ids: [3]u16) void {
    const wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = welcomeProc,
        .hInstance = inst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .lpszClassName = WELCOME_CLASS,
    };
    _ = w.RegisterClassExW(&wc);
    welcome.scale = scale;
    welcome.version = version;
    welcome.paper_brush = w.CreateSolidBrush(w.rgb(paper));
    welcome.title_font = w.CreateFontW(-welcome.sc(40), 0, 0, 0, 300, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI Light"));
    welcome.text_font = w.CreateFontW(-welcome.sc(15), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    welcome.small_font = w.CreateFontW(-welcome.sc(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    welcome.icon = @ptrCast(w.LoadImageW(inst, 1, w.IMAGE_ICON, welcome.sc(72), welcome.sc(72), 0));
    const h = w.CreateWindowExW(0, WELCOME_CLASS, null, w.WS_CHILD | w.WS_CLIPCHILDREN, 0, 0, 0, 0, main, null, inst, null) orelse return;
    welcome.hwnd = h;
    const style = w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.BS_COMMANDLINK;
    welcome.open_file = commandLink(h, inst, style, ids[0], L("Open a mailbox file\u{2026}"), L("Outlook PST or OST, or an MBOX file. Select several PST parts to merge them."));
    welcome.open_folder = commandLink(h, inst, style, ids[1], L("Open a folder\u{2026}"), L("A Thunderbird profile, an Apple Mail export, a Google Takeout folder, or a folder of PST parts."));
    welcome.install = commandLink(h, inst, w.WS_CHILD | w.WS_TABSTOP | w.BS_COMMANDLINK, ids[2], L("Install pstview for this user"), L("Adds a Start menu entry and opens .pst, .ost and .mbox files from Explorer. No administrator rights needed."));
}

fn commandLink(parent: w.HWND, inst: ?w.HINSTANCE, style: u32, id: u16, text: [:0]const u16, note: [:0]const u16) ?w.HWND {
    const b = w.CreateWindowExW(0, L("BUTTON"), text, style, 0, 0, 0, 0, parent, @ptrFromInt(id), inst, null) orelse return null;
    _ = w.SendMessageW(b, w.BCM_SETNOTE, 0, @intCast(@intFromPtr(note.ptr)));
    return b;
}

/// Show or hide the install offer (hidden once installed).
pub fn showInstallOffer(show: bool) void {
    if (welcome.install) |b| _ = w.ShowWindow(b, if (show) w.SW_SHOW else w.SW_HIDE);
    layoutWelcome();
}

const col_w = 480;

fn columnLeft(rc: w.RECT) i32 {
    return @divTrunc(rc.right - welcome.sc(col_w), 2);
}

/// Top of the content block, so that it sits slightly above the vertical centre.
fn contentTop(rc: w.RECT) i32 {
    const install_visible = if (welcome.install) |b| w.IsWindowVisible(b) != 0 else false;
    const block = welcome.sc(if (install_visible) 470 else 390);
    return @max(welcome.sc(24), @divTrunc(rc.bottom - block, 2) - welcome.sc(20));
}

pub fn layoutWelcome() void {
    const h = welcome.hwnd orelse return;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(h, &rc);
    const x = columnLeft(rc);
    var y = contentTop(rc) + welcome.sc(72 + 20 + 52 + 28 + 28);
    const bw = welcome.sc(col_w);
    const bh = welcome.sc(66);
    for ([_]?w.HWND{ welcome.open_file, welcome.open_folder, welcome.install }, 0..) |b, i| {
        const btn = b orelse continue;
        if (i == 2) {
            if (w.IsWindowVisible(btn) == 0) continue;
            y += welcome.sc(26); // set the install offer apart
        }
        _ = w.MoveWindow(btn, x, y, bw, bh, 1);
        y += bh + welcome.sc(6);
    }
    _ = w.InvalidateRect(h, null, 1);
}

fn welcomeProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_SIZE => {
            layoutWelcome();
            return 0;
        },
        w.WM_ERASEBKGND, w.WM_PRINTCLIENT => {
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(hwnd, &rc);
            _ = w.FillRect(@ptrFromInt(wp), &rc, welcome.paper_brush);
            return 1;
        },
        w.WM_CTLCOLORBTN => return @bitCast(@intFromPtr(welcome.paper_brush)), // handles may be sign-extended
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const dc = w.BeginPaint(hwnd, &ps) orelse return 0;
            paintWelcome(hwnd, dc);
            _ = w.EndPaint(hwnd, &ps);
            return 0;
        },
        w.WM_COMMAND => {
            // command links: forward to the main window
            if (w.GetParent(hwnd)) |main| _ = w.SendMessageW(main, w.WM_COMMAND, wp & 0xFFFF, 0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn drawText(dc: w.HDC, font: ?w.HFONT, color: u32, text: []const u16, rc: *w.RECT, flags: u32) void {
    if (font) |f| _ = w.SelectObject(dc, @ptrCast(f));
    _ = w.SetTextColor(dc, w.rgb(color));
    _ = w.DrawTextW(dc, text.ptr, @intCast(text.len), rc, flags | w.DT_NOPREFIX);
}

fn paintWelcome(hwnd: w.HWND, dc: w.HDC) void {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    const x = columnLeft(rc);
    const cw = welcome.sc(col_w);
    var y = contentTop(rc);
    if (welcome.icon) |ic| _ = w.DrawIconEx(dc, x, y, ic, welcome.sc(72), welcome.sc(72), 0, null, w.DI_NORMAL);
    y += welcome.sc(72 + 20);
    var r: w.RECT = .{ .left = x, .top = y, .right = x + cw, .bottom = y + welcome.sc(52) };
    drawText(dc, welcome.title_font, ink, L("pstview"), &r, w.DT_SINGLELINE);
    y += welcome.sc(52);
    r = .{ .left = x, .top = y, .right = x + cw, .bottom = y + welcome.sc(24) };
    drawText(dc, welcome.text_font, ink_soft, L("Read-only viewer for Outlook PST / OST and MBOX mailboxes"), &r, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);
    y += welcome.sc(28);
    r = .{ .left = x, .top = y, .right = x + cw, .bottom = y + welcome.sc(20) };
    drawText(dc, welcome.small_font, muted, L("Open a mailbox below, or drop files and folders anywhere in this window."), &r, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);

    // footer: the read-only promise, version at the right (the amber seal lives in the status bar)
    const fy = rc.bottom - welcome.sc(40);
    r = .{ .left = x, .top = fy, .right = x + cw, .bottom = fy + welcome.sc(20) };
    drawText(dc, welcome.small_font, ink_soft, L("Sources are opened read-only and never modified."), &r, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);
    var vb: [96]u16 = undefined;
    const vn = std.unicode.wtf8ToWtf16Le(&vb, welcome.version) catch 0;
    r = .{ .left = x, .top = fy, .right = x + cw, .bottom = fy + welcome.sc(20) };
    drawText(dc, welcome.small_font, muted, vb[0..vn], &r, w.DT_SINGLELINE | 0x2); // DT_RIGHT
}
