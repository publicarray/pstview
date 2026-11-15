//! pstview on Linux: GTK 3 windows whose content is a WebKitGTK web view (the desktop's own web
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
    gtk_widget_destroy: *const fn (P) callconv(.c) void,
    gtk_events_pending: *const fn () callconv(.c) c_int,
    gtk_main_iteration_do: *const fn (c_int) callconv(.c) c_int,
    gtk_selection_data_get_uris: *const fn (P) callconv(.c) ?[*:null]?[*:0]u8,
    g_strfreev: *const fn (?[*:null]?[*:0]u8) callconv(.c) void,
    g_filename_from_uri: *const fn (Z, P, P) callconv(.c) ?[*:0]u8,
    g_idle_add: *const fn (*const fn (P) callconv(.c) c_int, P) callconv(.c) c_uint,
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
/// The main window (id 0), parent of the dialogs.
var window: P = null;
var web_context: P = null;

/// One window and its web view. Signal handlers get the id as their user data.
const Win = struct { id: u32, window: P, webview: P, first_load_done: bool = false };
var wins: std.ArrayList(Win) = .empty;
var next_id: u32 = 1;

fn winById(id: u32) ?*Win {
    for (wins.items) |*w| if (w.id == id) return w;
    return null;
}

fn idOf(data: P) u32 {
    return @intCast(@intFromPtr(data));
}

// ================================================================ shell for webapp.zig

fn eval(win: u32, js: []const u8) void {
    const webview = (winById(win) orelse return).webview;
    if (evaluate_javascript) |f| return f(webview, js.ptr, @intCast(js.len), null, null, null, null, null);
    const z = gpa.dupeSentinel(u8, js, 0) catch return;
    defer gpa.free(z);
    run_javascript.?(webview, z.ptr, null, null, null);
}

/// A window showing the page; requests from it arrive as script messages carrying its id.
fn createWindow(id: u32, title: []const u8, width: c_int, height: c_int) bool {
    const w = lib.gtk_window_new(0) orelse return false;
    const data: P = @ptrFromInt(id);
    var buf: [1024]u8 = undefined;
    lib.gtk_window_set_title(w, std.fmt.bufPrintSentinel(&buf, "{s}", .{title[0..@min(title.len, 1000)]}, 0) catch "pstview");
    lib.gtk_window_set_default_size(w, width, height);
    lib.gtk_window_set_icon_name(w, "pstview");
    _ = lib.g_signal_connect_data(w, "destroy", &onDestroy, data, null, 0);

    // web view: an ephemeral context (nothing is written to disk), requests arrive as script messages
    const manager = lib.webkit_user_content_manager_new();
    _ = lib.g_signal_connect_data(manager, "script-message-received::pstview", &onScriptMessage, data, null, 0);
    _ = lib.webkit_user_content_manager_register_script_message_handler(manager, "pstview");
    const view = lib.g_object_new(lib.webkit_web_view_get_type(), "web-context", web_context, "user-content-manager", manager, @as(P, null));
    _ = lib.g_signal_connect_data(view, "decide-policy", &onDecidePolicy, data, null, 0);
    _ = lib.g_signal_connect_data(view, "context-menu", &onContextMenu, null, null, 0);
    if (id == 0) {
        _ = lib.g_signal_connect_data(view, "drag-data-received", &onDragData, null, null, 0);
        _ = lib.g_signal_connect_data(view, "drag-drop", &onDragDrop, null, null, 0);
    }
    wins.append(gpa, .{ .id = id, .window = w, .webview = view }) catch {
        lib.gtk_widget_destroy(w);
        return false;
    };
    lib.gtk_container_add(w, view);
    lib.gtk_widget_show_all(w);
    lib.webkit_web_view_load_html(view, webapp.page_html, null);
    return true;
}

fn openWindow(title: []const u8) ?u32 {
    const id = next_id;
    if (!createWindow(id, title, 1000, 760)) return null;
    next_id += 1;
    return id;
}

fn destroyLater(data: P) callconv(.c) c_int {
    if (winById(idOf(data))) |w| lib.gtk_widget_destroy(w.window);
    return 0; // once
}

/// Closing happens from the main loop: the request that asked for it is still being answered.
fn closeWindow(win: u32) void {
    if (win != 0) _ = lib.g_idle_add(&destroyLater, @ptrFromInt(win));
}

fn setDark(_: bool) void {}

/// Let GTK handle what is waiting (bounded: a busy display must not hold up the request).
fn pump() void {
    var n: usize = 0;
    while (n < 500 and lib.gtk_events_pending() != 0) : (n += 1) _ = lib.gtk_main_iteration_do(0);
}

// ================================================================ files dropped on the window

// The web view is the drop target and gives its page the files without their paths. It asks for
// the dragged data itself (while the pointer moves, or on the drop); these handlers run before
// its own, see the file list go by, and open it once the drop has happened.
var dragged: std.ArrayList([]const u8) = .empty;
var drop_seen = false;

fn clearDragged() void {
    for (dragged.items) |p| gpa.free(p);
    dragged.clearRetainingCapacity();
}

fn openDropped(_: P) callconv(.c) c_int {
    drop_seen = false;
    if (dragged.items.len > 0) webapp.openFromShell(dragged.items);
    clearDragged();
    return 0; // once
}

fn onDragData(_: P, _: P, _: c_int, _: c_int, selection: P, _: c_uint, _: c_uint, _: P) callconv(.c) void {
    const uris = lib.gtk_selection_data_get_uris(selection) orelse return; // another format of the same drag
    defer lib.g_strfreev(uris);
    clearDragged();
    var i: usize = 0;
    while (uris[i]) |uri| : (i += 1) {
        const path = lib.g_filename_from_uri(uri, null, null) orelse continue;
        defer lib.g_free(path);
        const copy = gpa.dupe(u8, std.mem.span(path)) catch continue;
        dragged.append(gpa, copy) catch gpa.free(copy);
    }
    if (drop_seen and dragged.items.len > 0) _ = lib.g_idle_add(&openDropped, null);
}

fn onDragDrop(_: P, _: P, _: c_int, _: c_int, _: c_uint, _: P) callconv(.c) c_int {
    if (dragged.items.len > 0) _ = lib.g_idle_add(&openDropped, null) else drop_seen = true;
    return 0; // the web view finishes the drag
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
fn onScriptMessage(_: P, js_result: P, data: P) callconv(.c) void {
    const value = lib.webkit_javascript_result_get_js_value(js_result);
    const text = lib.jsc_value_to_string(value) orelse return;
    defer lib.g_free(text);
    webapp.onMessage(idOf(data), std.mem.span(text));
}

/// "decide-policy": only the page itself and the about:srcdoc frames it fills are loaded; a link
/// in a message never navigates anywhere and never opens a window.
fn onDecidePolicy(_: P, decision: P, kind: c_int, data: P) callconv(.c) c_int {
    const navigation_action = 0;
    const new_window_action = 1;
    if (kind == navigation_action) {
        if (winById(idOf(data))) |w| if (!w.first_load_done) {
            w.first_load_done = true;
            return 0;
        };
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

fn onDestroy(_: P, data: P) callconv(.c) void {
    const id = idOf(data);
    for (wins.items, 0..) |w, i| if (w.id == id) {
        _ = wins.swapRemove(i);
        break;
    };
    if (id == 0) lib.gtk_main_quit() else webapp.windowClosed(id);
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
    webapp.init(gpa, io, .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openUrl, .setTitle = &setTitle, .openWindow = &openWindow, .closeWindow = &closeWindow, .pump = &pump, .setDark = &setDark, .quit = &quit }, start_paths, selftest);

    web_context = lib.webkit_web_context_new_ephemeral();
    if (!createWindow(0, "pstview", 1400, 900)) return 1;
    window = winById(0).?.window;

    lib.gtk_main();
    webapp.deinit();
    return 0;
}
