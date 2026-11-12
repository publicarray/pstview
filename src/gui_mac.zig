//! pstview on macOS: a Cocoa window whose content is a WKWebView (the system web view), plus the
//! menu bar and the open / save panels. The page and the model behind it are in webapp.zig.
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

fn loadRuntime() bool {
    const objc = std.c.dlopen("/usr/lib/libobjc.A.dylib", .{ .LAZY = true }) orelse return false;
    _ = std.c.dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", .{ .LAZY = true }) orelse return false;
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
var window: id = null;
var webview: id = null;
var first_load_done = false;

// ================================================================ shell for webapp.zig

fn eval(js: []const u8) void {
    const s = nsString(js);
    defer release(s);
    send2(void, webview, "evaluateJavaScript:completionHandler:", s, nil);
}

fn setTitle(title: []const u8) void {
    const s = nsString(title);
    defer release(s);
    send1(void, window, "setTitle:", s);
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
    const body = send0(id, message, "body") orelse return;
    if (send1(u8, body, "isKindOfClass:", cls("NSString")) == 0) return;
    webapp.onMessage(utf8(body));
}

/// -[webView:decidePolicyForNavigationAction:decisionHandler:]: only the page itself and the
/// about:srcdoc frames it fills are loaded; a link in a message never navigates anywhere.
fn onNavigation(_: id, _: SEL, _: id, action: id, handler: *Block) callconv(.c) void {
    var allow = false;
    if (!first_load_done) {
        first_load_done = true;
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

pub fn run(gpa: Allocator, io: Io, start_paths: []const []const u8, selftest: bool) u8 {
    if (!loadRuntime()) {
        std.debug.print("pstview: cannot load AppKit / WebKit\n", .{});
        return 1;
    }
    _ = send0(id, cls("NSAutoreleasePool"), "new");
    ns_app = send0(id, cls("NSApplication"), "sharedApplication");
    _ = send1(u8, ns_app, "setActivationPolicy:", @as(isize, 0)); // a regular app: dock icon and menu bar
    webapp.init(gpa, io, .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openUrl, .setTitle = &setTitle, .quit = &quit }, start_paths, selftest);

    const delegate = makeDelegate();
    send1(void, ns_app, "setDelegate:", delegate);
    makeMenus();

    // web view: no persistent data store (nothing is written to disk), requests arrive at the delegate
    const config = send0(id, cls("WKWebViewConfiguration"), "new");
    send1(void, config, "setWebsiteDataStore:", send0(id, cls("WKWebsiteDataStore"), "nonPersistentDataStore"));
    const handler_name = nsString("pstview");
    send2(void, send0(id, config, "userContentController"), "addScriptMessageHandler:name:", delegate, handler_name);

    const frame: NSRect = .{ .x = 0, .y = 0, .w = 1400, .h = 900 };
    const style: usize = 1 | 2 | 4 | 8; // titled, closable, miniaturizable, resizable
    window = send4(id, send0(id, cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:", frame, style, @as(usize, 2), no);
    setTitle("pstview");
    webview = send2(id, send0(id, cls("WKWebView"), "alloc"), "initWithFrame:configuration:", frame, config);
    send1(void, webview, "setNavigationDelegate:", delegate);
    send1(void, window, "setContentView:", webview);
    send0(void, window, "center");
    send1(void, window, "makeKeyAndOrderFront:", nil);
    send1(void, ns_app, "activateIgnoringOtherApps:", yes);

    const html = nsString(webapp.page_html);
    _ = send2(id, webview, "loadHTMLString:baseURL:", html, nil);
    release(html);

    send0(void, ns_app, "run");
    webapp.deinit();
    return 0;
}
