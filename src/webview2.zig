//! In-app HTML viewer for Windows: a window whose content is WebView2, the web view that ships
//! with Windows 11 (and with Windows 10 through the Evergreen runtime). Used for the safe HTML
//! view of a message, the header analysis report and the property list.
//!
//! No loader DLL is shipped: the installed runtime is found in the registry and its
//! EmbeddedBrowserWebView.dll is called directly (what WebView2Loader.dll does). When there is no
//! runtime, `show` returns false and the caller opens the page in the default browser instead.
//!
//! Safety, on top of the sanitised and CSP-locked documents of render.zig: scripts, script
//! dialogs, web messages, host objects and dev tools are off; every navigation after the page
//! itself and every new window is refused, so a link in a message leads nowhere.

const std = @import("std");
const w = @import("win.zig");
const L = w.L;

const HRESULT = i32;
const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));

extern "ole32" fn CoTaskMemAlloc(usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.winapi) ?*const anyopaque;

const hkey_local_machine: w.HKEY = @ptrFromInt(0xFFFFFFFF80000002);
const key_wow64_32key: u32 = 0x0200;

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

// ---------------------------------------------------------------- callback objects

/// A COM callback with one method. `Invoke` takes (HRESULT, result) for the completion handlers
/// and (sender, args) for the event handlers: two pointer-sized arguments either way.
const Handler = extern struct {
    vtbl: *const Vtbl,
    view: ?*View = null,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*Handler, *const w.GUID, *?*anyopaque) callconv(.winapi) HRESULT = &queryInterface,
        AddRef: *const fn (*Handler) callconv(.winapi) u32 = &addRefStatic,
        Release: *const fn (*Handler) callconv(.winapi) u32 = &releaseStatic,
        Invoke: *const fn (*Handler, usize, ?*anyopaque) callconv(.winapi) HRESULT,
    };

    // The handlers live as long as their view (or for ever): reference counting is not needed.
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

/// One viewer window.
const View = struct {
    hwnd: ?w.HWND,
    url: [:0]u16,
    controller: ?*anyopaque = null,
    loaded: bool = false,
    on_controller: Handler = .{ .vtbl = &controller_vtbl },
    on_navigation: Handler = .{ .vtbl = &navigation_vtbl },
    on_new_window: Handler = .{ .vtbl = &new_window_vtbl },
};

const environment_vtbl: Handler.Vtbl = .{ .Invoke = &environmentCreated };
const controller_vtbl: Handler.Vtbl = .{ .Invoke = &controllerCreated };
const navigation_vtbl: Handler.Vtbl = .{ .Invoke = &navigationStarting };
const new_window_vtbl: Handler.Vtbl = .{ .Invoke = &newWindowRequested };
const options_vtbl: Options.Vtbl = .{};

var gpa: std.mem.Allocator = undefined;
var environment: ?*anyopaque = null;
var environment_state: enum { none, pending, ready, failed } = .none;
var on_environment: Handler = .{ .vtbl = &environment_vtbl };
var options: Options = .{ .vtbl = &options_vtbl };
/// Views opened while the environment was still being created.
var waiting: std.ArrayList(*View) = .empty;
var class_registered = false;
var caption_color: u32 = 0;
var caption_text: u32 = 0;

const class_name = L("pstview.html");

/// Title bar colours for the viewer windows (COLORREF), as the other pstview windows have.
pub fn setCaptionColors(color: u32, text: u32) void {
    caption_color = color;
    caption_text = text;
}

// ---------------------------------------------------------------- runtime

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
fn startEnvironment(data_dir: [:0]const u16) bool {
    var buf: [700]u16 = undefined;
    const dll = w.LoadLibraryW(runtimeDll(&buf) orelse return false) orelse return false;
    const create: *const fn (c_int, c_int, [*:0]const u16, *Options, *Handler) callconv(.winapi) HRESULT =
        @ptrCast(@alignCast(GetProcAddress(dll, "CreateWebViewEnvironmentWithOptionsInternal") orelse return false));
    const installed_runtime = 0;
    return create(1, installed_runtime, data_dir, &options, &on_environment) >= 0;
}

fn environmentCreated(_: *Handler, hr: usize, env: ?*anyopaque) callconv(.winapi) HRESULT {
    if (@as(i32, @bitCast(@as(u32, @truncate(hr)))) < 0 or env == null) {
        environment_state = .failed;
        for (waiting.items) |v| if (v.hwnd) |h| {
            _ = w.DestroyWindow(h);
        };
    } else {
        addRef(env.?);
        environment = env;
        environment_state = .ready;
        for (waiting.items) |v| createController(v);
    }
    waiting.clearRetainingCapacity();
    return S_OK;
}

fn createController(v: *View) void {
    const hwnd = v.hwnd orelse return; // closed while waiting
    const env = environment.?;
    // ICoreWebView2Environment::CreateCoreWebView2Controller
    _ = method(env, 3, fn (*anyopaque, w.HWND, *Handler) callconv(.winapi) HRESULT)(env, hwnd, &v.on_controller);
}

fn controllerCreated(self: *Handler, hr: usize, controller: ?*anyopaque) callconv(.winapi) HRESULT {
    const v = self.view.?;
    const c = controller orelse return S_OK;
    if (@as(i32, @bitCast(@as(u32, @truncate(hr)))) < 0) return S_OK;
    if (v.hwnd == null) {
        // the window was closed while the browser was starting
        _ = method(c, 24, fn (*anyopaque) callconv(.winapi) HRESULT)(c); // Close
        freeView(v);
        return S_OK;
    }
    addRef(c);
    v.controller = c;
    var webview: ?*anyopaque = null;
    _ = method(c, 25, fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(c, &webview); // get_CoreWebView2
    const wv = webview orelse return S_OK;
    defer release(wv);

    var settings: ?*anyopaque = null;
    _ = method(wv, 3, fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(wv, &settings); // get_Settings
    if (settings) |s| {
        defer release(s);
        // put_IsScriptEnabled, put_IsWebMessageEnabled, put_AreDefaultScriptDialogsEnabled,
        // put_AreDevToolsEnabled, put_AreHostObjectsAllowed: all off
        inline for (.{ 4, 6, 8, 12, 16 }) |index| _ = method(s, index, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(s, 0);
    }
    var token: i64 = 0;
    const Add = fn (*anyopaque, *Handler, *i64) callconv(.winapi) HRESULT;
    _ = method(wv, 7, Add)(wv, &v.on_navigation, &token); // add_NavigationStarting
    _ = method(wv, 44, Add)(wv, &v.on_new_window, &token); // add_NewWindowRequested

    resize(v);
    _ = method(c, 4, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(c, 1); // put_IsVisible
    _ = method(wv, 5, fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT)(wv, v.url.ptr); // Navigate
    return S_OK;
}

/// Only the page the view was opened for is loaded; any later navigation (a clicked link) is cancelled.
fn navigationStarting(self: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    const v = self.view.?;
    if (!v.loaded) {
        v.loaded = true;
        return S_OK;
    }
    if (args) |a| _ = method(a, 8, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(a, 1); // put_Cancel
    return S_OK;
}

/// Links with target=_blank would open a browser window: mark the request handled, open nothing.
fn newWindowRequested(_: *Handler, _: usize, args: ?*anyopaque) callconv(.winapi) HRESULT {
    if (args) |a| _ = method(a, 6, fn (*anyopaque, i32) callconv(.winapi) HRESULT)(a, 1); // put_Handled
    return S_OK;
}

fn resize(v: *View) void {
    const c = v.controller orelse return;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(v.hwnd orelse return, &rc);
    _ = method(c, 6, fn (*anyopaque, w.RECT) callconv(.winapi) HRESULT)(c, rc); // put_Bounds
}

fn freeView(v: *View) void {
    gpa.free(v.url);
    gpa.destroy(v);
}

// ---------------------------------------------------------------- window

fn viewOf(hwnd: w.HWND) ?*View {
    const p = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    return if (p == 0) null else @ptrFromInt(@as(usize, @bitCast(p)));
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_SIZE => if (viewOf(hwnd)) |v| resize(v),
        w.WM_NCDESTROY => if (viewOf(hwnd)) |v| {
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, 0);
            v.hwnd = null;
            if (v.controller) |c| {
                _ = method(c, 24, fn (*anyopaque) callconv(.winapi) HRESULT)(c); // Close
                release(c);
                freeView(v);
            } else if (environment_state == .failed) freeView(v);
            // otherwise the browser is still starting: controllerCreated frees the view
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Percent-encoded file: URL of a path (UTF-8).
fn fileUrl(a: std.mem.Allocator, path: []const u8) ![:0]u16 {
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(a);
    try url.appendSlice(a, "file:///");
    for (path) |c| {
        if (c == '\\') {
            try url.append(a, '/');
        } else if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~/:", c) != null) {
            try url.append(a, c);
        } else try url.print(a, "%{X:0>2}", .{c});
    }
    return std.unicode.utf8ToUtf16LeAllocZ(a, url.items);
}

/// Show the HTML file `path` in a viewer window. False when WebView2 is not available (the
/// caller then falls back to the default browser). `data_dir` receives the browser profile.
pub fn show(allocator: std.mem.Allocator, hinst: ?w.HINSTANCE, title: [*:0]const u16, path: []const u8, data_dir: [:0]const u16, width: i32, height: i32) bool {
    gpa = allocator;
    if (environment_state == .failed) return false;
    if (environment_state == .none) {
        if (!startEnvironment(data_dir)) {
            environment_state = .failed;
            return false;
        }
        if (environment_state == .none) environment_state = .pending; // (the callback may already have run)
    }
    if (!class_registered) {
        const wc: w.WNDCLASSEXW = .{
            .lpfnWndProc = wndProc,
            .hInstance = hinst,
            .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
            .hIcon = w.LoadIconW(hinst, 1),
            .hbrBackground = @ptrFromInt(w.COLOR_WINDOW + 1),
            .lpszClassName = class_name,
        };
        _ = w.RegisterClassExW(&wc);
        class_registered = true;
    }
    const v = gpa.create(View) catch return false;
    v.* = .{ .hwnd = null, .url = fileUrl(gpa, path) catch {
        gpa.destroy(v);
        return false;
    } };
    inline for (.{ &v.on_controller, &v.on_navigation, &v.on_new_window }) |h| h.view = v;
    const hwnd = w.CreateWindowExW(0, class_name, title, w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN | w.WS_VISIBLE, w.CW_USEDEFAULT, w.CW_USEDEFAULT, width, height, null, null, hinst, null) orelse {
        freeView(v);
        return false;
    };
    v.hwnd = hwnd;
    _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(v)));
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_CAPTION_COLOR, &caption_color, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_BORDER_COLOR, &caption_color, 4);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_TEXT_COLOR, &caption_text, 4);
    if (environment_state == .ready) createController(v) else waiting.append(gpa, v) catch {};
    return true;
}

/// True once a viewer has been opened: the browser profile folder then exists and wants deleting.
pub fn used() bool {
    return environment_state != .none;
}
