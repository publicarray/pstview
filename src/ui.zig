//! Visual style for the GUI, after design/design-philosophy.md ("Sealed Signal"): an ink-navy
//! ground, paper-white for content, and a single amber accent used only where something needs
//! attention. Flat colour, hairline separators, generous spacing; native controls throughout.
//!
//! Two themes share the roles below: light (ink text on paper) and dark (paper text on an ink
//! ground). `setDark` switches; windows repaint from the palette, controls get the system's dark
//! visuals through `themeControl`, and the menu bar is painted here (`menuBarMessage`).

const std = @import("std");
const w = @import("win.zig");
const mime = @import("mime.zig");
const glyph = @import("glyph.zig");
const L = w.L;

// ---- palette (0xRRGGBB; convert with w.rgb). The names are roles: `ink` is the text colour and
// `white` the content ground in either theme.
pub var ink: u32 = 0x13233F;
pub var ink_soft: u32 = 0x606C80;
pub var paper: u32 = 0xF6F4EE;
pub const amber: u32 = 0xF5B700;
/// Left pane and chrome: a lighter paper.
pub var pane: u32 = 0xF9F8F5;
pub var hairline: u32 = 0xE3E1DA;
/// Secondary text.
pub var muted: u32 = 0x7C8595;
pub var white: u32 = 0xFFFFFF;
/// Selected / hot item in chrome painted here (the menu bar).
pub var select: u32 = 0xE4E9F2;
/// Title bars: ink with paper text in both themes.
pub var bar: u32 = 0x13233F;
pub const on_bar: u32 = 0xF6F4EE;
/// Amber dark enough to read as a glyph on the current ground.
pub var amber_glyph: u32 = 0xC98F00;

pub var dark = false;

pub fn setDark(on: bool) void {
    dark = on;
    const p: [10]u32 = if (on)
        .{ 0xE4E8EF, 0xA3ADBD, 0x131B29, 0x161F2E, 0x263247, 0x8490A3, 0x0F1724, 0x22324D, 0x0B1422, 0xE0A91A }
    else
        .{ 0x13233F, 0x606C80, 0xF6F4EE, 0xF9F8F5, 0xE3E1DA, 0x7C8595, 0xFFFFFF, 0xE4E9F2, 0x13233F, 0xC98F00 };
    ink, ink_soft, paper, pane, hairline, muted, white, select, bar, amber_glyph = p;
    loadDarkApi();
    // popup menus, scroll bars and common dialogs of this process follow the theme
    if (set_preferred_app_mode) |f| _ = f(if (on) 2 else 3); // ForceDark / ForceLight
    if (flush_menu_themes) |f| f();
}

/// True when Windows is set to dark mode for apps.
pub fn systemDark() bool {
    var key: ?w.HKEY = null;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), 0, w.KEY_READ, &key) != 0) return false;
    defer _ = w.RegCloseKey(key.?);
    var light: u32 = 1;
    var cb: u32 = 4;
    if (w.RegQueryValueExW(key.?, L("AppsUseLightTheme"), null, null, @ptrCast(&light), &cb) != 0) return false;
    return light == 0;
}

// The dark visuals of the common controls are reached through uxtheme exports that have ordinals
// but no names (Windows 10 1809 and later; absent on older systems, where controls stay light).
var allow_dark_for_window: ?*const fn (w.HWND, w.BOOL) callconv(.winapi) w.BOOL = null;
var set_preferred_app_mode: ?*const fn (c_int) callconv(.winapi) c_int = null;
var flush_menu_themes: ?*const fn () callconv(.winapi) void = null;
var dark_api_loaded = false;

fn loadDarkApi() void {
    if (dark_api_loaded) return;
    dark_api_loaded = true;
    const ux = w.LoadLibraryW(L("uxtheme.dll")) orelse return;
    if (w.GetProcAddress(ux, @ptrFromInt(133))) |p| allow_dark_for_window = @ptrCast(@alignCast(p));
    if (w.GetProcAddress(ux, @ptrFromInt(135))) |p| set_preferred_app_mode = @ptrCast(@alignCast(p));
    if (w.GetProcAddress(ux, @ptrFromInt(136))) |p| flush_menu_themes = @ptrCast(@alignCast(p));
}

/// Give a control the system visuals of the current theme (scroll bars, selection, button faces).
/// `light_theme` is the visual style used in the light theme (null = the control's default).
pub fn themeControl(h: w.HWND, light_theme: ?[*:0]const u16) void {
    loadDarkApi();
    if (allow_dark_for_window) |f| _ = f(h, @intFromBool(dark));
    _ = w.SetWindowTheme(h, if (dark) L("DarkMode_Explorer") else light_theme, null);
    _ = w.SendMessageW(h, 0x031A, 0, 0); // WM_THEMECHANGED
}

/// A list view's header: dark visuals; its text colour comes from `headerTextColor`.
pub fn themeHeader(header: w.HWND) void {
    loadDarkApi();
    if (allow_dark_for_window) |f| _ = f(header, @intFromBool(dark));
    _ = w.SetWindowTheme(header, if (dark) L("DarkMode_ItemsView") else null, null);
}

/// Subclass procedure for a list view: paints its header's text in the theme's text colour
/// (the dark header visuals keep the system's black text otherwise).
pub fn listSubclass(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM, _: usize, _: usize) callconv(w.WINAPI) w.LRESULT {
    if (msg == w.WM_NOTIFY and dark) {
        const nm: *const w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (nm.code == w.NM_CUSTOMDRAW) {
            const header: usize = @bitCast(w.SendMessageW(hwnd, w.LVM_GETHEADER, 0, 0));
            if (nm.hwndFrom != null and @intFromPtr(nm.hwndFrom.?) == header) {
                const cd: *const w.NMCUSTOMDRAW = @ptrCast(@alignCast(nm));
                if (cd.dwDrawStage == 0x1) return 0x20; // CDDS_PREPAINT -> CDRF_NOTIFYITEMDRAW
                if (cd.dwDrawStage == 0x10001) { // CDDS_ITEMPREPAINT
                    if (cd.hdc) |dc| _ = w.SetTextColor(dc, w.rgb(ink));
                    return 0;
                }
            }
        }
    }
    return w.DefSubclassProc(hwnd, msg, wp, lp);
}

// ---- menu bar (dark theme): Windows paints it light unless the window draws it itself, through
// the undocumented WM_UAHDRAWMENU / WM_UAHDRAWMENUITEM messages.

const WM_UAHDRAWMENU = 0x0091;
const WM_UAHDRAWMENUITEM = 0x0092;
const UahMenu = extern struct { hmenu: ?w.HMENU, hdc: ?w.HDC, flags: u32 };
const UahDrawMenuItem = extern struct { dis: w.DRAWITEMSTRUCT, um: UahMenu, position: c_int };
const objid_menu: i32 = -3;

/// Font for the menu bar items (the GUI's text font).
pub var menu_font: ?w.HFONT = null;

fn fillColor(dc: w.HDC, rc: w.RECT, color: u32) void {
    const br = w.CreateSolidBrush(w.rgb(color)) orelse return;
    _ = w.FillRect(dc, &rc, br);
    _ = w.DeleteObject(@ptrCast(br));
}

/// Handles the menu bar drawing messages in the dark theme; null = not handled (pass on).
pub fn menuBarMessage(hwnd: w.HWND, msg: u32, lp: w.LPARAM) ?w.LRESULT {
    if (!dark or (msg != WM_UAHDRAWMENU and msg != WM_UAHDRAWMENUITEM) or lp == 0) return null;
    if (msg == WM_UAHDRAWMENU) {
        const um: *const UahMenu = @ptrFromInt(@as(usize, @bitCast(lp)));
        var mbi: w.MENUBARINFO = .{};
        var wr: w.RECT = undefined;
        if (w.GetMenuBarInfo(hwnd, objid_menu, 0, &mbi) == 0 or w.GetWindowRect(hwnd, &wr) == 0) return null;
        const rc: w.RECT = .{ .left = mbi.rcBar.left - wr.left, .top = mbi.rcBar.top - wr.top, .right = mbi.rcBar.right - wr.left, .bottom = mbi.rcBar.bottom - wr.top };
        fillColor(um.hdc orelse return null, rc, pane);
        return 0;
    }
    const d: *const UahDrawMenuItem = @ptrFromInt(@as(usize, @bitCast(lp)));
    const dc = d.um.hdc orelse return null;
    var text: [128]u16 = undefined;
    var mii: w.MENUITEMINFOW = .{ .fMask = 0x40, .dwTypeData = &text, .cch = text.len - 1 }; // MIIM_STRING
    if (w.GetMenuItemInfoW(d.um.hmenu orelse return null, @intCast(d.position), 1, &mii) == 0) return null;
    const state = d.dis.itemState;
    const hot = (state & (0x40 | 0x1)) != 0; // ODS_HOTLIGHT | ODS_SELECTED
    const off = (state & (0x2 | 0x4 | 0x80)) != 0; // ODS_GRAYED | ODS_DISABLED | ODS_INACTIVE
    fillColor(dc, d.dis.rcItem, if (hot) select else pane);
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    _ = w.SetTextColor(dc, w.rgb(if (off) muted else ink));
    if (menu_font) |f| _ = w.SelectObject(dc, @ptrCast(f));
    var rc = d.dis.rcItem;
    const hide_prefix: u32 = if ((state & 0x100) != 0) 0x100000 else 0; // ODS_NOACCEL -> DT_HIDEPREFIX
    _ = w.DrawTextW(dc, &text, @intCast(mii.cch), &rc, w.DT_CENTER | w.DT_SINGLELINE | w.DT_VCENTER | hide_prefix);
    return 0;
}

/// The one-pixel line under the menu bar, which the system paints light: call after the default
/// handling of WM_NCPAINT and WM_NCACTIVATE.
pub fn paintMenuBarLine(hwnd: w.HWND) void {
    if (!dark) return;
    var mbi: w.MENUBARINFO = .{};
    if (w.GetMenuBarInfo(hwnd, objid_menu, 0, &mbi) == 0) return;
    var client: w.RECT = undefined;
    var wr: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &client);
    _ = w.MapWindowPoints(hwnd, null, &client, 2);
    if (w.GetWindowRect(hwnd, &wr) == 0) return;
    const line: w.RECT = .{ .left = client.left - wr.left, .top = client.top - wr.top - 1, .right = client.right - wr.left, .bottom = client.top - wr.top };
    const dc = w.GetWindowDC(hwnd) orelse return;
    fillColor(dc, line, pane);
    _ = w.ReleaseDC(hwnd, dc);
}

// ---- folder glyphs (Segoe Fluent Icons / Segoe MDL2 Assets, both ship with Windows)

pub const Glyph = glyph.Glyph;
pub const folderGlyph = glyph.folderGlyph;

const Tone = enum { soft, strong, amber };
const glyph_cp = std.enums.directEnumArray(Glyph, struct { u16, Tone }, 0, .{
    .folder = .{ 0xE8B7, .soft },
    .mailbox = .{ 0xE7B8, .strong },
    .inbox = .{ 0xE715, .soft },
    .sent = .{ 0xE724, .soft },
    .drafts = .{ 0xE70F, .soft },
    .deleted = .{ 0xE74D, .soft },
    .junk = .{ 0xE7BA, .soft },
    .archive = .{ 0xE7B8, .soft },
    .calendar = .{ 0xE787, .soft },
    .contacts = .{ 0xE77B, .soft },
    .tasks = .{ 0xE9D5, .soft },
    .notes = .{ 0xE70B, .soft },
    .journal = .{ 0xE81C, .soft },
    .search = .{ 0xE721, .soft },
    .hidden = .{ 0xED1A, .soft },
    // the one amber figure: items brought back from deleted space
    .recovered = .{ 0xE777, .amber },
    .document = .{ 0xE8A5, .soft },
});

/// Image list with every `Glyph`, `px` pixels square, drawn in its palette colour with alpha.
pub fn glyphList(px: i32) ?w.HIMAGELIST {
    const n: i32 = @intCast(std.enums.values(Glyph).len);
    const il = w.ImageList_Create(px, px, w.ILC_COLOR32, n, 0) orelse return null;
    const dc = w.CreateCompatibleDC(null) orelse return il;
    defer _ = w.DeleteDC(dc);
    const font = iconFont(dc, -px) orelse return il;
    defer _ = w.DeleteObject(font);
    for (std.enums.values(Glyph)) |g| {
        const cp, const tone = glyph_cp[@intFromEnum(g)];
        const color = switch (tone) {
            .soft => ink_soft,
            .strong => ink,
            .amber => amber_glyph,
        };
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

/// Repaint the welcome screen in the current theme.
pub fn retheme() void {
    if (welcome.paper_brush) |b| _ = w.DeleteObject(@ptrCast(b));
    welcome.paper_brush = w.CreateSolidBrush(w.rgb(paper));
    for ([_]?w.HWND{ welcome.open_file, welcome.open_folder, welcome.install }) |b| if (b) |h| themeControl(h, null);
    if (welcome.hwnd) |h| _ = w.InvalidateRect(h, null, 1);
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

// ---- pstview's own dialogs (instead of system message boxes, which chime)

pub const DialogKind = enum { info, warning, err, about };

pub const DialogSpec = struct {
    kind: DialogKind = .info,
    /// Bold first line; empty = none.
    heading: []const u8 = "",
    /// Selectable body text (so hashes, paths and errors can be copied).
    body: []const u8 = "",
    /// About only: version line, and a muted detail line (e.g. installed / portable).
    version: []const u8 = "",
    detail: []const u8 = "",
    link: ?[:0]const u16 = null,
    link_url: ?[:0]const u16 = null,
    buttons: []const Button = &.{.{ .id = w.IDOK, .text = L("OK") }},
};

const DialogState = struct {
    spec: *const DialogSpec,
    scale: f32,
    result: i32 = w.IDCANCEL,
    done: bool = false,
    heading_font: ?w.HFONT = null,
    text_font: ?w.HFONT = null,
    title_font: ?w.HFONT = null,
    glyph_font: ?w.HFONT = null,
    paper_brush: ?w.HBRUSH = null,
    pane_brush: ?w.HBRUSH = null,
    hair_brush: ?w.HBRUSH = null,
    icon: ?w.HICON = null,
    edit: ?w.HWND = null,
    footer_top: i32 = 0,
    text_x: i32 = 0,

    fn sc(self: *const DialogState, v: i32) i32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * self.scale));
    }
};

const DIALOG_CLASS = L("pstview.dialog");
var dialog_registered = false;

/// Show a modal pstview dialog and return the id of the button pressed (IDCANCEL for Esc / close).
pub fn dialog(owner: ?w.HWND, inst: ?w.HINSTANCE, spec: DialogSpec) i32 {
    if (!dialog_registered) {
        const wc: w.WNDCLASSEXW = .{ .lpfnWndProc = dialogProc, .hInstance = inst, .hCursor = w.LoadCursorW(null, w.IDC_ARROW), .lpszClassName = DIALOG_CLASS };
        _ = w.RegisterClassExW(&wc);
        dialog_registered = true;
    }
    const dpi: u32 = if (owner) |o| w.GetDpiForWindow(o) else w.GetDpiForSystem();
    var st: DialogState = .{ .spec = &spec, .scale = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96.0 };
    st.text_font = w.CreateFontW(-st.sc(14), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
    st.heading_font = w.CreateFontW(-st.sc(17), 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI Semibold"));
    st.title_font = w.CreateFontW(-st.sc(34), 0, 0, 0, 300, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI Light"));
    st.paper_brush = w.CreateSolidBrush(w.rgb(paper));
    st.pane_brush = w.CreateSolidBrush(w.rgb(pane));
    st.hair_brush = w.CreateSolidBrush(w.rgb(hairline));
    defer {
        inline for (.{ st.text_font, st.heading_font, st.title_font, st.glyph_font }) |f| if (f) |h| {
            _ = w.DeleteObject(@ptrCast(h));
        };
        inline for (.{ st.paper_brush, st.pane_brush, st.hair_brush }) |b| if (b) |h| {
            _ = w.DeleteObject(@ptrCast(h));
        };
    }
    const about = spec.kind == .about;
    const P = st.sc(24);
    const cw = st.sc(if (about) 520 else 470);
    st.icon = if (about) @ptrCast(w.LoadImageW(inst, 1, w.IMAGE_ICON, st.sc(64), st.sc(64), 0)) else null;
    st.text_x = if (about) P else P + st.sc(52);

    // measure the text to size the window
    const sdc = w.GetDC(null) orelse return w.IDCANCEL;
    if (!about) st.glyph_font = iconFont(sdc, -st.sc(30));
    const text_w = cw - st.text_x - P;
    const heading_h = if (spec.heading.len > 0) measure(sdc, st.heading_font, spec.heading, text_w) + st.sc(8) else 0;
    const body_full = if (spec.body.len > 0) measure(sdc, st.text_font, spec.body, text_w) else 0;
    _ = w.ReleaseDC(null, sdc);
    const body_max = st.sc(380);
    const body_h = @min(body_full, body_max);
    const top_block = if (about) st.sc(64 + 22) else heading_h;
    const link_h: i32 = if (spec.link != null) st.sc(30) else 0;
    const detail_h: i32 = if (spec.detail.len > 0) st.sc(22) else 0;
    const content_h = @max(top_block + body_h + link_h + detail_h, if (about) 0 else st.sc(40));
    st.footer_top = P + content_h + P;
    const ch = st.footer_top + st.sc(60);

    const style = w.WS_POPUP | w.WS_CAPTION | w.WS_SYSMENU | w.WS_CLIPCHILDREN;
    const ex = w.WS_EX_DLGMODALFRAME;
    var wr: w.RECT = .{ .left = 0, .top = 0, .right = cw, .bottom = ch };
    _ = w.AdjustWindowRectExForDpi(&wr, style, 0, ex, if (dpi == 0) 96 else dpi);
    const ww = wr.right - wr.left;
    const wh = wr.bottom - wr.top;
    var x: i32 = @divTrunc(w.GetSystemMetrics(w.SM_CXSCREEN) - ww, 2);
    var y: i32 = @divTrunc(w.GetSystemMetrics(w.SM_CYSCREEN) - wh, 2);
    if (owner) |o| {
        var orc: w.RECT = undefined;
        if (w.GetWindowRect(o, &orc) != 0) {
            x = orc.left + @divTrunc(orc.right - orc.left - ww, 2);
            y = orc.top + @max(@divTrunc(orc.bottom - orc.top - wh, 3), 0);
        }
    }
    const caption = if (about) L("About pstview") else L("pstview");
    const hwnd = w.CreateWindowExW(ex, DIALOG_CLASS, caption, style, x, y, ww, wh, owner, null, inst, @ptrCast(&st)) orelse return w.IDCANCEL;
    const cap = w.rgb(bar);
    const cap_text = w.rgb(on_bar);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_CAPTION_COLOR, &cap, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_BORDER_COLOR, &cap, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_TEXT_COLOR, &cap_text, 4);

    // body: a borderless read-only edit, so the text can be selected and copied
    var yy = P + top_block;
    if (spec.body.len > 0) {
        const scroll: u32 = if (body_full > body_max) w.WS_VSCROLL else 0;
        const eb = w.CreateWindowExW(0, L("EDIT"), null, w.WS_CHILD | w.WS_VISIBLE | w.ES_MULTILINE | w.ES_READONLY | scroll, st.text_x, yy, text_w, body_h, hwnd, @ptrFromInt(901), inst, null);
        if (eb) |e| {
            _ = w.SendMessageW(e, w.WM_SETFONT, @intFromPtr(st.text_font), 1);
            _ = w.SendMessageW(e, w.EM_SETMARGINS, w.EC_LEFTMARGIN | w.EC_RIGHTMARGIN, 0);
            var tb: std.ArrayList(u16) = .empty;
            defer tb.deinit(std.heap.page_allocator);
            crlfWide(std.heap.page_allocator, &tb, spec.body);
            _ = w.SetWindowTextW(e, @ptrCast(tb.items.ptr));
            if (dark) themeControl(e, null); // its scroll bar
            st.edit = e;
        }
        yy += body_h;
    }
    if (spec.detail.len > 0) yy += detail_h; // painted
    if (spec.link) |lt| {
        const lk = w.CreateWindowExW(0, L("SysLink"), lt, w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP, st.text_x, yy + st.sc(6), text_w, st.sc(22), hwnd, @ptrFromInt(900), inst, null);
        if (lk) |h| _ = w.SendMessageW(h, w.WM_SETFONT, @intFromPtr(st.text_font), 1);
    }

    // buttons, right-aligned in the footer; the first is the default
    const bw = st.sc(104);
    const bh = st.sc(32);
    var bx = cw - P - bw * @as(i32, @intCast(spec.buttons.len)) - st.sc(8) * @as(i32, @intCast(spec.buttons.len -| 1));
    var first: ?w.HWND = null;
    for (spec.buttons, 0..) |b, i| {
        const bstyle = w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | (if (i == 0) w.BS_DEFPUSHBUTTON else 0);
        const h = w.CreateWindowExW(0, L("BUTTON"), b.text, bstyle, bx, st.footer_top + @divTrunc(st.sc(60) - bh, 2), bw, bh, hwnd, @ptrFromInt(@as(usize, @intCast(b.id))), inst, null);
        if (h) |bh_| {
            _ = w.SendMessageW(bh_, w.WM_SETFONT, @intFromPtr(st.text_font), 1);
            if (dark) themeControl(bh_, null);
            if (i == 0) first = bh_;
        }
        bx += bw + st.sc(8);
    }

    if (owner) |o| _ = w.EnableWindow(o, 0);
    _ = w.ShowWindow(hwnd, w.SW_SHOW);
    if (first) |f| _ = w.SetFocus(f);
    var msg: w.MSG = undefined;
    var quit = false;
    while (!st.done) {
        if (w.GetMessageW(&msg, null, 0, 0) <= 0) {
            quit = true;
            break;
        }
        if (w.IsDialogMessageW(hwnd, &msg) != 0) continue;
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    // re-enable the owner before the dialog goes, so activation returns to it
    if (owner) |o| _ = w.EnableWindow(o, 1);
    _ = w.DestroyWindow(hwnd);
    if (quit) w.PostQuitMessage(0);
    return st.result;
}

fn measure(dc: w.HDC, font: ?w.HFONT, text: []const u8, width: i32) i32 {
    var tb: std.ArrayList(u16) = .empty;
    defer tb.deinit(std.heap.page_allocator);
    crlfWide(std.heap.page_allocator, &tb, text);
    if (font) |f| _ = w.SelectObject(dc, @ptrCast(f));
    var r: w.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    _ = w.DrawTextW(dc, tb.items.ptr, @intCast(tb.items.len -| 1), &r, w.DT_CALCRECT | w.DT_WORDBREAK | w.DT_EDITCONTROL | w.DT_NOPREFIX);
    return r.bottom - r.top + 4;
}

/// UTF-8 -> NUL-terminated UTF-16 with CRLF line ends (what the EDIT control needs).
fn crlfWide(a: std.mem.Allocator, out: *std.ArrayList(u16), text: []const u8) void {
    const s = mime.repairUtf8(a, text) catch text; // message-derived text may not be valid UTF-8
    const view = std.unicode.Utf8View.init(s) catch return out.append(a, 0) catch {};
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\r') continue;
        if (cp == '\n') {
            out.appendSlice(a, &.{ '\r', '\n' }) catch return;
        } else if (cp >= 0x10000) {
            const v = cp - 0x10000;
            out.appendSlice(a, &.{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) }) catch return;
        } else out.append(a, @intCast(cp)) catch return;
    }
    out.append(a, 0) catch {};
}

fn dialogProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (msg == w.WM_CREATE) {
        const cs: *const ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(cs.*.?)));
        return 0;
    }
    const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (raw == 0) return w.DefWindowProcW(hwnd, msg, wp, lp);
    const st: *DialogState = @ptrFromInt(@as(usize, @bitCast(raw)));
    switch (msg) {
        w.WM_COMMAND => {
            // Only a button click ends the dialog: the body text box also sends WM_COMMAND
            // (EN_SETFOCUS etc.) when clicked. Enter / Esc arrive as IDOK / IDCANCEL clicks.
            const id: i32 = @intCast(wp & 0xFFFF);
            const code: u16 = @truncate(wp >> 16);
            if (code != w.BN_CLICKED) return 0;
            const known = for (st.spec.buttons) |b| {
                if (b.id == id) break true;
            } else id == w.IDOK or id == w.IDCANCEL;
            if (!known) return 0;
            st.result = id;
            st.done = true;
            return 0;
        },
        w.WM_CLOSE => {
            st.result = w.IDCANCEL;
            st.done = true;
            return 0;
        },
        w.WM_NOTIFY => {
            const nm: *const w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (nm.idFrom == 900 and (nm.code == w.NM_CLICK or nm.code == w.NM_RETURN)) {
                if (st.spec.link_url) |u| _ = w.ShellExecuteW(hwnd, L("open"), u, null, null, w.SW_SHOWNORMAL);
            }
            return 0;
        },
        w.WM_CTLCOLORSTATIC => {
            // the read-only body and the link sit on the paper ground
            const dc: w.HDC = @ptrFromInt(wp);
            _ = w.SetBkColor(dc, w.rgb(paper));
            _ = w.SetTextColor(dc, w.rgb(ink));
            return @bitCast(@intFromPtr(st.paper_brush));
        },
        w.WM_CTLCOLORBTN => return @bitCast(@intFromPtr(st.pane_brush)), // buttons sit on the footer band
        w.WM_ERASEBKGND => return 1,
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const dc = w.BeginPaint(hwnd, &ps) orelse return 0;
            paintDialog(hwnd, dc, st);
            _ = w.EndPaint(hwnd, &ps);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn paintDialog(hwnd: w.HWND, dc: w.HDC, st: *DialogState) void {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    const spec = st.spec;
    var top: w.RECT = rc;
    top.bottom = st.footer_top;
    _ = w.FillRect(dc, &top, st.paper_brush);
    var foot: w.RECT = rc;
    foot.top = st.footer_top;
    _ = w.FillRect(dc, &foot, st.pane_brush);
    foot.bottom = foot.top + 1;
    _ = w.FillRect(dc, &foot, st.hair_brush);
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    const P = st.sc(24);
    var buf: [512]u16 = undefined;
    switch (spec.kind) {
        .about => {
            if (st.icon) |ic| _ = w.DrawIconEx(dc, P, P, ic, st.sc(64), st.sc(64), 0, null, w.DI_NORMAL);
            const tx = P + st.sc(64 + 18);
            var r: w.RECT = .{ .left = tx, .top = P - st.sc(2), .right = rc.right - P, .bottom = P + st.sc(44) };
            drawText(dc, st.title_font, ink, L("pstview"), &r, w.DT_SINGLELINE);
            r = .{ .left = tx, .top = P + st.sc(44), .right = rc.right - P, .bottom = P + st.sc(66) };
            drawText(dc, st.text_font, muted, wide(&buf, spec.version), &r, w.DT_SINGLELINE | w.DT_END_ELLIPSIS);
        },
        else => {
            if (st.glyph_font) |gf| {
                const cp: u16, const color: u32 = switch (spec.kind) {
                    .info => .{ 0xE946, ink },
                    .warning => .{ 0xE7BA, amber_glyph },
                    else => .{ 0xE783, if (dark) 0xFF7B72 else 0xB3261E },
                };
                var gr: w.RECT = .{ .left = P, .top = P - st.sc(2), .right = P + st.sc(40), .bottom = P + st.sc(40) };
                const g = [1]u16{cp};
                drawText(dc, gf, color, &g, &gr, w.DT_SINGLELINE);
            }
            if (spec.heading.len > 0) {
                var r: w.RECT = .{ .left = st.text_x, .top = P, .right = rc.right - P, .bottom = st.footer_top };
                drawText(dc, st.heading_font, ink, wide(&buf, spec.heading), &r, w.DT_WORDBREAK);
            }
        },
    }
    if (spec.detail.len > 0) {
        const ey = if (st.edit) |e| blk: {
            var er: w.RECT = undefined;
            _ = w.GetWindowRect(e, &er);
            break :blk er.bottom - er.top;
        } else 0;
        const y0 = P + (if (spec.kind == .about) st.sc(64 + 22) else 0) + ey;
        var r: w.RECT = .{ .left = st.text_x, .top = y0 + st.sc(4), .right = rc.right - P, .bottom = y0 + st.sc(24) };
        drawText(dc, st.text_font, muted, wide(&buf, spec.detail), &r, w.DT_SINGLELINE | w.DT_END_ELLIPSIS | 0x4000); // DT_PATH_ELLIPSIS
    }
}

/// UTF-8 into a fixed UTF-16 buffer (truncated), without terminator.
fn wide(buf: []u16, s: []const u8) []const u16 {
    const n = std.unicode.wtf8ToWtf16Le(buf[0..@min(buf.len, s.len)], s[0..@min(buf.len, s.len)]) catch return buf[0..0];
    return buf[0..n];
}
