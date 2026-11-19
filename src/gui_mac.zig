//! pstview on macOS: Cocoa windows whose content is a WKWebView (the system web view), with the
//! page's menus in the menu bar, a status line under the web view, native alerts, the About panel
//! and the open / save panels. The page and the model behind it are in webapp.zig; what the
//! menus contain is the page's. PSTVIEW_NATIVE=0 leaves menus, status and dialogs to the page.
//!
//! The Objective-C runtime, AppKit and WebKit are loaded at run time (they are in every macOS
//! install), so this builds for macOS from any host without the SDK.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const webapp = @import("webapp.zig");

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const NSRect = extern struct { x: f64, y: f64, w: f64, h: f64 };
const NSPoint = extern struct { x: f64, y: f64 };
/// The start of every Objective-C block: enough to call one.
const Block = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*Block, isize) callconv(.c) void,
};

var msg_send: *const anyopaque = undefined;
var objc_getClass: *const fn ([*:0]const u8) callconv(.c) id = undefined;
var sel_registerName: *const fn ([*:0]const u8) callconv(.c) SEL = undefined;
var objc_allocateClassPair: *const fn (id, [*:0]const u8, usize) callconv(.c) id = undefined;
var class_addMethod: *const fn (id, SEL, *const anyopaque, [*:0]const u8) callconv(.c) u8 = undefined;
var objc_registerClassPair: *const fn (id) callconv(.c) void = undefined;
/// NSDefaultRunLoopMode (an NSString), when found.
var default_mode: id = null;
/// The run loop modes of a modal alert and of an open menu, for closing them in the self-test.
var modal_mode: id = null;
var tracking_mode: id = null;

fn loadRuntime() bool {
    const objc = std.c.dlopen("/usr/lib/libobjc.A.dylib", .{ .LAZY = true }) orelse return false;
    const appkit = std.c.dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", .{ .LAZY = true }) orelse return false;
    if (std.c.dlsym(appkit, "NSDefaultRunLoopMode")) |p| default_mode = @as(*const id, @ptrCast(@alignCast(p))).*;
    if (std.c.dlsym(appkit, "NSModalPanelRunLoopMode")) |p| modal_mode = @as(*const id, @ptrCast(@alignCast(p))).*;
    if (std.c.dlsym(appkit, "NSEventTrackingRunLoopMode")) |p| tracking_mode = @as(*const id, @ptrCast(@alignCast(p))).*;
    _ = std.c.dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", .{ .LAZY = true }) orelse return false;
    msg_send = std.c.dlsym(objc, "objc_msgSend") orelse return false;
    objc_getClass = @ptrCast(@alignCast(std.c.dlsym(objc, "objc_getClass") orelse return false));
    sel_registerName = @ptrCast(@alignCast(std.c.dlsym(objc, "sel_registerName") orelse return false));
    objc_allocateClassPair = @ptrCast(@alignCast(std.c.dlsym(objc, "objc_allocateClassPair") orelse return false));
    class_addMethod = @ptrCast(@alignCast(std.c.dlsym(objc, "class_addMethod") orelse return false));
    objc_registerClassPair = @ptrCast(@alignCast(std.c.dlsym(objc, "objc_registerClassPair") orelse return false));
    return true;
}

// objc_msgSend must be called through a pointer of the exact C signature of the method.
fn send0(comptime R: type, o: id, s: [*:0]const u8) R {
    const f: *const fn (id, SEL) callconv(.c) R = @ptrCast(@alignCast(msg_send));
    return f(o, sel_registerName(s));
}
fn send1(comptime R: type, o: id, s: [*:0]const u8, a1: anytype) R {
    const f: *const fn (id, SEL, @TypeOf(a1)) callconv(.c) R = @ptrCast(@alignCast(msg_send));
    return f(o, sel_registerName(s), a1);
}
fn send2(comptime R: type, o: id, s: [*:0]const u8, a1: anytype, a2: anytype) R {
    const f: *const fn (id, SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) R = @ptrCast(@alignCast(msg_send));
    return f(o, sel_registerName(s), a1, a2);
}
fn send3(comptime R: type, o: id, s: [*:0]const u8, a1: anytype, a2: anytype, a3: anytype) R {
    const f: *const fn (id, SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) R = @ptrCast(@alignCast(msg_send));
    return f(o, sel_registerName(s), a1, a2, a3);
}
fn send4(comptime R: type, o: id, s: [*:0]const u8, a1: anytype, a2: anytype, a3: anytype, a4: anytype) R {
    const f: *const fn (id, SEL, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3), @TypeOf(a4)) callconv(.c) R = @ptrCast(@alignCast(msg_send));
    return f(o, sel_registerName(s), a1, a2, a3, a4);
}

fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

const yes: u8 = 1;
const no: u8 = 0;
const nil: id = null;
const utf8_encoding: usize = 4;

/// A new NSString (owned: release it). Text that is not valid UTF-8 gives an empty string.
fn nsString(s: []const u8) id {
    const str = send3(id, send0(id, cls("NSString"), "alloc"), "initWithBytes:length:encoding:", s.ptr, s.len, utf8_encoding);
    return str orelse send0(id, cls("NSString"), "new");
}

fn release(o: id) void {
    send0(void, o, "release");
}

fn utf8(ns_string: id) []const u8 {
    const p = send0(?[*:0]const u8, ns_string, "UTF8String") orelse return "";
    return std.mem.span(p);
}

var ns_app: id = null;
var delegate: id = null;
var gpa: Allocator = undefined;

/// One window and its web view; the main window has id 0.
const Win = struct {
    id: u32,
    window: id,
    webview: id,
    first_load_done: bool = false,
    /// The window's menu bar (the main menu while it is the key window) and the page's items in
    /// it, in order, with their commands; the layout they were made for.
    bar: id = null,
    items: std.ArrayList(id) = .empty,
    actions: std.ArrayList([]u8) = .empty,
    shape: []u8 = &.{},
    window_menu: id = null,
    /// The status line under the web view.
    status: id = null,
};
/// Menus, status line and dialogs are native (PSTVIEW_NATIVE=0: the page's).
var native = true;
var selftest_mode = false;
var wins: std.ArrayList(Win) = .empty;
var next_id: u32 = 1;

fn winById(n: u32) ?*Win {
    for (wins.items) |*w| if (w.id == n) return w;
    return null;
}

fn winByView(view: id) ?*Win {
    for (wins.items) |*w| if (w.webview == view) return w;
    return null;
}

// ================================================================ shell for webapp.zig

fn eval(win: u32, js: []const u8) void {
    const w = winById(win) orelse return;
    const s = nsString(js);
    defer release(s);
    send2(void, w.webview, "evaluateJavaScript:completionHandler:", s, nil);
}

fn setTitle(title: []const u8) void {
    const w = winById(0) orelse return;
    const s = nsString(title);
    defer release(s);
    send1(void, w.window, "setTitle:", s);
}

/// A window showing the page; its requests arrive at the delegate, which finds it by its web view.
fn createWindow(n: u32, title: []const u8, width: f64, height: f64) bool {
    // web view: no persistent data store (nothing is written to disk)
    const config = send0(id, cls("WKWebViewConfiguration"), "new");
    defer release(config);
    send1(void, config, "setWebsiteDataStore:", send0(id, cls("WKWebsiteDataStore"), "nonPersistentDataStore"));
    const handler_name = nsString("pstview");
    defer release(handler_name);
    send2(void, send0(id, config, "userContentController"), "addScriptMessageHandler:name:", delegate, handler_name);

    const frame: NSRect = .{ .x = 0, .y = 0, .w = width, .h = height };
    const style: usize = 1 | 2 | 4 | 8; // titled, closable, miniaturizable, resizable
    const window = send4(id, send0(id, cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:", frame, style, @as(usize, 2), no) orelse return false;
    const t = nsString(title);
    defer release(t);
    send1(void, window, "setTitle:", t);
    const webview = send2(id, send0(id, if (n == 0) webViewClass() else cls("WKWebView"), "alloc"), "initWithFrame:configuration:", frame, config) orelse return false;
    wins.append(gpa, .{ .id = n, .window = window, .webview = webview }) catch return false;
    // Until the page is painted the window's own background shows (dark in a dark session),
    // not the web view's white.
    const key = nsString("drawsBackground");
    defer release(key);
    send2(void, webview, "setValue:forKey:", send1(id, cls("NSNumber"), "numberWithBool:", no), key);
    send1(void, webview, "setNavigationDelegate:", delegate);
    send1(void, window, "setDelegate:", delegate);
    if (native) {
        // the web view over a status line: dot, "Read-only", the status text
        const status_h: f64 = 24;
        const container = send1(id, send0(id, cls("NSView"), "alloc"), "initWithFrame:", frame);
        send1(void, webview, "setFrame:", NSRect{ .x = 0, .y = status_h, .w = width, .h = height - status_h });
        const width_sizable: usize = 2;
        const height_sizable: usize = 16;
        send1(void, webview, "setAutoresizingMask:", width_sizable | height_sizable);
        send1(void, container, "addSubview:", webview);
        const dot = label("\u{25CF}", .{ .x = 12, .y = 4, .w = 14, .h = 16 });
        send1(void, dot, "setTextColor:", send4(id, cls("NSColor"), "colorWithSRGBRed:green:blue:alpha:", @as(f64, 0.96), @as(f64, 0.72), @as(f64, 0.0), @as(f64, 1.0)));
        send1(void, container, "addSubview:", dot);
        send1(void, container, "addSubview:", label("Read-only", .{ .x = 28, .y = 4, .w = 76, .h = 16 }));
        const status = label("", .{ .x = 108, .y = 4, .w = width - 120, .h = 16 });
        send1(void, status, "setTextColor:", send0(id, cls("NSColor"), "secondaryLabelColor"));
        send1(void, status, "setAutoresizingMask:", width_sizable);
        const truncate_tail: usize = 4;
        send1(void, status, "setLineBreakMode:", truncate_tail);
        send1(void, container, "addSubview:", status);
        wins.items[wins.items.len - 1].status = status;
        send1(void, window, "setContentView:", container);
        release(container);
    } else send1(void, window, "setContentView:", webview);
    release(webview); // the window keeps it
    send0(void, window, "center");
    send1(void, window, "makeKeyAndOrderFront:", nil);

    const html = nsString(webapp.page_html);
    _ = send2(id, webview, "loadHTMLString:baseURL:", html, nil);
    release(html);
    return true;
}

fn openWindow(title: []const u8) ?u32 {
    const n = next_id;
    if (!createWindow(n, title, 1000, 760)) return null;
    next_id += 1;
    return n;
}

/// Closing happens from the run loop: the request that asked for it is still being answered.
fn closeWindow(win: u32) void {
    if (win == 0) return;
    const w = winById(win) orelse return;
    send3(void, w.window, "performSelector:withObject:afterDelay:", sel_registerName("close"), nil, @as(f64, 0));
}

fn setDark(_: bool) void {}

/// Let the run loop deliver what is waiting (script calls to the web view, window events).
fn pump() void {
    const mode = default_mode orelse return;
    var n: usize = 0;
    while (n < 50) : (n += 1) {
        _ = send2(u8, send0(id, cls("NSRunLoop"), "currentRunLoop"), "runMode:beforeDate:", mode, send0(id, cls("NSDate"), "date"));
        const event = send4(id, ns_app, "nextEventMatchingMask:untilDate:inMode:dequeue:", ~@as(usize, 0), nil, mode, yes) orelse break;
        send1(void, ns_app, "sendEvent:", event);
    }
}

/// -[performDragOperation:] of the web view: files dropped on the window are opened. (The page
/// would get them without their paths.)
fn onPerformDrag(_: id, _: SEL, sender: id) callconv(.c) u8 {
    const board = send0(id, sender, "draggingPasteboard") orelse return no;
    const kind = nsString("NSFilenamesPboardType");
    defer release(kind);
    const files = send1(id, board, "propertyListForType:", kind) orelse return no;
    if (send1(u8, files, "isKindOfClass:", cls("NSArray")) == 0) return no;
    const n = send0(usize, files, "count");
    if (n == 0) return no;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = a.alloc([]const u8, n) catch return no;
    for (paths, 0..) |*p, i| p.* = a.dupe(u8, utf8(send1(id, files, "objectAtIndex:", i))) catch return no;
    webapp.openFromShell(paths);
    return yes;
}

var view_class: id = null;

/// WKWebView with the drop handled by pstview.
fn webViewClass() id {
    if (view_class == null) {
        const c = objc_allocateClassPair(cls("WKWebView"), "PstviewWebView", 0) orelse return cls("WKWebView");
        _ = class_addMethod(c, sel_registerName("performDragOperation:"), &onPerformDrag, "c@:@");
        objc_registerClassPair(c);
        view_class = c;
    }
    return view_class;
}

fn pickOpen(a: Allocator, title: []const u8, multiple: bool, folders: bool) ?[]const []const u8 {
    const panel = send0(id, cls("NSOpenPanel"), "openPanel");
    send1(void, panel, "setCanChooseFiles:", if (folders) no else yes);
    send1(void, panel, "setCanChooseDirectories:", if (folders) yes else no);
    send1(void, panel, "setAllowsMultipleSelection:", if (multiple) yes else no);
    send1(void, panel, "setCanCreateDirectories:", yes);
    const t = nsString(title);
    defer release(t);
    send1(void, panel, "setMessage:", t);
    if (send0(isize, panel, "runModal") != 1) return null;
    const urls = send0(id, panel, "URLs");
    const n = send0(usize, urls, "count");
    if (n == 0) return null;
    const out = a.alloc([]const u8, n) catch return null;
    for (out, 0..) |*p, i| {
        const url = send1(id, urls, "objectAtIndex:", i);
        p.* = a.dupe(u8, utf8(send0(id, url, "path"))) catch return null;
    }
    return out;
}

fn pickSave(a: Allocator, title: []const u8, name: []const u8) ?[]const u8 {
    const panel = send0(id, cls("NSSavePanel"), "savePanel");
    const t = nsString(title);
    defer release(t);
    send1(void, panel, "setMessage:", t);
    const nm = nsString(name);
    defer release(nm);
    send1(void, panel, "setNameFieldStringValue:", nm);
    send1(void, panel, "setCanCreateDirectories:", yes);
    if (send0(isize, panel, "runModal") != 1) return null;
    const url = send0(id, panel, "URL") orelse return null;
    return a.dupe(u8, utf8(send0(id, url, "path"))) catch null;
}

fn openPath(path: []const u8) void {
    const s = nsString(path);
    defer release(s);
    const url = send1(id, cls("NSURL"), "fileURLWithPath:", s);
    _ = send1(u8, send0(id, cls("NSWorkspace"), "sharedWorkspace"), "openURL:", url);
}

fn openUrl(url_text: []const u8) void {
    const s = nsString(url_text);
    defer release(s);
    const url = send1(id, cls("NSURL"), "URLWithString:", s) orelse return;
    _ = send1(u8, send0(id, cls("NSWorkspace"), "sharedWorkspace"), "openURL:", url);
}

fn quit(code: u8) void {
    webapp.deinit();
    std.process.exit(code);
}

// ================================================================ delegate (script messages, navigation, app events)

/// -[userContentController:didReceiveScriptMessage:]: a request from the page.
fn onScriptMessage(_: id, _: SEL, _: id, message: id) callconv(.c) void {
    const w = winByView(send0(id, message, "webView")) orelse return;
    const body = send0(id, message, "body") orelse return;
    if (send1(u8, body, "isKindOfClass:", cls("NSString")) == 0) return;
    webapp.onMessage(w.id, utf8(body));
}

/// -[windowWillClose:]: a message window goes away; closing the main window ends the program.
fn onWindowWillClose(_: id, _: SEL, notification: id) callconv(.c) void {
    const window = send0(id, notification, "object");
    for (wins.items, 0..) |w, i| if (w.window == window) {
        var gone = wins.swapRemove(i);
        forgetMenus(&gone);
        if (w.id == 0) send1(void, ns_app, "terminate:", nil) else webapp.windowClosed(w.id);
        return;
    };
}

/// -[webView:decidePolicyForNavigationAction:decisionHandler:]: only the page itself and the
/// about:srcdoc frames it fills are loaded; a link in a message never navigates anywhere.
fn onNavigation(_: id, _: SEL, view: id, action: id, handler: *Block) callconv(.c) void {
    var allow = false;
    const w = winByView(view);
    if (w != null and !w.?.first_load_done) {
        w.?.first_load_done = true;
        allow = true;
    } else {
        const url = send0(id, send0(id, action, "request"), "URL");
        allow = std.mem.startsWith(u8, utf8(send0(id, url, "absoluteString")), "about:");
    }
    handler.invoke(handler, if (allow) 1 else 0);
}

fn onLastWindowClosed(_: id, _: SEL, _: id) callconv(.c) u8 {
    return yes;
}

/// -[application:openFiles:]: files opened with pstview from Finder or dropped on its icon.
fn onOpenFiles(_: id, _: SEL, _: id, files: id) callconv(.c) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = send0(usize, files, "count");
    const paths = a.alloc([]const u8, n) catch return;
    for (paths, 0..) |*p, i| p.* = a.dupe(u8, utf8(send1(id, files, "objectAtIndex:", i))) catch return;
    webapp.openFromShell(paths);
}

fn makeDelegate() id {
    const c = objc_allocateClassPair(cls("NSObject"), "PstviewDelegate", 0);
    _ = class_addMethod(c, sel_registerName("userContentController:didReceiveScriptMessage:"), &onScriptMessage, "v@:@@");
    _ = class_addMethod(c, sel_registerName("webView:decidePolicyForNavigationAction:decisionHandler:"), &onNavigation, "v@:@@@?");
    _ = class_addMethod(c, sel_registerName("applicationShouldTerminateAfterLastWindowClosed:"), &onLastWindowClosed, "c@:@");
    _ = class_addMethod(c, sel_registerName("application:openFiles:"), &onOpenFiles, "v@:@@");
    _ = class_addMethod(c, sel_registerName("windowWillClose:"), &onWindowWillClose, "v@:@");
    _ = class_addMethod(c, sel_registerName("windowDidBecomeKey:"), &onWindowDidBecomeKey, "v@:@");
    _ = class_addMethod(c, sel_registerName("pvMenu:"), &onMenuItem, "v@:@");
    _ = class_addMethod(c, sel_registerName("pvPopup:"), &onPopupItem, "v@:@");
    _ = class_addMethod(c, sel_registerName("pvAbout:"), &onAboutItem, "v@:@");
    objc_registerClassPair(c);
    return send0(id, c, "new");
}

// ================================================================ menu bar

fn menuItem(menu: id, title: []const u8, action: ?[*:0]const u8, key: []const u8) void {
    const t = nsString(title);
    defer release(t);
    const k = nsString(key);
    defer release(k);
    const item = send3(id, send0(id, cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:", t, if (action) |s| sel_registerName(s) else @as(SEL, null), k);
    send1(void, menu, "addItem:", item);
    release(item);
}

fn submenu(bar: id, title: []const u8) id {
    const t = nsString(title);
    defer release(t);
    const menu = send1(id, send0(id, cls("NSMenu"), "alloc"), "initWithTitle:", t);
    const item = send0(id, cls("NSMenuItem"), "new");
    send1(void, item, "setSubmenu:", menu);
    send1(void, bar, "addItem:", item);
    release(item);
    return menu;
}

/// The application, Edit and Window menus. The page has its own menus for everything else; the
/// Edit menu is what makes Cmd+C / Cmd+V reach the web view.
fn makeMenus() void {
    const bar = send0(id, cls("NSMenu"), "new");
    const app_menu = submenu(bar, "pstview");
    menuItem(app_menu, "Hide pstview", "hide:", "h");
    menuItem(app_menu, "Quit pstview", "terminate:", "q");
    const edit = submenu(bar, "Edit");
    menuItem(edit, "Cut", "cut:", "x");
    menuItem(edit, "Copy", "copy:", "c");
    menuItem(edit, "Paste", "paste:", "v");
    const win = submenu(bar, "Window");
    menuItem(win, "Minimize", "performMiniaturize:", "m");
    menuItem(win, "Close", "performClose:", "w");
    send1(void, ns_app, "setMainMenu:", bar);
    send1(void, ns_app, "setWindowsMenu:", win);
}

// ================================================================ start

pub fn run(gpa_: Allocator, io: Io, start_paths: []const []const u8, selftest: bool) u8 {
    if (!loadRuntime()) {
        std.debug.print("pstview: cannot load AppKit / WebKit\n", .{});
        return 1;
    }
    gpa = gpa_;
    _ = send0(id, cls("NSAutoreleasePool"), "new");
    ns_app = send0(id, cls("NSApplication"), "sharedApplication");
    _ = send1(u8, ns_app, "setActivationPolicy:", @as(isize, 0)); // a regular app: dock icon and menu bar
    selftest_mode = selftest;
    if (std.c.getenv("PSTVIEW_NATIVE")) |v| native = !std.mem.eql(u8, std.mem.span(v), "0");
    var shell: webapp.Shell = .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openUrl, .setTitle = &setTitle, .openWindow = &openWindow, .closeWindow = &closeWindow, .pump = &pump, .setDark = &setDark, .quit = &quit };
    if (native) {
        shell.setMenus = &setMenus;
        shell.popup = &popup;
        shell.setStatus = &setStatus;
        shell.alert = &alert;
        shell.ask = &ask;
        shell.input = &input;
        shell.about = &about;
        shell.setTheme = &setTheme;
        shell.selftest_closes = true;
    }
    webapp.init(gpa, io, shell, start_paths, selftest);

    delegate = makeDelegate();
    send1(void, ns_app, "setDelegate:", delegate);
    makeMenus();

    if (!createWindow(0, "pstview", 1400, 900)) return 1;
    send1(void, ns_app, "activateIgnoringOtherApps:", yes);

    send0(void, ns_app, "run");
    webapp.deinit();
    return 0;
}

// ================================================================ native chrome

fn label(text: []const u8, frame: NSRect) id {
    const t = nsString(text);
    defer release(t);
    const l = send1(id, cls("NSTextField"), "labelWithString:", t);
    send1(void, l, "setFrame:", frame);
    send1(void, l, "setFont:", send1(id, cls("NSFont"), "systemFontOfSize:", @as(f64, 11)));
    return l;
}

fn setStatus(win: u32, text: []const u8) void {
    const w = winById(win) orelse return;
    const t = nsString(text);
    defer release(t);
    send1(void, w.status orelse return, "setStringValue:", t);
}

/// View > Theme: the windows (and their web views) take the chosen appearance, or the system's.
fn setTheme(choice: []const u8) void {
    const name: ?[]const u8 = if (std.mem.eql(u8, choice, "dark")) "NSAppearanceNameDarkAqua" else if (std.mem.eql(u8, choice, "light")) "NSAppearanceNameAqua" else null;
    const appearance: id = if (name) |n| blk: {
        const s = nsString(n);
        defer release(s);
        break :blk send1(id, cls("NSAppearance"), "appearanceNamed:", s);
    } else nil;
    send1(void, ns_app, "setAppearance:", appearance);
}

// ---------------------------------------------------------------- menus

/// A menu item for a page command: title, the delegate's selector, its tag, and the shortcut
/// when it is Cmd+letter. Enter and Esc are left to the page (a menu would take them from the
/// search field), and Cmd+A too (it selects the field's text there).
fn pageItem(it: webapp.MenuItem, selector: [*:0]const u8, tag: isize) id {
    var key: []const u8 = "";
    var kb: [1]u8 = undefined;
    if (std.mem.startsWith(u8, it.key, "Mod+") and it.key.len == 5 and std.ascii.isAlphabetic(it.key[4]) and std.ascii.toLower(it.key[4]) != 'a') {
        kb[0] = std.ascii.toLower(it.key[4]);
        key = &kb;
    }
    const t = nsString(it.label);
    defer release(t);
    const k = nsString(key);
    defer release(k);
    const item = send3(id, send0(id, cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:", t, sel_registerName(selector), k);
    send1(void, item, "setTarget:", delegate);
    send1(void, item, "setTag:", tag);
    setItemState(item, it);
    return item;
}

fn setItemState(item: id, it: webapp.MenuItem) void {
    send1(void, item, "setEnabled:", if (it.enabled) yes else no);
    if (it.checked) |c| send1(void, item, "setState:", @as(isize, if (c) 1 else 0));
}

/// `items` without "About" (it is in the application menu) and without separators at the ends or
/// next to each other.
fn macItems(a: Allocator, items: []const ?webapp.MenuItem) []const ?webapp.MenuItem {
    var out: std.ArrayList(?webapp.MenuItem) = .empty;
    for (items) |entry| {
        if (entry) |it| {
            if (std.mem.eql(u8, it.action, "about")) continue;
            out.append(a, it) catch return items;
        } else if (out.items.len > 0 and out.items[out.items.len - 1] != null) out.append(a, null) catch return items;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == null) _ = out.pop();
    return out.items;
}

fn newMenu(title: []const u8) id {
    const t = nsString(title);
    defer release(t);
    const menu = send1(id, send0(id, cls("NSMenu"), "alloc"), "initWithTitle:", t);
    send1(void, menu, "setAutoenablesItems:", no); // enabled as the page says
    return menu;
}

fn addSubmenu(bar: id, menu: id) void {
    const item = send0(id, cls("NSMenuItem"), "new");
    send1(void, item, "setSubmenu:", menu);
    send1(void, bar, "addItem:", item);
    release(item);
    release(menu); // the item keeps it
}

/// The menu bar of a window: the application menu, the page's menus with Edit after the first
/// and Window before Help, as macOS has them.
fn buildBar(w: *Win, menus: []const webapp.Menu) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    forgetItems(w);
    const bar = send0(id, cls("NSMenu"), "new");
    const app_menu = newMenu("pstview");
    const about_title = nsString("About pstview");
    const no_key = nsString("");
    const about_item = send3(id, send0(id, cls("NSMenuItem"), "alloc"), "initWithTitle:action:keyEquivalent:", about_title, sel_registerName("pvAbout:"), no_key);
    release(about_title);
    release(no_key);
    send1(void, about_item, "setTarget:", delegate);
    send1(void, app_menu, "addItem:", about_item);
    release(about_item);
    send1(void, app_menu, "addItem:", send0(id, cls("NSMenuItem"), "separatorItem"));
    menuItem(app_menu, "Hide pstview", "hide:", "h");
    menuItem(app_menu, "Quit pstview", "terminate:", "q");
    addSubmenu(bar, app_menu);
    var help: ?webapp.Menu = null;
    for (menus, 0..) |m, mi| {
        if (std.mem.eql(u8, m.label, "Help")) {
            help = m;
            continue;
        }
        addPageMenu(a, w, bar, m);
        if (mi == 0) {
            const edit = newMenu("Edit");
            menuItem(edit, "Cut", "cut:", "x");
            menuItem(edit, "Copy", "copy:", "c");
            menuItem(edit, "Paste", "paste:", "v");
            addSubmenu(bar, edit);
        }
    }
    const window_menu = newMenu("Window");
    menuItem(window_menu, "Minimize", "performMiniaturize:", "m");
    menuItem(window_menu, "Close", "performClose:", "w");
    send1(void, window_menu, "setAutoenablesItems:", yes);
    addSubmenu(bar, window_menu);
    w.window_menu = window_menu;
    if (help) |m| addPageMenu(a, w, bar, m);
    if (w.bar) |old| {
        if (send0(id, ns_app, "mainMenu") == old) send1(void, ns_app, "setMainMenu:", bar);
        release(old);
    }
    w.bar = bar;
}

fn addPageMenu(a: Allocator, w: *Win, bar: id, m: webapp.Menu) void {
    const menu = newMenu(m.label);
    for (macItems(a, m.items)) |entry| {
        const it = entry orelse {
            send1(void, menu, "addItem:", send0(id, cls("NSMenuItem"), "separatorItem"));
            continue;
        };
        const action = gpa.dupe(u8, it.action) catch continue;
        w.actions.append(gpa, action) catch {
            gpa.free(action);
            continue;
        };
        const item = pageItem(it, "pvMenu:", @intCast(@as(usize, w.id) * 1000 + w.actions.items.len - 1));
        send1(void, menu, "addItem:", item);
        w.items.append(gpa, item) catch {}; // (kept: released in forgetItems)
    }
    addSubmenu(bar, menu);
}

fn forgetItems(w: *Win) void {
    for (w.items.items) |item| release(item);
    w.items.clearRetainingCapacity();
    for (w.actions.items) |x| gpa.free(x);
    w.actions.clearRetainingCapacity();
}

fn forgetMenus(w: *Win) void {
    forgetItems(w);
    w.items.deinit(gpa);
    w.actions.deinit(gpa);
    gpa.free(w.shape);
    if (w.bar) |b| release(b);
}

/// Show window `w`'s menu bar while it is the key window.
fn showBar(w: *Win) void {
    const bar = w.bar orelse return;
    send1(void, ns_app, "setMainMenu:", bar);
    send1(void, ns_app, "setWindowsMenu:", w.window_menu);
}

fn setMenus(win: u32, menus: []const webapp.Menu) usize {
    const w = winById(win) orelse return 0;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The bar is made again only when its layout changes; otherwise its items are updated in
    // place, and an open menu stays open.
    var shape: std.ArrayList(u8) = .empty;
    for (menus) |m| {
        shape.print(a, "\x1e{s}", .{m.label}) catch return w.items.items.len;
        for (m.items) |entry| if (entry) |it| shape.print(a, "\x1f{s}\x1d{s}\x1d{s}", .{ it.label, it.action, it.key }) catch return 0 else shape.append(a, '|') catch return 0;
    }
    if (w.bar == null or !std.mem.eql(u8, shape.items, w.shape)) {
        buildBar(w, menus);
        gpa.free(w.shape);
        w.shape = gpa.dupe(u8, shape.items) catch &.{};
        if (send0(id, ns_app, "keyWindow") == w.window or win == 0 and send0(id, ns_app, "keyWindow") == nil) showBar(w);
        return w.items.items.len;
    }
    var i: usize = 0;
    for (menus) |m| for (macItems(a, m.items)) |entry| if (entry) |it| {
        if (i < w.items.items.len) setItemState(w.items.items[i], it);
        i += 1;
    };
    return w.items.items.len;
}

/// -[windowDidBecomeKey:]: the menu bar is that window's.
fn onWindowDidBecomeKey(_: id, _: SEL, notification: id) callconv(.c) void {
    const window = send0(id, notification, "object");
    for (wins.items) |*w| if (w.window == window) return showBar(w);
}

/// -[pvMenu:]: an item of a window's menu bar; its tag is window id * 1000 + item.
fn onMenuItem(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag: usize = @intCast(@max(send0(isize, sender, "tag"), 0));
    const w = winById(@intCast(tag / 1000)) orelse return;
    if (tag % 1000 < w.actions.items.len) webapp.menuAction(w.id, w.actions.items[tag % 1000]);
}

/// -[pvAbout:]: pstview > About pstview, shown by the page of the key window.
fn onAboutItem(_: id, _: SEL, _: id) callconv(.c) void {
    const key = send0(id, ns_app, "keyWindow");
    for (wins.items) |w| if (w.window == key) return webapp.menuAction(w.id, "about");
    webapp.menuAction(0, "about");
}

var popup_actions: std.ArrayList([]u8) = .empty;
var popup_win: u32 = 0;

fn onPopupItem(_: id, _: SEL, sender: id) callconv(.c) void {
    const tag: usize = @intCast(@max(send0(isize, sender, "tag"), 0));
    if (tag < popup_actions.items.len) webapp.menuAction(popup_win, popup_actions.items[tag]);
}

/// A context menu at the pointer (where the page was right-clicked).
fn popup(win: u32, _: f64, _: f64, items: []const ?webapp.MenuItem) void {
    for (popup_actions.items) |x| gpa.free(x);
    popup_actions.clearRetainingCapacity();
    popup_win = win;
    const menu = newMenu("");
    defer release(menu);
    for (items) |entry| {
        const it = entry orelse {
            send1(void, menu, "addItem:", send0(id, cls("NSMenuItem"), "separatorItem"));
            continue;
        };
        const action = gpa.dupe(u8, it.action) catch continue;
        popup_actions.append(gpa, action) catch {
            gpa.free(action);
            continue;
        };
        const item = pageItem(.{ .label = it.label, .action = it.action, .enabled = it.enabled, .checked = it.checked }, "pvPopup:", @intCast(popup_actions.items.len - 1));
        send1(void, menu, "addItem:", item);
        release(item);
    }
    if (selftest_mode) closeLater(menu, "cancelTracking", tracking_mode);
    const at = send0(NSPoint, cls("NSEvent"), "mouseLocation");
    _ = send3(u8, menu, "popUpMenuPositioningItem:atLocation:inView:", nil, at, nil);
}

// ---------------------------------------------------------------- dialogs

/// --selftest: `target` gets `selector` after a moment, in run loop mode `mode` (an alert's or a
/// menu's), which closes what it shows.
fn closeLater(target: id, selector: [*:0]const u8, mode: id) void {
    const m = mode orelse return;
    const modes = send1(id, cls("NSArray"), "arrayWithObject:", m);
    send4(void, target, "performSelector:withObject:afterDelay:inModes:", sel_registerName(selector), nil, @as(f64, 0.7), modes);
}

fn newAlert(title: []const u8, text: []const u8) id {
    const alert_ = send0(id, cls("NSAlert"), "new");
    const t = nsString(title);
    defer release(t);
    const x = nsString(text);
    defer release(x);
    send1(void, alert_, "setMessageText:", t);
    send1(void, alert_, "setInformativeText:", x);
    return alert_;
}

fn addButton(alert_: id, title: []const u8) void {
    const t = nsString(title);
    defer release(t);
    _ = send1(id, alert_, "addButtonWithTitle:", t);
}

/// Run an alert as a modal window; the self-test aborts it after a moment.
fn runAlert(alert_: id) isize {
    if (selftest_mode) closeLater(ns_app, "abortModal", modal_mode);
    return send0(isize, alert_, "runModal");
}

const first_button: isize = 1000;

fn alert(_: Allocator, _: u32, title: []const u8, text: []const u8) void {
    const a = newAlert(title, text);
    defer release(a);
    addButton(a, "OK");
    _ = runAlert(a);
}

/// The question: a button per choice (the notes go into the text), Cancel, and the check box as
/// the alert's suppression button.
fn ask(a: Allocator, q: webapp.Ask) ?webapp.Answer {
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(a, q.text) catch return null;
    for (q.choices) |c| if (c.note.len > 0) text.print(a, "\n\n{s}: {s}", .{ c.label, c.note }) catch return null;
    const al = newAlert(q.title, text.items);
    defer release(al);
    for (q.choices) |c| addButton(al, c.label);
    addButton(al, "Cancel");
    if (q.verification.len > 0) {
        send1(void, al, "setShowsSuppressionButton:", yes);
        const v = nsString(q.verification);
        defer release(v);
        send1(void, send0(id, al, "suppressionButton"), "setTitle:", v);
    }
    const r = runAlert(al);
    const verified = q.verification.len > 0 and send0(isize, send0(id, al, "suppressionButton"), "state") == 1;
    const i = r - first_button;
    return .{ .choice = if (i >= 0 and i < q.choices.len) @intCast(i) else null, .verified = verified };
}

/// Pasted headers: an alert with a text view.
fn input(a: Allocator, _: u32, title: []const u8, prompt: []const u8, ok: []const u8) ?[]const u8 {
    const al = newAlert(title, prompt);
    defer release(al);
    addButton(al, if (ok.len > 0) ok else "OK");
    addButton(al, "Cancel");
    const frame: NSRect = .{ .x = 0, .y = 0, .w = 520, .h = 280 };
    const scroll = send1(id, send0(id, cls("NSScrollView"), "alloc"), "initWithFrame:", frame);
    defer release(scroll);
    send1(void, scroll, "setHasVerticalScroller:", yes);
    const bezel_border: usize = 2;
    send1(void, scroll, "setBorderType:", bezel_border);
    const view = send1(id, send0(id, cls("NSTextView"), "alloc"), "initWithFrame:", frame);
    defer release(view);
    send1(void, view, "setFont:", send2(id, cls("NSFont"), "monospacedSystemFontOfSize:weight:", @as(f64, 11), @as(f64, 0)));
    send1(void, view, "setRichText:", no);
    send1(void, view, "setAutomaticQuoteSubstitutionEnabled:", no);
    send1(void, scroll, "setDocumentView:", view);
    send1(void, al, "setAccessoryView:", scroll);
    send1(void, send0(id, al, "window"), "setInitialFirstResponder:", view);
    if (runAlert(al) != first_button) return null;
    return a.dupe(u8, utf8(send0(id, view, "string"))) catch null;
}

/// The standard About panel, with the page's text as its credits.
fn about(_: Allocator, _: u32, info: webapp.About) void {
    const keys = [_]id{ nsString("ApplicationName"), nsString("ApplicationVersion"), nsString("Version"), nsString("Credits") };
    defer for (keys) |k| release(k);
    const credits_text = nsString(info.comments);
    defer release(credits_text);
    const credits = send1(id, send0(id, cls("NSAttributedString"), "alloc"), "initWithString:", credits_text);
    defer release(credits);
    const values = [_]id{ nsString("pstview"), nsString(info.version), nsString(""), credits };
    defer for (values[0..3]) |v| release(v);
    const dict = send3(id, cls("NSDictionary"), "dictionaryWithObjects:forKeys:count:", &values, &keys, @as(usize, keys.len));
    send1(void, ns_app, "orderFrontStandardAboutPanelWithOptions:", dict);
    if (selftest_mode) {
        // the panel is the key window now (never one of pstview's: closing that would end it)
        const panel = send0(id, ns_app, "keyWindow");
        for (wins.items) |w| if (w.window == panel) return;
        if (panel != nil) closeLater(panel, "close", default_mode);
    }
}
