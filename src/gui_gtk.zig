//! pstview on Linux: a GTK 3 window whose content is a WebKitGTK web view (the desktop's own web
//! engine), plus the native file choosers. The page and the model behind it are in webapp.zig.
//!
//! GTK and WebKitGTK are loaded at run time, so the program builds without their development
//! packages (and cross-compiles); at run time it needs libgtk-3 and libwebkit2gtk-4.1 (or 4.0),
//! which desktop distributions install by default or as one package.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const webapp = @import("webapp.zig");

const P = ?*anyopaque;
const Z = [*:0]const u8;
const GSList = extern struct { data: P, next: ?*GSList };

/// Every library function used, looked up by its field name.
const Lib = struct {
    gtk_init_check: *const fn (?*c_int, P) callconv(.c) c_int,
    gtk_window_new: *const fn (c_int) callconv(.c) P,
    gtk_window_set_title: *const fn (P, Z) callconv(.c) void,
    gtk_window_set_default_size: *const fn (P, c_int, c_int) callconv(.c) void,
    gtk_window_set_icon_name: *const fn (P, Z) callconv(.c) void,
    gtk_container_add: *const fn (P, P) callconv(.c) void,
    gtk_widget_show_all: *const fn (P) callconv(.c) void,
    gtk_main: *const fn () callconv(.c) void,
    gtk_main_quit: *const fn () callconv(.c) void,
    gtk_file_chooser_native_new: *const fn (Z, P, c_int, ?Z, ?Z) callconv(.c) P,
    gtk_native_dialog_run: *const fn (P) callconv(.c) c_int,
    gtk_file_chooser_set_select_multiple: *const fn (P, c_int) callconv(.c) void,
    gtk_file_chooser_get_filenames: *const fn (P) callconv(.c) ?*GSList,
    gtk_file_chooser_get_filename: *const fn (P) callconv(.c) ?[*:0]u8,
    gtk_file_chooser_set_current_name: *const fn (P, Z) callconv(.c) void,
    gtk_file_chooser_set_current_folder: *const fn (P, Z) callconv(.c) c_int,
    g_get_home_dir: *const fn () callconv(.c) ?Z,
    gtk_file_chooser_set_do_overwrite_confirmation: *const fn (P, c_int) callconv(.c) void,
    gtk_show_uri_on_window: *const fn (P, Z, u32, P) callconv(.c) c_int,
    g_signal_connect_data: *const fn (P, Z, *const anyopaque, P, P, c_int) callconv(.c) c_ulong,
    g_object_new: *const fn (usize, ?Z, ...) callconv(.c) P,
    g_object_unref: *const fn (P) callconv(.c) void,
    g_free: *const fn (P) callconv(.c) void,
    g_slist_free: *const fn (?*GSList) callconv(.c) void,
    g_filename_to_uri: *const fn (Z, ?Z, P) callconv(.c) ?[*:0]u8,
    webkit_web_view_get_type: *const fn () callconv(.c) usize,
    webkit_web_context_new_ephemeral: *const fn () callconv(.c) P,
    webkit_user_content_manager_new: *const fn () callconv(.c) P,
    webkit_user_content_manager_register_script_message_handler: *const fn (P, Z) callconv(.c) c_int,
    webkit_web_view_load_html: *const fn (P, Z, ?Z) callconv(.c) void,
    webkit_javascript_result_get_js_value: *const fn (P) callconv(.c) P,
    jsc_value_to_string: *const fn (P) callconv(.c) ?[*:0]u8,
    webkit_navigation_policy_decision_get_navigation_action: *const fn (P) callconv(.c) P,
    webkit_navigation_action_get_request: *const fn (P) callconv(.c) P,
    webkit_uri_request_get_uri: *const fn (P) callconv(.c) ?Z,
    webkit_policy_decision_ignore: *const fn (P) callconv(.c) void,
};

var lib: Lib = undefined;
/// WebKitGTK 2.40+; older versions have only `run_javascript`.
var evaluate_javascript: ?*const fn (P, [*]const u8, isize, ?Z, ?Z, P, P, P) callconv(.c) void = null;
var run_javascript: ?*const fn (P, Z, P, P, P) callconv(.c) void = null;

var handles: [2]P = .{ null, null };

fn lookup(name: Z) ?*anyopaque {
    for (handles) |h| if (std.c.dlsym(h, name)) |p| return p;
    return null;
}

/// Load GTK 3 and the newest WebKitGTK built for it; null with the missing piece named on failure.
fn loadLibraries() ?[]const u8 {
    handles[0] = std.c.dlopen("libgtk-3.so.0", .{ .LAZY = true }) orelse return "libgtk-3.so.0 (GTK 3)";
    handles[1] = std.c.dlopen("libwebkit2gtk-4.1.so.0", .{ .LAZY = true }) orelse
        std.c.dlopen("libwebkit2gtk-4.0.so.37", .{ .LAZY = true }) orelse return "libwebkit2gtk-4.1.so.0 (WebKitGTK)";
    inline for (@typeInfo(Lib).@"struct".field_names) |name| {
        @field(lib, name) = @ptrCast(@alignCast(lookup(name) orelse return name));
    }
    if (lookup("webkit_web_view_evaluate_javascript")) |p| evaluate_javascript = @ptrCast(@alignCast(p));
    if (lookup("webkit_web_view_run_javascript")) |p| run_javascript = @ptrCast(@alignCast(p));
    if (evaluate_javascript == null and run_javascript == null) return "webkit_web_view_run_javascript";
    return null;
}

var gpa: Allocator = undefined;
var window: P = null;
var webview: P = null;
var first_load_done = false;

// ================================================================ shell for webapp.zig

fn eval(js: []const u8) void {
    if (evaluate_javascript) |f| return f(webview, js.ptr, @intCast(js.len), null, null, null, null, null);
    const z = gpa.dupeSentinel(u8, js, 0) catch return;
    defer gpa.free(z);
    run_javascript.?(webview, z.ptr, null, null, null);
}

fn setTitle(title: []const u8) void {
    var buf: [1024]u8 = undefined;
    lib.gtk_window_set_title(window, std.fmt.bufPrintSentinel(&buf, "{s}", .{title[0..@min(title.len, 1000)]}, 0) catch "pstview");
}

const action_open = 0;
const action_save = 1;
const action_select_folder = 2;
const response_accept = -3;

/// Without a folder the chooser opens on "Recent", where a folder cannot be confirmed.
fn startAtHome(dlg: P) void {
    if (lib.g_get_home_dir()) |home| _ = lib.gtk_file_chooser_set_current_folder(dlg, home);
}

fn pickOpen(a: Allocator, title: []const u8, multiple: bool, folders: bool) ?[]const []const u8 {
    const tz = a.dupeSentinel(u8, title, 0) catch return null;
    const dlg = lib.gtk_file_chooser_native_new(tz.ptr, window, if (folders) action_select_folder else action_open, null, null);
    defer lib.g_object_unref(dlg);
    lib.gtk_file_chooser_set_select_multiple(dlg, @intFromBool(multiple));
    startAtHome(dlg);
    if (lib.gtk_native_dialog_run(dlg) != response_accept) return null;
    const list = lib.gtk_file_chooser_get_filenames(dlg);
    defer lib.g_slist_free(list);
    var out: std.ArrayList([]const u8) = .empty;
    var node = list;
    while (node) |n| : (node = n.next) {
        const p: [*:0]u8 = @ptrCast(n.data orelse continue);
        out.append(a, a.dupe(u8, std.mem.span(p)) catch return null) catch return null;
        lib.g_free(p);
    }
    return if (out.items.len > 0) out.items else null;
}

fn pickSave(a: Allocator, title: []const u8, name: []const u8) ?[]const u8 {
    const tz = a.dupeSentinel(u8, title, 0) catch return null;
    const nz = a.dupeSentinel(u8, name, 0) catch return null;
    const dlg = lib.gtk_file_chooser_native_new(tz.ptr, window, action_save, null, null);
    defer lib.g_object_unref(dlg);
    lib.gtk_file_chooser_set_do_overwrite_confirmation(dlg, 1);
    startAtHome(dlg);
    lib.gtk_file_chooser_set_current_name(dlg, nz.ptr);
    if (lib.gtk_native_dialog_run(dlg) != response_accept) return null;
    const p = lib.gtk_file_chooser_get_filename(dlg) orelse return null;
    defer lib.g_free(p);
    return a.dupe(u8, std.mem.span(p)) catch null;
}

fn openUrl(url: []const u8) void {
    var buf: [2048]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{url}, 0) catch return;
    _ = lib.gtk_show_uri_on_window(window, z.ptr, 0, null);
}

fn openPath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
    const uri = lib.g_filename_to_uri(z.ptr, null, null) orelse return;
    defer lib.g_free(uri);
    _ = lib.gtk_show_uri_on_window(window, uri, 0, null);
}

fn quit(code: u8) void {
    webapp.deinit();
    std.process.exit(code);
}

// ================================================================ signals

/// "script-message-received::pstview": a request from the page.
fn onScriptMessage(_: P, js_result: P, _: P) callconv(.c) void {
    const value = lib.webkit_javascript_result_get_js_value(js_result);
    const text = lib.jsc_value_to_string(value) orelse return;
    defer lib.g_free(text);
    webapp.onMessage(std.mem.span(text));
}

/// "decide-policy": only the page itself and the about:srcdoc frames it fills are loaded; a link
/// in a message never navigates anywhere and never opens a window.
fn onDecidePolicy(_: P, decision: P, kind: c_int, _: P) callconv(.c) c_int {
    const navigation_action = 0;
    const new_window_action = 1;
    if (kind == navigation_action) {
        if (!first_load_done) {
            first_load_done = true;
            return 0;
        }
        const action = lib.webkit_navigation_policy_decision_get_navigation_action(decision);
        const uri = lib.webkit_uri_request_get_uri(lib.webkit_navigation_action_get_request(action));
        if (uri != null and std.mem.startsWith(u8, std.mem.span(uri.?), "about:")) return 0;
    } else if (kind != new_window_action) return 0;
    lib.webkit_policy_decision_ignore(decision);
    return 1;
}

/// "context-menu": the page has its own; WebKit's (Reload, Back) would reset the view.
fn onContextMenu(_: P, _: P, _: P, _: P, _: P) callconv(.c) c_int {
    return 1;
}

fn onDestroy(_: P, _: P) callconv(.c) void {
    lib.gtk_main_quit();
}

// ================================================================ start

pub fn run(gpa_: Allocator, io: Io, start_paths: []const []const u8, selftest: bool) u8 {
    gpa = gpa_;
    if (loadLibraries()) |missing| {
        std.debug.print("pstview needs GTK 3 and WebKitGTK (packages libgtk-3-0 and libwebkit2gtk-4.1-0, or webkit2gtk4.1 / webkit2gtk-4.1 on other distributions).\nNot found: {s}\nThe command-line tool pstx works without them.\n", .{missing});
        return 1;
    }
    if (lib.gtk_init_check(null, null) == 0) {
        std.debug.print("pstview: cannot open a display (no X11 / Wayland session). The command-line tool pstx works without one.\n", .{});
        return 1;
    }
    webapp.init(gpa, io, .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openUrl, .setTitle = &setTitle, .quit = &quit }, start_paths, selftest);

    window = lib.gtk_window_new(0);
    lib.gtk_window_set_title(window, "pstview");
    lib.gtk_window_set_default_size(window, 1400, 900);
    lib.gtk_window_set_icon_name(window, "pstview");
    _ = lib.g_signal_connect_data(window, "destroy", &onDestroy, null, null, 0);

    // web view: an ephemeral context (nothing is written to disk), requests arrive as script messages
    const manager = lib.webkit_user_content_manager_new();
    _ = lib.g_signal_connect_data(manager, "script-message-received::pstview", &onScriptMessage, null, null, 0);
    _ = lib.webkit_user_content_manager_register_script_message_handler(manager, "pstview");
    const context = lib.webkit_web_context_new_ephemeral();
    webview = lib.g_object_new(lib.webkit_web_view_get_type(), "web-context", context, "user-content-manager", manager, @as(P, null));
    _ = lib.g_signal_connect_data(webview, "decide-policy", &onDecidePolicy, null, null, 0);
    _ = lib.g_signal_connect_data(webview, "context-menu", &onContextMenu, null, null, 0);
    lib.gtk_container_add(window, webview);
    lib.gtk_widget_show_all(window);
    lib.webkit_web_view_load_html(webview, webapp.page_html, null);

    lib.gtk_main();
    webapp.deinit();
    return 0;
}
