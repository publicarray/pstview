//! pstview - PST / OST / MBOX viewer and exporter (read-only), Windows entry point.
//!
//! The windows are plain Win32 windows whose content is WebView2, the web view that ships with
//! Windows 11 (and with Windows 10 through the Evergreen runtime). They show the same page
//! (webui.html) with the same model behind it (webapp.zig) as on macOS and Linux; this file
//! provides the windows, the web views and the file dialogs.
//!
//! No loader DLL is shipped: the installed runtime is found in the registry and its
//! EmbeddedBrowserWebView.dll is called directly (what WebView2Loader.dll does).
//!
//! Safety, on top of the sanitised and CSP-locked documents of render.zig: messages are shown in
//! sandboxed frames (no scripts); every navigation after the page itself, every frame navigation
//! that is not an about: document and every new window is refused, so a link in a message leads
//! nowhere. Script dialogs, host objects, dev tools and the browser's context menu are off, and
//! the browser profile is a temp folder that is deleted on exit.
//!
//! The page's menus are the windows' menu bars (painted here in the dark theme), its context
//! menu a popup menu, its status a strip under the web view, and its messages and About task
//! dialogs; pasted headers are asked for by the page. PSTVIEW_NATIVE=0: all of it by the page.
//!
//!   pstview [file or folder ...]      several PST/OST parts are merged into one mailbox
//!   pstview --version
//!   pstview --uninstall               what Settings > Apps runs
//!   pstview --selftest <source>       open, list and render one message, then exit 0 / 1 (for CI)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const w = @import("win.zig");
const L = w.L;
const webapp = @import("webapp.zig");
const setup = @import("setup.zig");
const build_options = @import("build_options");

const HRESULT = i32;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));

extern "ole32" fn CoTaskMemAlloc(usize) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
extern "user32" fn SetForegroundWindow(w.HWND) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetEnvironmentVariableW([*:0]const u16, ?[*:0]const u16) callconv(.winapi) w.BOOL;
extern "user32" fn PeekMessageW(*w.MSG, ?w.HWND, u32, u32, u32) callconv(.winapi) w.BOOL;

const hkey_local_machine: w.HKEY = @ptrFromInt(0xFFFFFFFF80000002);
const key_wow64_32key: u32 = 0x0200;
const WM_MOVE = 0x0003;
/// A request from a page, handed from the web view's callback to the window procedure.
const WM_APP_REQUEST = w.WM_APP + 1;
/// Close a window once the request that asked for it has been answered.
const WM_APP_CLOSE = w.WM_APP + 2;
/// Files dropped on the main window: their paths, one per line.
const WM_APP_DROP = w.WM_APP + 3;
const WM_QUIT = 0x0012;

/// A windows-subsystem program has no console for a panic message: show it first.
pub const panic = std.debug.FullPanic(guiPanic);
var panicking = std.atomic.Value(bool).init(false);

fn guiPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking.swap(true, .seq_cst)) {
        var tb: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&tb, "pstview hit an internal error and has to close. The source file was not changed.\n\n{s}\n\nPlease report this, with the details above, at https://github.com/publicarray/pstview/issues", .{msg[0..@min(msg.len, 700)]}) catch "pstview hit an internal error and has to close.";
        var wb: [1200]u16 = undefined; // at most 1024 bytes, so at most 1024 UTF-16 units
        const n = std.unicode.wtf8ToWtf16Le(&wb, text) catch 0;
        wb[n] = 0;
        _ = w.MessageBoxW(null, wb[0..n :0].ptr, L("pstview - internal error"), w.MB_ICONERROR | w.MB_TASKMODAL | w.MB_SETFOREGROUND);
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Method `index` of a COM object's vtable, as function type `F`.
fn method(obj: *anyopaque, comptime index: usize, comptime F: type) *const F {
    const vtbl: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(@alignCast(vtbl.*[index]));
}

fn release(obj: ?*anyopaque) void {
    if (obj) |o| _ = method(o, 2, fn (*anyopaque) callconv(.winapi) u32)(o);
}

fn addRef(obj: *anyopaque) void {
    _ = method(obj, 1, fn (*anyopaque) callconv(.winapi) u32)(obj);
}

fn failedHr(hr: usize) bool {
    return @as(i32, @bitCast(@as(u32, @truncate(hr)))) < 0;
}

// ---------------------------------------------------------------- callback objects

/// A COM callback with one method. `Invoke` takes (HRESULT, result) for the completion handlers
/// and (sender, args) for the event handlers: two pointer-sized arguments either way.
const Handler = extern struct {
    vtbl: *const Vtbl,
    win: ?*Win = null,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*Handler, *const w.GUID, *?*anyopaque) callconv(.winapi) HRESULT = &queryInterface,
        AddRef: *const fn (*Handler) callconv(.winapi) u32 = &addRefStatic,
        Release: *const fn (*Handler) callconv(.winapi) u32 = &releaseStatic,
        Invoke: *const fn (*Handler, usize, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    // The handlers live as long as their window (or for ever): reference counting is not needed.
    // Each handler is asked for IUnknown and its own callback interface (all single-method, same
    // layout). COM's own interfaces (IMarshal and the like, {000000xx-0000-0000-C000-000000000046})
    // have other methods and are refused.
    fn queryInterface(self: *Handler, iid: *const w.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        const system = iid.b == 0 and iid.c == 0 and std.mem.eql(u8, &iid.d, &iid_unknown.d);
        if (system and iid.a != 0) {
            out.* = null;
            return E_NOINTERFACE;
        }
        out.* = self;
        return S_OK;
    }
    fn addRefStatic(_: *Handler) callconv(.winapi) u32 {
        return 2;
    }
    fn releaseStatic(_: *Handler) callconv(.winapi) u32 {
        return 1;
    }
};

const iid_unknown: w.GUID = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const iid_message_args2: w.GUID = .{ .a = 0x06fc7ab7, .b = 0xc90c, .c = 0x4297, .d = .{ 0x93, 0x89, 0x33, 0xca, 0x01, 0xcf, 0x6d, 0x5e } };
const iid_file: w.GUID = .{ .a = 0xf2c19559, .b = 0x6bc1, .c = 0x4583, .d = .{ 0xa7, 0x57, 0x90, 0x02, 0x1b, 0xe9, 0xaf, 0xec } };
const iid_environment_options: w.GUID = .{ .a = 0x2fde08a8, .b = 0x1e9a, .c = 0x4766, .d = .{ 0x8c, 0x05, 0x95, 0xa9, 0xce, 0xb9, 0xd1, 0xc5 } };

/// ICoreWebView2EnvironmentOptions with the defaults: the runtime asks it for the browser
/// arguments, the language and the minimum browser version.
const Options = extern struct {
    vtbl: *const Vtbl,

    const Str = *const fn (*Options, *?[*:0]u16) callconv(.winapi) HRESULT;
    const Put = *const fn (*Options, usize) callconv(.winapi) HRESULT;
    const Vtbl = extern struct {
        QueryInterface: *const fn (*Options, *const w.GUID, *?*anyopaque) callconv(.winapi) HRESULT = &queryInterface,
        AddRef: *const fn (*Options) callconv(.winapi) u32 = &addRefStatic,
        Release: *const fn (*Options) callconv(.winapi) u32 = &releaseStatic,
        get_AdditionalBrowserArguments: Str = &emptyString,
        put_AdditionalBrowserArguments: Put = &put,
        get_Language: Str = &emptyString,
        put_Language: Put = &put,
        get_TargetCompatibleBrowserVersion: Str = &version,
        put_TargetCompatibleBrowserVersion: Put = &put,
        get_AllowSingleSignOnUsingOSPrimaryAccount: *const fn (*Options, *i32) callconv(.winapi) HRESULT = &noSingleSignOn,
        put_AllowSingleSignOnUsingOSPrimaryAccount: Put = &put,
    };

    fn queryInterface(self: *Options, iid: *const w.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, iid_unknown) or std.meta.eql(iid.*, iid_environment_options)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }
    fn addRefStatic(_: *Options) callconv(.winapi) u32 {
        return 2;
    }
    fn releaseStatic(_: *Options) callconv(.winapi) u32 {
        return 1;
    }
    /// Strings handed to the runtime are allocated with CoTaskMemAlloc; it frees them.
    fn comString(text: []const u16, out: *?[*:0]u16) HRESULT {
        const mem: [*]u16 = @ptrCast(@alignCast(CoTaskMemAlloc((text.len + 1) * 2) orelse return E_POINTER));
        @memcpy(mem[0..text.len], text);
        mem[text.len] = 0;
        out.* = @ptrCast(mem);
        return S_OK;
    }
    fn emptyString(_: *Options, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        return comString(L(""), out);
    }
    fn version(_: *Options, out: *?[*:0]u16) callconv(.winapi) HRESULT {
        return comString(L("86.0.616.0"), out); // the first WebView2 release: any runtime will do
    }
    fn noSingleSignOn(_: *Options, out: *i32) callconv(.winapi) HRESULT {
        out.* = 0;
        return S_OK;
    }
    fn put(_: *Options, _: usize) callconv(.winapi) HRESULT {
        return S_OK;
    }
};

// ---------------------------------------------------------------- state

/// One window and its web view; the main window has id 0.
const Win = struct {
    id: u32,
    hwnd: ?w.HWND = null,
    controller: ?*anyopaque = null,
    webview: ?*anyopaque = null,
    /// The browser has been asked for this window's web view: `controllerCreated` will be called.
    requested: bool = false,
    /// The page itself has been loaded: any later navigation is refused.
    loaded: bool = false,
    on_controller: Handler = .{ .vtbl = &controller_vtbl },
    on_navigation: Handler = .{ .vtbl = &navigation_vtbl },
    on_frame_navigation: Handler = .{ .vtbl = &frame_navigation_vtbl },
    on_new_window: Handler = .{ .vtbl = &new_window_vtbl },
    on_message: Handler = .{ .vtbl = &message_vtbl },
    /// The menu bar's commands (item id - first_command) and the layout it was made for.
    actions: std.ArrayList([]u8) = .empty,
    shape: []u8 = &.{},
    /// The status strip under the web view and its text.
    status: ?w.HWND = null,
    status_text: []u16 = &.{},
};
/// Menus, status strip and dialogs are native (PSTVIEW_NATIVE=0: the page's).
var native = true;
var selftest_mode = false;
const first_command: usize = 1000;
const popup_timer: usize = 77;

const environment_vtbl: Handler.Vtbl = .{ .Invoke = &environmentCreated };
const controller_vtbl: Handler.Vtbl = .{ .Invoke = &controllerCreated };
const navigation_vtbl: Handler.Vtbl = .{ .Invoke = &navigationStarting };
const frame_navigation_vtbl: Handler.Vtbl = .{ .Invoke = &frameNavigationStarting };
const new_window_vtbl: Handler.Vtbl = .{ .Invoke = &newWindowRequested };
const message_vtbl: Handler.Vtbl = .{ .Invoke = &webMessageReceived };
const options_vtbl: Options.Vtbl = .{};

var gpa: Allocator = undefined;
var io: Io = undefined;
var hinst: ?w.HINSTANCE = null;
var environment: ?*anyopaque = null;
var environment_state: enum { pending, ready, failed } = .pending;
var on_environment: Handler = .{ .vtbl = &environment_vtbl };
var options: Options = .{ .vtbl = &options_vtbl };
var wins: std.ArrayList(*Win) = .empty;
var next_id: u32 = 1;
var page_w: [:0]u16 = undefined;
var data_dir: [:0]u16 = undefined;
var dark = false;
var exit_code: u8 = 0;

const class_name = L("pstview.window");

fn winById(id: u32) ?*Win {
    for (wins.items) |v| if (v.id == id) return v;
    return null;
}

fn mainHwnd() ?w.HWND {
    return if (winById(0)) |v| v.hwnd else null;
}

fn toW(a: Allocator, text: []const u8) ?[:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, text) catch null;
}

fn message(text: []const u8, flags: u32) i32 {
    const t = toW(gpa, text) orelse return 0;
    defer gpa.free(t);
    return w.MessageBoxW(mainHwnd(), t.ptr, L("pstview"), flags | w.MB_SETFOREGROUND);
}

// ---------------------------------------------------------------- runtime

const no_runtime =
    "pstview shows its window with the Microsoft Edge WebView2 Runtime, which is part of Windows 11 and of up-to-date Windows 10, but was not found on this PC.\n\n" ++
    "Install the \"Evergreen\" runtime from https://developer.microsoft.com/microsoft-edge/webview2/ and start pstview again.\n\n" ++
    "The command-line tool pstx.exe works without it.";

/// Path of the installed runtime's EmbeddedBrowserWebView.dll, if there is one.
fn runtimeDll(buf: *[700]u16) ?[*:0]const u16 {
    const sub = L("SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}");
    for ([_]w.HKEY{ hkey_local_machine, w.HKEY_CURRENT_USER }) |root| {
        var key: ?w.HKEY = null;
        if (w.RegOpenKeyExW(root, sub, 0, w.KEY_READ | key_wow64_32key, &key) != 0) continue;
        defer _ = w.RegCloseKey(key.?);
        var dir: [520]u16 = @splat(0);
        var cb: u32 = @sizeOf(@TypeOf(dir)) - 2;
        if (w.RegQueryValueExW(key.?, L("EBWebView"), null, null, @ptrCast(&dir), &cb) != 0) continue;
        const len = std.mem.indexOfScalar(u16, &dir, 0) orelse continue;
        if (len == 0) continue;
        const arch = switch (@import("builtin").cpu.arch) {
            .x86_64 => L("x64"),
            .aarch64 => L("arm64"),
            else => L("x86"),
        };
        var n: usize = 0;
        for ([_][]const u16{ dir[0..len], L("\\EBWebView\\"), arch, L("\\EmbeddedBrowserWebView.dll") }) |part| {
            @memcpy(buf[n..][0..part.len], part);
            n += part.len;
        }
        buf[n] = 0;
        if (w.GetFileAttributesW(buf[0..n :0]) != 0xFFFFFFFF) return buf[0..n :0];
    }
    return null;
}

/// Start creating the browser environment; its profile goes to `data_dir` (a temp folder).
fn startEnvironment() bool {
    var buf: [700]u16 = undefined;
    const dll = w.LoadLibraryW(runtimeDll(&buf) orelse return false) orelse return false;
    const create: *const fn (c_int, c_int, [*:0]const u16, *Options, *Handler) callconv(.winapi) HRESULT =
        @ptrCast(@alignCast(w.GetProcAddress(dll, "CreateWebViewEnvironmentWithOptionsInternal") orelse return false));
    const installed_runtime = 0;
    return create(1, installed_runtime, data_dir, &options, &on_environment) >= 0;
}

fn environmentCreated(_: *Handler, hr: usize, env: ?*anyopaque) callconv(.winapi) HRESULT {
    if (failedHr(hr) or env == null) {
        environment_state = .failed;
        _ = message(no_runtime, w.MB_ICONERROR);
        exit_code = 1;
        w.PostQuitMessage(1);
        return S_OK;
    }
    addRef(env.?);
    environment = env;
    environment_state = .ready;
    for (wins.items) |v| createController(v); // windows opened while the browser was starting
    return S_OK;
}

fn createController(v: *Win) void {
    const hwnd = v.hwnd orelse return;
    const env = environment.?;
    // ICoreWebView2Environment::CreateCoreWebView2Controller
    v.requested = method(env, 3, fn (*anyopaque, w.HWND, *Handler) callconv(.winapi) HRESULT)(env, hwnd, &v.on_controller) >= 0;
}

fn controllerCreated(self: *Handler, hr: usize, controller: ?*anyopaque) callconv(.winapi) HRESULT {
    const v = self.win.?;
    const c = controller orelse return S_OK;
    if (failedHr(hr)) return S_OK;
    if (v.hwnd == null) {
        // the window was closed while the browser was starting
        _ = method(c, 24, fn (*anyopaque) callconv(.winapi) HRESULT)(c); // Close
        gpa.destroy(v);
        return S_OK;
    }
    addRef(c);
    v.controller = c;
    var webview: ?*anyopaque = null;
    _ = method(c, 25, fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(c, &webview); // get_CoreWebView2
    const wv = webview orelse return S_OK;
    v.webview = wv; // keeps the reference get_CoreWebView2 gave

    var settings: ?*anyopaque = null;
    _ = method(wv, 3, fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(wv, &settings); // get_Settings
    if (settings) |s| {
        defer release(s);
        // The page runs pstview's own script and talks to the model through web messages; those
        // stay on. Off: put_AreDefaultScriptDialogsEnabled, put_IsStatusBarEnabled,
        // put_AreDevToolsEnabled, put_AreDefaultContextMenusEnabled, put_AreHostObjectsAllowed,
        // put_IsBuiltInErrorPageEnabled.
        inline for (.{ 8, 10, 12, 14, 16, 20 }) |index| _ = method(s, index, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(s, 0);
    }
    var token: i64 = 0;
    const Add = fn (*anyopaque, *Handler, *i64) callconv(.winapi) HRESULT;
    _ = method(wv, 7, Add)(wv, &v.on_navigation, &token); // add_NavigationStarting
    _ = method(wv, 17, Add)(wv, &v.on_frame_navigation, &token); // add_FrameNavigationStarting
    _ = method(wv, 34, Add)(wv, &v.on_message, &token); // add_WebMessageReceived
    _ = method(wv, 44, Add)(wv, &v.on_new_window, &token); // add_NewWindowRequested

    resize(v);
    _ = method(c, 4, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(c, 1); // put_IsVisible
    _ = method(wv, 6, fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT)(wv, page_w.ptr); // NavigateToString
    focus(v);
    return S_OK;
}

/// Only the page itself is loaded; any later navigation of the window is cancelled.
fn navigationStarting(self: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    const v = self.win.?;
    if (!v.loaded) {
        v.loaded = true;
        return S_OK;
    }
    if (args) |a| _ = method(a, 8, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(a, 1); // put_Cancel
    return S_OK;
}

/// The frames show documents the page hands them (about:srcdoc); a link clicked in a message
/// would load something else, and is cancelled.
fn frameNavigationStarting(_: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    const a = args orelse return S_OK;
    var uri: ?[*:0]u16 = null;
    _ = method(a, 3, fn (*anyopaque, *?[*:0]u16) callconv(.winapi) HRESULT)(a, &uri); // get_Uri
    var allow = false;
    if (uri) |u| {
        allow = std.mem.startsWith(u16, std.mem.span(u), L("about:"));
        w.CoTaskMemFree(u);
    }
    if (!allow) _ = method(a, 8, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(a, 1); // put_Cancel
    return S_OK;
}

/// Links with target=_blank would open a browser window: mark the request handled, open nothing.
fn newWindowRequested(_: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    if (args) |a| _ = method(a, 6, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(a, 1); // put_Handled
    return S_OK;
}

/// A request from the page. It is answered from the window procedure, not from inside this
/// callback: answering can open a file dialog, and the web view must not be re-entered meanwhile.
fn webMessageReceived(self: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    const v = self.win.?;
    const a = args orelse return S_OK;
    var text: ?[*:0]u16 = null;
    // ICoreWebView2WebMessageReceivedEventArgs::TryGetWebMessageAsString
    if (method(a, 5, fn (*anyopaque, *?[*:0]u16) callconv(.winapi) HRESULT)(a, &text) < 0) return S_OK;
    const t = text orelse return S_OK;
    defer w.CoTaskMemFree(t);
    if (std.mem.eql(u16, std.mem.span(t), L("drop"))) {
        if (v.id == 0) filesDropped(v, a);
        return S_OK;
    }
    const utf8 = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(t)) catch return S_OK;
    if (v.hwnd == null or w.PostMessageW(v.hwnd.?, WM_APP_REQUEST, utf8.len, @bitCast(@intFromPtr(utf8.ptr))) == 0) gpa.free(utf8);
    return S_OK;
}

fn asInterface(obj: *anyopaque, iid: *const w.GUID) ?*anyopaque {
    var out: ?*anyopaque = null;
    if (method(obj, 0, fn (*anyopaque, *const w.GUID, *?*anyopaque) callconv(.winapi) HRESULT)(obj, iid, &out) < 0) return null;
    return out;
}

/// The page passed on the File objects of a drop (it cannot see their paths; the host can):
/// ICoreWebView2WebMessageReceivedEventArgs2::get_AdditionalObjects, each an ICoreWebView2File.
fn filesDropped(v: *Win, args: *anyopaque) void {
    const args2 = asInterface(args, &iid_message_args2) orelse return; // a runtime older than 2023
    defer release(args2);
    var objects: ?*anyopaque = null;
    if (method(args2, 6, fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(args2, &objects) < 0) return;
    const list = objects orelse return;
    defer release(list);
    var count: u32 = 0;
    _ = method(list, 3, fn (*anyopaque, *u32) callconv(.winapi) HRESULT)(list, &count); // get_Count
    var paths: std.ArrayList(u8) = .empty;
    defer paths.deinit(gpa);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var item: ?*anyopaque = null;
        if (method(list, 4, fn (*anyopaque, u32, *?*anyopaque) callconv(.winapi) HRESULT)(list, i, &item) < 0) continue; // GetValueAtIndex
        defer release(item);
        const file = asInterface(item orelse continue, &iid_file) orelse continue;
        defer release(file);
        var path: ?[*:0]u16 = null;
        if (method(file, 3, fn (*anyopaque, *?[*:0]u16) callconv(.winapi) HRESULT)(file, &path) < 0) continue; // get_Path
        const p = path orelse continue;
        defer w.CoTaskMemFree(p);
        const utf8 = std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(p)) catch continue;
        defer gpa.free(utf8);
        if (utf8.len == 0) continue;
        if (paths.items.len > 0) paths.append(gpa, '\n') catch return;
        paths.appendSlice(gpa, utf8) catch return;
    }
    if (paths.items.len == 0) return;
    const text = paths.toOwnedSlice(gpa) catch return;
    if (v.hwnd == null or w.PostMessageW(v.hwnd.?, WM_APP_DROP, text.len, @bitCast(@intFromPtr(text.ptr))) == 0) gpa.free(text);
}

fn resize(v: *Win) void {
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(v.hwnd orelse return, &rc);
    if (v.status) |st| {
        const h = statusHeight(v.hwnd.?);
        rc.bottom = @max(rc.top, rc.bottom - h);
        _ = w.MoveWindow(st, 0, rc.bottom, rc.right - rc.left, h, 1);
    }
    const c = v.controller orelse return;
    _ = method(c, 6, fn (*anyopaque, w.RECT) callconv(.winapi) HRESULT)(c, rc); // put_Bounds
}

/// Keyboard input goes to the web view (ICoreWebView2Controller::MoveFocus, programmatic).
fn focus(v: *Win) void {
    if (v.controller) |c| _ = method(c, 12, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(c, 0);
}

// ---------------------------------------------------------------- windows

fn winOf(hwnd: w.HWND) ?*Win {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    return if (p == 0) null else @ptrFromInt(@as(usize, @bitCast(p)));
}

/// Title bar in the colour of the page's ink bar.
fn paintCaption(hwnd: w.HWND) void {
    const bar: u32 = w.rgb(if (dark) 0x0B1422 else 0x13233F);
    const text: u32 = w.rgb(0xF6F4EE);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_CAPTION_COLOR, &bar, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_BORDER_COLOR, &bar, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_TEXT_COLOR, &text, 4);
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (menuBarMessage(hwnd, msg, lp)) |r| return r;
    switch (msg) {
        w.WM_NCPAINT, w.WM_NCACTIVATE => {
            const r = w.DefWindowProcW(hwnd, msg, wp, lp);
            paintMenuBarLine(hwnd);
            return r;
        },
        w.WM_COMMAND => if (winOf(hwnd)) |v| {
            // a menu bar item (HIWORD 0: a menu, not an accelerator or control)
            const cmd = wp & 0xffff;
            if ((wp >> 16) & 0xffff == 0 and cmd >= first_command and cmd - first_command < v.actions.items.len) {
                webapp.menuAction(v.id, v.actions.items[cmd - first_command]);
                return 0;
            }
        },
        w.WM_TIMER => if (wp == popup_timer) {
            _ = w.KillTimer(hwnd, popup_timer);
            _ = w.EndMenu(); // --selftest: the context menu closes by itself
            return 0;
        },
        w.WM_SIZE => if (winOf(hwnd)) |v| resize(v),
        // ICoreWebView2Controller::NotifyParentWindowPositionChanged
        WM_MOVE => if (winOf(hwnd)) |v| if (v.controller) |c| {
            _ = method(c, 23, fn (*anyopaque) callconv(.winapi) HRESULT)(c);
        },
        w.WM_SETFOCUS => if (winOf(hwnd)) |v| focus(v),
        WM_APP_REQUEST => {
            const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lp)));
            const text = ptr[0..wp];
            defer gpa.free(text);
            if (winOf(hwnd)) |v| webapp.onMessage(v.id, text);
            return 0;
        },
        WM_APP_DROP => {
            const ptr: [*]u8 = @ptrFromInt(@as(usize, @bitCast(lp)));
            const text = ptr[0..wp];
            defer gpa.free(text);
            var list: std.ArrayList([]const u8) = .empty;
            defer list.deinit(gpa);
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |p| list.append(gpa, p) catch break;
            webapp.openFromShell(list.items); // several PST parts are merged into one mailbox
            return 0;
        },
        WM_APP_CLOSE => {
            _ = w.DestroyWindow(hwnd);
            return 0;
        },
        w.WM_NCDESTROY => if (winOf(hwnd)) |v| {
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            forgetChrome(v);
            v.hwnd = null;
            for (wins.items, 0..) |x, i| if (x == v) {
                _ = wins.swapRemove(i);
                break;
            };
            const id = v.id;
            if (v.controller) |c| {
                _ = method(c, 24, fn (*anyopaque) callconv(.winapi) HRESULT)(c); // Close
                release(v.webview);
                release(c);
                gpa.destroy(v);
            } else if (!v.requested) gpa.destroy(v);
            // otherwise the web view is still being created: controllerCreated frees the window
            if (id == 0) w.PostQuitMessage(0) else webapp.windowClosed(id);
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn createWindow(id: u32, title: []const u8, width: i32, height: i32) bool {
    const v = gpa.create(Win) catch return false;
    v.* = .{ .id = id };
    inline for (.{ &v.on_controller, &v.on_navigation, &v.on_frame_navigation, &v.on_new_window, &v.on_message }) |h| h.win = v;
    const t = toW(gpa, title);
    defer if (t) |x| gpa.free(x);
    const scale = @max(GetDpiForSystem(), 96);
    const hwnd = w.CreateWindowExW(0, class_name, if (t) |x| x.ptr else L("pstview").ptr, w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN, w.CW_USEDEFAULT, w.CW_USEDEFAULT, @intCast(@divTrunc(@as(u32, @intCast(width)) * scale, 96)), @intCast(@divTrunc(@as(u32, @intCast(height)) * scale, 96)), null, null, hinst, null) orelse {
        gpa.destroy(v);
        return false;
    };
    v.hwnd = hwnd;
    wins.append(gpa, v) catch {
        _ = w.DestroyWindow(hwnd);
        gpa.destroy(v);
        return false;
    };
    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(v)));
    paintCaption(hwnd);
    if (native) {
        loadDarkApi();
        if (allow_dark_for_window) |f| _ = f(hwnd, 1);
        v.status = w.CreateWindowExW(0, status_class, null, w.WS_CHILD | w.WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hinst, null);
        if (v.status) |st| _ = w.SetWindowLongPtrW(st, w.GWLP_USERDATA, @bitCast(@intFromPtr(v)));
        resize(v);
    }
    _ = w.ShowWindow(hwnd, w.SW_SHOW);
    _ = w.UpdateWindow(hwnd);
    if (environment_state == .ready) createController(v);
    return true;
}

// ================================================================ shell for webapp.zig

fn eval(win: u32, js: []const u8) void {
    const v = winById(win) orelse return;
    const wv = v.webview orelse return;
    const text = toW(gpa, js) orelse return;
    defer gpa.free(text);
    // ICoreWebView2::ExecuteScript; the result is not needed
    _ = method(wv, 29, fn (*anyopaque, [*:0]const u16, ?*anyopaque) callconv(.winapi) HRESULT)(wv, text.ptr, null);
}

fn setTitle(title: []const u8) void {
    const t = toW(gpa, title) orelse return;
    defer gpa.free(t);
    if (mainHwnd()) |h| _ = w.SetWindowTextW(h, t.ptr);
}

fn openWindow(title: []const u8) ?u32 {
    const id = next_id;
    if (!createWindow(id, title, 1000, 760)) return null;
    next_id += 1;
    return id;
}

fn closeWindow(win: u32) void {
    if (win == 0) return;
    if (winById(win)) |v| if (v.hwnd) |h| {
        _ = w.PostMessageW(h, WM_APP_CLOSE, 0, 0);
    };
}

/// Handle the window messages that are waiting. WM_QUIT is for the main loop: it is posted again.
fn pump() void {
    var msg: w.MSG = undefined;
    var n: usize = 0;
    while (n < 500 and PeekMessageW(&msg, null, 0, 0, 1) != 0) : (n += 1) {
        if (msg.message == WM_QUIT) {
            w.PostQuitMessage(@intCast(msg.wParam & 0xff));
            return;
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

/// Windows is set to dark apps (Settings > Personalisation > Colours).
fn systemDark() bool {
    var key: ?w.HKEY = null;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), 0, w.KEY_READ, &key) != 0) return false;
    defer _ = w.RegCloseKey(key.?);
    var light: u32 = 1;
    var cb: u32 = 4;
    if (w.RegQueryValueExW(key.?, L("AppsUseLightTheme"), null, null, @ptrCast(&light), &cb) != 0) return false;
    return light == 0;
}

/// The native question of webapp.Shell.ask: a task dialog with command links, the app icon and
/// an optional check box - pstview's install dialogs as they were before the windows became web
/// pages.
fn ask(a: Allocator, q: webapp.Ask) ?webapp.Answer {
    var buttons: [8]w.TASKDIALOG_BUTTON = undefined;
    const n = @min(q.choices.len, buttons.len);
    for (q.choices[0..n], 0..) |c, i| {
        // a command link: its label, then the note on a second line
        const text = if (c.note.len > 0) std.fmt.allocPrint(a, "{s}\n{s}", .{ c.label, c.note }) catch return null else c.label;
        buttons[i] = .{ .nButtonID = @intCast(100 + i), .pszButtonText = (toW(a, text) orelse return null).ptr };
    }
    const scale = @max(GetDpiForSystem(), 96);
    const px: i32 = @intCast(@divTrunc(32 * scale, 96));
    const icon = w.LoadImageW(hinst, 1, w.IMAGE_ICON, px, px, 0);
    const verification = if (q.verification.len > 0) toW(a, q.verification) else null;
    var cfg: w.TASKDIALOGCONFIG = .{
        .hwndParent = w.GetActiveWindow() orelse mainHwnd(),
        .dwFlags = w.TDF_USE_COMMAND_LINKS | w.TDF_ALLOW_DIALOG_CANCELLATION | w.TDF_POSITION_RELATIVE_TO_WINDOW | (if (icon != null) w.TDF_USE_HICON_MAIN else 0),
        .dwCommonButtons = w.TDCBF_CANCEL_BUTTON,
        .pszWindowTitle = L("pstview"),
        .hMainIcon = icon,
        .pszMainInstruction = (toW(a, q.title) orelse return null).ptr,
        .pszContent = (toW(a, q.text) orelse return null).ptr,
        .cButtons = @intCast(n),
        .pButtons = &buttons,
        .nDefaultButton = if (n > 0) 100 else 0,
        .pszVerificationText = if (verification) |v| v.ptr else null,
        .pfCallback = @ptrCast(&taskCallback),
    };
    cfg.dwFlags |= if (selftest_mode) w.TDF_CALLBACK_TIMER else 0;
    var pressed: i32 = w.IDCANCEL;
    var checked: w.BOOL = 0;
    if (w.TaskDialogIndirect(&cfg, &pressed, null, &checked) < 0) return null; // the page asks instead
    const choice: ?usize = if (pressed >= 100 and pressed < 100 + @as(i32, @intCast(n))) @intCast(pressed - 100) else null;
    return .{ .choice = choice, .verified = checked != 0 };
}

fn setDark(on: bool) void {
    dark = on;
    for (wins.items) |v| if (v.hwnd) |h| {
        paintCaption(h);
        _ = w.DrawMenuBar(h);
        if (v.status) |st| _ = w.InvalidateRect(st, null, 1);
    };
}

fn pickFolder(a: Allocator, title: []const u8) ?[]const []const u8 {
    var name: [260]u16 = undefined;
    const tw = toW(a, title) orelse return null;
    var bi: w.BROWSEINFOW = .{ .hwndOwner = w.GetActiveWindow(), .pszDisplayName = &name, .lpszTitle = tw, .ulFlags = w.BIF_RETURNONLYFSDIRS | w.BIF_NEWDIALOGSTYLE | w.BIF_EDITBOX };
    const pidl = w.SHBrowseForFolderW(&bi) orelse return null;
    defer w.CoTaskMemFree(pidl);
    var path: [1024]u16 = @splat(0);
    if (w.SHGetPathFromIDListW(pidl, &path) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &path, 0) orelse 0;
    const out = a.alloc([]const u8, 1) catch return null;
    out[0] = std.unicode.wtf16LeToWtf8Alloc(a, path[0..len]) catch return null;
    return out;
}

fn pickOpen(a: Allocator, title: []const u8, multiple: bool, folders: bool) ?[]const []const u8 {
    if (folders) return pickFolder(a, title);
    const file = a.alloc(u16, 32768) catch return null;
    @memset(file, 0);
    // several files: the parts of a mailbox; one file: a message or header text to analyse
    const filter = if (multiple)
        L("Mail files (*.pst;*.ost;*.mbox;*.mbx)\x00*.pst;*.ost;*.mbox;*.mbx\x00Outlook data files (*.pst;*.ost)\x00*.pst;*.ost\x00MBOX files (*.mbox;*.mbx)\x00*.mbox;*.mbx\x00All files - e.g. Thunderbird mailboxes (*.*)\x00*.*\x00")
    else
        L("Messages and header text (*.eml;*.txt)\x00*.eml;*.txt\x00All files (*.*)\x00*.*\x00");
    var ofn: w.OPENFILENAMEW = .{
        .hwndOwner = w.GetActiveWindow(),
        .lpstrFilter = filter.ptr,
        .lpstrFile = file.ptr,
        .nMaxFile = @intCast(file.len),
        .Flags = w.OFN_FILEMUSTEXIST | w.OFN_PATHMUSTEXIST | w.OFN_EXPLORER | w.OFN_HIDEREADONLY | (if (multiple) w.OFN_ALLOWMULTISELECT else 0),
        .lpstrTitle = toW(a, title) orelse return null,
    };
    if (w.GetOpenFileNameW(&ofn) == 0) return null;
    // one file: "C:\dir\file.pst\0\0"; several: "C:\dir\0a.pst\0b.pst\0\0"
    var parts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < file.len and file[i] != 0) {
        const e = std.mem.indexOfScalarPos(u16, file, i, 0) orelse break;
        parts.append(a, std.unicode.wtf16LeToWtf8Alloc(a, file[i..e]) catch return null) catch return null;
        i = e + 1;
    }
    if (parts.items.len <= 1) return if (parts.items.len == 1) parts.items else null;
    const paths = a.alloc([]const u8, parts.items.len - 1) catch return null;
    for (paths, parts.items[1..]) |*p, name| p.* = std.fs.path.join(a, &.{ parts.items[0], name }) catch return null;
    return paths;
}

fn pickSave(a: Allocator, title: []const u8, name: []const u8) ?[]const u8 {
    var file: [1024]u16 = @splat(0);
    const n = std.unicode.wtf8ToWtf16Le(file[0 .. file.len - 1], name[0..@min(name.len, 300)]) catch 0;
    file[n] = 0;
    var ofn: w.OPENFILENAMEW = .{
        .hwndOwner = w.GetActiveWindow(),
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .Flags = w.OFN_OVERWRITEPROMPT | w.OFN_PATHMUSTEXIST | w.OFN_EXPLORER | w.OFN_HIDEREADONLY,
        .lpstrFilter = L("All files (*.*)\x00*.*\x00").ptr,
        .lpstrTitle = toW(a, title) orelse return null,
    };
    if (w.GetSaveFileNameW(&ofn) == 0) return null;
    const len = std.mem.indexOfScalar(u16, &file, 0) orelse 0;
    return std.unicode.wtf16LeToWtf8Alloc(a, file[0..len]) catch null;
}

/// Open a folder, a file or a URL (also "ms-settings:") with whatever Windows uses for it.
fn openPath(path: []const u8) void {
    const p = toW(gpa, path) orelse return;
    defer gpa.free(p);
    _ = w.ShellExecuteW(mainHwnd(), L("open"), p.ptr, null, null, w.SW_SHOWNORMAL);
}

fn quit(code: u8) void {
    exit_code = code;
    w.PostQuitMessage(code);
}

// ================================================================ start

fn tempDir(a: Allocator) ![]u8 {
    var buf: [600]u16 = undefined;
    const n = w.GetTempPathW(buf.len, &buf);
    const base = try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
    return std.fmt.allocPrint(a, "{s}pstview", .{base});
}

/// What Settings > Apps runs: confirm, uninstall, done.
fn uninstallFromSettings(a: Allocator) void {
    const s = setup.info(a, io);
    if (message(std.fmt.allocPrint(a, "Uninstall pstview?\n\n{s}", .{s.uninstall_text}) catch return, w.MB_YESNO | w.MB_ICONINFORMATION) != w.IDYES) return;
    const r = setup.uninstall(a, io);
    _ = message(r.text, if (r.ok) w.MB_ICONINFORMATION else w.MB_ICONERROR);
}

pub fn main(init: std.process.Init) !void {
    gpa = init.gpa;
    io = init.io;
    const arena = init.arena.allocator();
    hinst = w.GetModuleHandleW(null);
    _ = w.CoInitializeEx(null, 0x2); // apartment-threaded: the web view and the folder picker need it

    const args = try init.minimal.args.toSlice(arena);
    var paths: std.ArrayList([]const u8) = .empty;
    var selftest = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("pstview {s}\n", .{build_options.version});
            return;
        } else if (std.mem.eql(u8, arg, "--uninstall")) {
            return uninstallFromSettings(arena);
        } else if (std.mem.eql(u8, arg, "--selftest")) {
            selftest = true;
        } else {
            // dialogs and exports work with absolute paths
            const abs = std.fs.path.resolve(arena, &.{ try std.process.currentPathAlloc(init.io, arena), arg }) catch arg;
            try paths.append(arena, abs);
        }
    }

    const temp = try tempDir(arena);
    Io.Dir.cwd().createDirPath(io, temp) catch {};
    const profile = try std.fmt.allocPrint(arena, "{s}\\webview", .{temp});
    data_dir = try std.unicode.wtf8ToWtf16LeAllocZ(arena, profile);
    page_w = try std.unicode.utf8ToUtf16LeAllocZ(arena, webapp.page_html);

    selftest_mode = selftest;
    var env_buf: [8]u16 = undefined;
    const env_len = w.GetEnvironmentVariableW(L("PSTVIEW_NATIVE"), &env_buf, env_buf.len);
    if (env_len == 1 and env_buf[0] == '0') native = false;
    var shell: webapp.Shell = .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openPath, .setTitle = &setTitle, .openWindow = &openWindow, .closeWindow = &closeWindow, .pump = &pump, .ask = &ask, .setDark = &setDark, .quit = &quit };
    if (native) {
        shell.setMenus = &setMenus;
        shell.popup = &popup;
        shell.setStatus = &setStatus;
        shell.alert = &alert;
        shell.about = &about;
        shell.setTheme = &setTheme;
    }
    shell.selftest_closes = true; // (the task dialog of the question, also without the rest)
    webapp.init(gpa, io, shell, paths.items, selftest);

    // What a window shows before its page is painted: the page's ground colour, not white, in a
    // dark session (the window's own background and the web view's, which is set by this variable).
    dark = systemDark();
    if (dark) _ = SetEnvironmentVariableW(L("WEBVIEW2_DEFAULT_BACKGROUND_COLOR"), L("FF0F1724"));
    const wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = hinst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .hIcon = w.LoadIconW(hinst, 1),
        .hbrBackground = if (dark) w.CreateSolidBrush(w.rgb(0x0F1724)) else @ptrFromInt(w.COLOR_WINDOW + 1),
        .lpszClassName = class_name,
    };
    _ = w.RegisterClassExW(&wc);
    const status_wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = statusProc,
        .hInstance = hinst,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .lpszClassName = status_class,
    };
    _ = w.RegisterClassExW(&status_wc);
    const px = @max(GetDpiForSystem(), 96);
    ui_font = w.CreateFontW(-@as(i32, @intCast(@divTrunc(12 * px, 96))), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));

    if (!startEnvironment()) {
        if (selftest) std.debug.print("pstview selftest FAILED: no WebView2 runtime\n", .{});
        _ = if (!selftest) message(no_runtime, w.MB_ICONERROR);
        std.process.exit(1);
    }
    if (!createWindow(0, "pstview", 1400, 900)) return error.CreateWindowFailed;
    if (mainHwnd()) |h| _ = SetForegroundWindow(h);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    webapp.deinit();
    // message windows that are still open go with the main window
    while (wins.pop()) |v| {
        if (v.hwnd) |h| _ = w.DestroyWindow(h) else gpa.destroy(v);
    }
    wins.deinit(gpa);
    // the browser profile (best effort: the browser processes may still be closing)
    Io.Dir.cwd().deleteTree(io, profile) catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

// ================================================================ native chrome

const status_class = L("pstview.status");
var ui_font: ?*anyopaque = null;

/// The page's colours (webui.html): pane ground, hairline, text, secondary text, selection.
fn pal(light: u32, dark_: u32) u32 {
    return w.rgb(if (dark) dark_ else light);
}

fn fill(dc: w.HDC, rc: w.RECT, color: u32) void {
    const br = w.CreateSolidBrush(color) orelse return;
    _ = w.FillRect(dc, &rc, br);
    _ = w.DeleteObject(@ptrCast(br));
}

fn statusHeight(hwnd: w.HWND) i32 {
    return @intCast(@divTrunc(26 * @max(w.GetDpiForWindow(hwnd), 96), 96));
}

fn forgetChrome(v: *Win) void {
    for (v.actions.items) |x| gpa.free(x);
    v.actions.deinit(gpa);
    v.actions = .empty;
    gpa.free(v.shape);
    v.shape = &.{};
    gpa.free(v.status_text);
    v.status_text = &.{};
}

// ---------------------------------------------------------------- status strip

fn statusProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_ERASEBKGND => return 1,
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const dc = w.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w.EndPaint(hwnd, &ps);
            var rc: w.RECT = undefined;
            _ = w.GetClientRect(hwnd, &rc);
            const scale = @max(w.GetDpiForWindow(hwnd), 96);
            const px = struct {
                fn f(n: i32, s_: u32) i32 {
                    return @intCast(@divTrunc(@as(u32, @intCast(n)) * s_, 96));
                }
            }.f;
            fill(dc, rc, pal(0xF9F8F5, 0x161F2E));
            fill(dc, .{ .left = rc.left, .top = rc.top, .right = rc.right, .bottom = rc.top + 1 }, pal(0xE3E1DA, 0x263247));
            // the amber dot
            const amber = w.rgb(0xF5B700);
            const br = w.CreateSolidBrush(amber);
            const pen = w.CreatePen(w.PS_SOLID, 1, amber);
            const old_br = w.SelectObject(dc, @ptrCast(br));
            const old_pen = w.SelectObject(dc, @ptrCast(pen));
            const mid = @divTrunc(rc.bottom + rc.top, 2);
            _ = w.Ellipse(dc, px(12, scale), mid - px(4, scale), px(20, scale), mid + px(4, scale));
            _ = w.SelectObject(dc, old_br);
            _ = w.SelectObject(dc, old_pen);
            if (br) |b| _ = w.DeleteObject(@ptrCast(b));
            if (pen) |p_| _ = w.DeleteObject(@ptrCast(p_));
            if (ui_font) |f| _ = w.SelectObject(dc, f);
            _ = w.SetBkMode(dc, w.TRANSPARENT);
            var text_rc: w.RECT = .{ .left = px(28, scale), .top = rc.top, .right = rc.right - px(12, scale), .bottom = rc.bottom };
            const ro = L("Read-only");
            _ = w.SetTextColor(dc, pal(0x13233F, 0xE4E8EF));
            var measure = text_rc;
            _ = w.DrawTextW(dc, ro.ptr, @intCast(ro.len), &measure, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_NOPREFIX | w.DT_CALCRECT);
            _ = w.DrawTextW(dc, ro.ptr, @intCast(ro.len), &text_rc, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_NOPREFIX);
            const v = winOf(hwnd) orelse return 0;
            if (v.status_text.len == 0) return 0;
            text_rc.left = measure.right + px(14, scale);
            _ = w.SetTextColor(dc, pal(0x606C80, 0xA3ADBD));
            _ = w.DrawTextW(dc, v.status_text.ptr, @intCast(v.status_text.len), &text_rc, w.DT_SINGLELINE | w.DT_VCENTER | w.DT_NOPREFIX | w.DT_END_ELLIPSIS);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn setStatus(win: u32, text: []const u8) void {
    const v = winById(win) orelse return;
    const t = std.unicode.wtf8ToWtf16LeAlloc(gpa, text) catch return;
    gpa.free(v.status_text);
    v.status_text = t;
    if (v.status) |st| {
        _ = w.InvalidateRect(st, null, 1);
        _ = w.UpdateWindow(st); // (progress text: shown while the request is still running)
    }
}

// ---------------------------------------------------------------- dark theme of menus

// The dark visuals of menus are reached through uxtheme exports that have ordinals but no names
// (Windows 10 1809 and later; absent on older systems, where menus stay light).
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

/// View > Theme: popup menus follow ("system": Windows' setting), and the menu bars are painted
/// again (setDark follows with what the page shows).
fn setTheme(choice: []const u8) void {
    loadDarkApi();
    const allow_dark: c_int = 1;
    const force_dark: c_int = 2;
    const force_light: c_int = 3;
    const mode = if (std.mem.eql(u8, choice, "dark")) force_dark else if (std.mem.eql(u8, choice, "light")) force_light else allow_dark;
    if (set_preferred_app_mode) |f| _ = f(mode);
    if (flush_menu_themes) |f| f();
}

// The menu bar in the dark theme: Windows paints it light unless the window draws it itself,
// through the undocumented WM_UAHDRAWMENU / WM_UAHDRAWMENUITEM messages (as pstview's Win32
// GUI before 0.5 did).
const WM_UAHDRAWMENU = 0x0091;
const WM_UAHDRAWMENUITEM = 0x0092;
const UahMenu = extern struct { hmenu: ?w.HMENU, hdc: ?w.HDC, flags: u32 };
const UahDrawMenuItem = extern struct { dis: w.DRAWITEMSTRUCT, um: UahMenu, position: c_int };
const objid_menu: i32 = -3;

/// Handles the menu bar drawing messages in the dark theme; null: not handled (pass on).
fn menuBarMessage(hwnd: w.HWND, msg: u32, lp: w.LPARAM) ?w.LRESULT {
    if (!native or !dark or (msg != WM_UAHDRAWMENU and msg != WM_UAHDRAWMENUITEM) or lp == 0) return null;
    if (msg == WM_UAHDRAWMENU) {
        const um: *const UahMenu = @ptrFromInt(@as(usize, @bitCast(lp)));
        var mbi: w.MENUBARINFO = .{};
        var wr: w.RECT = undefined;
        if (w.GetMenuBarInfo(hwnd, objid_menu, 0, &mbi) == 0 or w.GetWindowRect(hwnd, &wr) == 0) return null;
        const rc: w.RECT = .{ .left = mbi.rcBar.left - wr.left, .top = mbi.rcBar.top - wr.top, .right = mbi.rcBar.right - wr.left, .bottom = mbi.rcBar.bottom - wr.top };
        fill(um.hdc orelse return null, rc, pal(0xF9F8F5, 0x161F2E));
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
    fill(dc, d.dis.rcItem, if (hot) pal(0xE4E9F2, 0x22324D) else pal(0xF9F8F5, 0x161F2E));
    _ = w.SetBkMode(dc, w.TRANSPARENT);
    _ = w.SetTextColor(dc, if (off) pal(0x7C8595, 0x8490A3) else pal(0x13233F, 0xE4E8EF));
    if (ui_font) |f| _ = w.SelectObject(dc, f);
    var rc = d.dis.rcItem;
    const hide_prefix: u32 = if ((state & 0x100) != 0) 0x100000 else 0; // ODS_NOACCEL -> DT_HIDEPREFIX
    _ = w.DrawTextW(dc, &text, @intCast(mii.cch), &rc, w.DT_CENTER | w.DT_SINGLELINE | w.DT_VCENTER | hide_prefix);
    return 0;
}

/// The one-pixel line under the menu bar, which the system paints light.
fn paintMenuBarLine(hwnd: w.HWND) void {
    if (!native or !dark) return;
    var mbi: w.MENUBARINFO = .{};
    if (w.GetMenuBarInfo(hwnd, objid_menu, 0, &mbi) == 0) return;
    var client: w.RECT = undefined;
    var wr: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &client);
    _ = w.MapWindowPoints(hwnd, null, &client, 2);
    if (w.GetWindowRect(hwnd, &wr) == 0) return;
    const line: w.RECT = .{ .left = client.left - wr.left, .top = client.top - wr.top - 1, .right = client.right - wr.left, .bottom = client.top - wr.top };
    const dc = w.GetWindowDC(hwnd) orelse return;
    fill(dc, line, pal(0xF9F8F5, 0x161F2E));
    _ = w.ReleaseDC(hwnd, dc);
}

// ---------------------------------------------------------------- menus

/// "Label\tCtrl+O" ("&" doubled: it marks the access key in menus).
fn itemText(a: Allocator, it: webapp.MenuItem) ?[:0]u16 {
    var t: std.ArrayList(u8) = .empty;
    for (it.label) |c| {
        if (c == '&') t.append(a, '&') catch return null;
        t.append(a, c) catch return null;
    }
    if (it.key.len > 0) {
        t.append(a, '\t') catch return null;
        if (std.mem.startsWith(u8, it.key, "Mod+")) t.print(a, "Ctrl+{s}", .{it.key[4..]}) catch return null else t.appendSlice(a, it.key) catch return null;
    }
    return toW(a, t.items);
}

fn itemFlags(it: webapp.MenuItem) u32 {
    return w.MF_STRING | (if (it.enabled) 0 else w.MF_GRAYED) | (if (it.checked orelse false) w.MF_CHECKED else 0);
}

/// A popup menu of `items` whose ids are `first` + the item's index among the commands; the
/// commands are appended to `actions` when given.
fn buildPopup(a: Allocator, items: []const ?webapp.MenuItem, first: usize, actions: ?*std.ArrayList([]u8)) ?w.HMENU {
    const menu = w.CreatePopupMenu() orelse return null;
    var n: usize = 0;
    for (items) |entry| {
        const it = entry orelse {
            _ = w.AppendMenuW(menu, w.MF_SEPARATOR, 0, null);
            continue;
        };
        const text = itemText(a, it) orelse continue;
        if (actions) |list| {
            const action = gpa.dupe(u8, it.action) catch continue;
            list.append(gpa, action) catch {
                gpa.free(action);
                continue;
            };
            n = list.items.len - 1;
        }
        _ = w.AppendMenuW(menu, itemFlags(it), first + n, text.ptr);
        if (actions == null) n += 1;
    }
    return menu;
}

fn setMenus(win: u32, menus: []const webapp.Menu) usize {
    const v = winById(win) orelse return 0;
    const hwnd = v.hwnd orelse return 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The bar is made again only when its layout changes; otherwise its items are updated in
    // place, and an open menu stays open.
    var shape: std.ArrayList(u8) = .empty;
    for (menus) |m| {
        shape.print(a, "\x1e{s}", .{m.label}) catch return 0;
        for (m.items) |entry| if (entry) |it| shape.print(a, "\x1f{s}\x1d{s}\x1d{s}", .{ it.label, it.action, it.key }) catch return 0 else shape.append(a, '|') catch return 0;
    }
    const current = w.GetMenu(hwnd);
    if (current != null and std.mem.eql(u8, shape.items, v.shape)) {
        var i: usize = 0;
        for (menus) |m| for (m.items) |entry| if (entry) |it| {
            const cmd: u32 = @intCast(first_command + i);
            _ = w.EnableMenuItem(current.?, cmd, w.MF_BYCOMMAND | (if (it.enabled) w.MF_ENABLED else w.MF_GRAYED));
            if (it.checked) |c| _ = w.CheckMenuItem(current.?, cmd, w.MF_BYCOMMAND | (if (c) w.MF_CHECKED else w.MF_UNCHECKED));
            i += 1;
        };
        return v.actions.items.len;
    }
    for (v.actions.items) |x| gpa.free(x);
    v.actions.clearRetainingCapacity();
    const bar = w.CreateMenu() orelse return 0;
    for (menus) |m| {
        const popup_menu = buildPopup(a, m.items, first_command, &v.actions) orelse continue;
        const title = toW(a, std.fmt.allocPrint(a, "&{s}", .{m.label}) catch continue) orelse continue;
        _ = w.AppendMenuW(bar, w.MF_POPUP, @intFromPtr(popup_menu), title.ptr);
    }
    _ = w.SetMenu(hwnd, bar);
    if (current) |old| _ = w.DestroyMenu(old);
    _ = w.DrawMenuBar(hwnd);
    gpa.free(v.shape);
    v.shape = gpa.dupe(u8, shape.items) catch &.{};
    resize(v); // the menu bar takes room from the client area
    return v.actions.items.len;
}

/// A context menu at the pointer (where the page was right-clicked).
fn popup(win: u32, _: f64, _: f64, items: []const ?webapp.MenuItem) void {
    const v = winById(win) orelse return;
    const hwnd = v.hwnd orelse return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const menu = buildPopup(a, items, 1, null) orelse return;
    defer _ = w.DestroyMenu(menu);
    var pt: w.POINT = undefined;
    if (w.GetCursorPos(&pt) == 0) return;
    if (selftest_mode) _ = w.SetTimer(hwnd, popup_timer, 700, null);
    const cmd = w.TrackPopupMenu(menu, w.TPM_RETURNCMD | w.TPM_RIGHTBUTTON, pt.x, pt.y, 0, hwnd, null);
    _ = w.KillTimer(hwnd, popup_timer);
    // the commands of the menu in order: 1, 2, ...
    var n: i32 = 0;
    for (items) |entry| if (entry) |it| {
        n += 1;
        if (n == cmd) return webapp.menuAction(win, it.action);
    };
}

// ---------------------------------------------------------------- task dialogs

/// The task dialogs' callback: links open in the browser; --selftest presses Cancel after a
/// moment, so the dialog closes by itself.
fn taskCallback(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM, _: isize) callconv(w.WINAPI) i32 {
    if (msg == w.TDN_HYPERLINK_CLICKED and lp != 0) {
        const url: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = w.ShellExecuteW(hwnd, L("open"), url, null, null, w.SW_SHOWNORMAL);
    } else if (msg == w.TDN_TIMER and selftest_mode and wp >= 700) {
        _ = w.SendMessageW(hwnd, w.TDM_CLICK_BUTTON, @intCast(w.IDCANCEL), 0);
    }
    return S_OK;
}

fn appIcon() ?*anyopaque {
    const scale = @max(GetDpiForSystem(), 96);
    const px: i32 = @intCast(@divTrunc(32 * scale, 96));
    return w.LoadImageW(hinst, 1, w.IMAGE_ICON, px, px, 0);
}

fn taskDialog(cfg: *w.TASKDIALOGCONFIG) void {
    cfg.pfCallback = @ptrCast(&taskCallback);
    if (selftest_mode) cfg.dwFlags |= w.TDF_CALLBACK_TIMER;
    var pressed: i32 = 0;
    _ = w.TaskDialogIndirect(cfg, &pressed, null, null);
}

fn alert(a: Allocator, _: u32, title: []const u8, text: []const u8) void {
    const icon = appIcon();
    var cfg: w.TASKDIALOGCONFIG = .{
        .hwndParent = w.GetActiveWindow() orelse mainHwnd(),
        .dwFlags = w.TDF_ALLOW_DIALOG_CANCELLATION | w.TDF_POSITION_RELATIVE_TO_WINDOW | (if (icon != null) w.TDF_USE_HICON_MAIN else 0),
        .dwCommonButtons = w.TDCBF_OK_BUTTON,
        .pszWindowTitle = L("pstview"),
        .hMainIcon = icon,
        .pszMainInstruction = (toW(a, title) orelse return).ptr,
        .pszContent = (toW(a, text) orelse return).ptr,
    };
    taskDialog(&cfg);
}

/// Help > About: the version, the page's text and a link to the project.
fn about(a: Allocator, _: u32, info: webapp.About) void {
    const icon = appIcon();
    // (the text is plain: "<" would start markup in a dialog with links)
    const plain = std.mem.replaceOwned(u8, a, info.comments, "<", "\u{2039}") catch return;
    const shown = if (std.mem.startsWith(u8, info.url, "https://")) info.url[8..] else info.url;
    const text = std.fmt.allocPrint(a, "{s}\n\n<a href=\"{s}\">{s}</a>", .{ plain, info.url, shown }) catch return;
    var cfg: w.TASKDIALOGCONFIG = .{
        .hwndParent = w.GetActiveWindow() orelse mainHwnd(),
        .dwFlags = w.TDF_ENABLE_HYPERLINKS | w.TDF_ALLOW_DIALOG_CANCELLATION | w.TDF_POSITION_RELATIVE_TO_WINDOW | (if (icon != null) w.TDF_USE_HICON_MAIN else 0),
        .dwCommonButtons = w.TDCBF_OK_BUTTON,
        .pszWindowTitle = L("About pstview"),
        .hMainIcon = icon,
        .pszMainInstruction = (toW(a, std.fmt.allocPrint(a, "pstview {s}", .{info.version}) catch return) orelse return).ptr,
        .pszContent = (toW(a, text) orelse return).ptr,
    };
    taskDialog(&cfg);
}
