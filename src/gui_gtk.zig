//! pstview on Linux: GTK 4 windows with a native menu bar and status bar around a WebKitGTK web
//! view (the desktop's own web engine), plus native dialogs, context menus and file choosers. The
//! page and the model behind it are in webapp.zig; what the menus contain is the page's.
//!
//! PSTVIEW_NATIVE=0 leaves the menus, status bar and dialogs to the page, as on Windows and macOS.
//!
//! On GNOME (or with PSTVIEW_ADWAITA=1) libadwaita is used where it is installed: a header bar
//! with the menus in its main menu instead of a menu bar, and libadwaita's dialogs and style.
//! PSTVIEW_ADWAITA=0, other desktops, or no libadwaita: plain GTK 4 with a menu bar.
//!
//! GTK and WebKitGTK are loaded at run time, so the program builds without their development
//! packages (and cross-compiles); at run time it needs libgtk-4 and libwebkitgtk-6.0, which
//! desktop distributions install by default or as one package.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const webapp = @import("webapp.zig");

const P = ?*anyopaque;
const Z = [*:0]const u8;
const GdkRGBA = extern struct { r: f32, g: f32, b: f32, a: f32 = 1 };
const GSList = extern struct { data: P, next: ?*GSList };
const AsyncReady = *const fn (P, P, P) callconv(.c) void;
const GdkRectangle = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
const GrapheneRect = extern struct { x: f32, y: f32, w: f32, h: f32 };

/// Every library function used, looked up by its field name.
const Lib = struct {
    gtk_init_check: *const fn () callconv(.c) c_int,
    g_set_prgname: *const fn (Z) callconv(.c) void,
    g_set_application_name: *const fn (Z) callconv(.c) void,
    gtk_window_new: *const fn () callconv(.c) P,
    gtk_window_set_title: *const fn (P, Z) callconv(.c) void,
    gtk_window_set_default_size: *const fn (P, c_int, c_int) callconv(.c) void,
    gtk_window_set_icon_name: *const fn (P, Z) callconv(.c) void,
    gtk_window_set_child: *const fn (P, P) callconv(.c) void,
    gtk_window_present: *const fn (P) callconv(.c) void,
    gtk_window_destroy: *const fn (P) callconv(.c) void,
    g_timeout_add: *const fn (c_uint, *const fn (P) callconv(.c) c_int, P) callconv(.c) c_uint,
    g_idle_add: *const fn (*const fn (P) callconv(.c) c_int, P) callconv(.c) c_uint,
    g_main_loop_new: *const fn (P, c_int) callconv(.c) P,
    g_main_loop_run: *const fn (P) callconv(.c) void,
    g_main_loop_quit: *const fn (P) callconv(.c) void,
    g_main_context_pending: *const fn (P) callconv(.c) c_int,
    g_main_context_iteration: *const fn (P, c_int) callconv(.c) c_int,
    g_signal_connect_data: *const fn (P, Z, *const anyopaque, P, P, c_int) callconv(.c) c_ulong,
    g_object_new: *const fn (usize, ?Z, ...) callconv(.c) P,
    g_object_unref: *const fn (P) callconv(.c) void,
    g_free: *const fn (P) callconv(.c) void,
    g_slist_free: *const fn (?*GSList) callconv(.c) void,
    g_get_home_dir: *const fn () callconv(.c) ?Z,
    g_file_new_for_path: *const fn (Z) callconv(.c) P,
    g_file_get_path: *const fn (P) callconv(.c) ?[*:0]u8,
    g_list_model_get_n_items: *const fn (P) callconv(.c) c_uint,
    g_list_model_get_item: *const fn (P, c_uint) callconv(.c) P,
    g_value_get_boxed: *const fn (P) callconv(.c) P,
    gtk_file_dialog_new: *const fn () callconv(.c) P,
    gtk_file_dialog_set_title: *const fn (P, Z) callconv(.c) void,
    gtk_file_dialog_set_modal: *const fn (P, c_int) callconv(.c) void,
    gtk_file_dialog_set_initial_folder: *const fn (P, P) callconv(.c) void,
    gtk_file_dialog_set_initial_name: *const fn (P, Z) callconv(.c) void,
    gtk_file_dialog_open: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    gtk_file_dialog_open_finish: *const fn (P, P, P) callconv(.c) P,
    gtk_file_dialog_open_multiple: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    gtk_file_dialog_open_multiple_finish: *const fn (P, P, P) callconv(.c) P,
    gtk_file_dialog_select_folder: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    gtk_file_dialog_select_folder_finish: *const fn (P, P, P) callconv(.c) P,
    gtk_file_dialog_save: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    gtk_file_dialog_save_finish: *const fn (P, P, P) callconv(.c) P,
    gtk_uri_launcher_new: *const fn (Z) callconv(.c) P,
    gtk_uri_launcher_launch: *const fn (P, P, P, ?AsyncReady, P) callconv(.c) void,
    gtk_file_launcher_new: *const fn (P) callconv(.c) P,
    gtk_file_launcher_launch: *const fn (P, P, P, ?AsyncReady, P) callconv(.c) void,
    gtk_drop_target_new: *const fn (usize, c_int) callconv(.c) P,
    gtk_widget_add_controller: *const fn (P, P) callconv(.c) void,
    gtk_event_controller_set_propagation_phase: *const fn (P, c_int) callconv(.c) void,
    gdk_file_list_get_type: *const fn () callconv(.c) usize,
    gdk_file_list_get_files: *const fn (P) callconv(.c) ?*GSList,
    gdk_texture_save_to_png: *const fn (P, Z) callconv(.c) c_int,
    webkit_web_view_get_type: *const fn () callconv(.c) usize,
    webkit_network_session_new_ephemeral: *const fn () callconv(.c) P,
    webkit_user_content_manager_new: *const fn () callconv(.c) P,
    webkit_user_content_manager_register_script_message_handler: *const fn (P, Z, ?Z) callconv(.c) c_int,
    webkit_web_view_load_html: *const fn (P, Z, ?Z) callconv(.c) void,
    webkit_web_view_evaluate_javascript: *const fn (P, [*]const u8, isize, ?Z, ?Z, P, ?AsyncReady, P) callconv(.c) void,
    webkit_web_view_set_background_color: *const fn (P, *const GdkRGBA) callconv(.c) void,
    webkit_web_view_get_snapshot: *const fn (P, c_int, c_int, P, AsyncReady, P) callconv(.c) void,
    webkit_web_view_get_snapshot_finish: *const fn (P, P, P) callconv(.c) P,
    jsc_value_to_string: *const fn (P) callconv(.c) ?[*:0]u8,
    webkit_navigation_policy_decision_get_navigation_action: *const fn (P) callconv(.c) P,
    webkit_navigation_action_get_request: *const fn (P) callconv(.c) P,
    webkit_uri_request_get_uri: *const fn (P) callconv(.c) ?Z,
    webkit_policy_decision_ignore: *const fn (P) callconv(.c) void,

    // native chrome
    g_object_set: *const fn (P, Z, ...) callconv(.c) void,
    g_object_get: *const fn (P, Z, ...) callconv(.c) void,
    g_object_class_find_property: *const fn (P, Z) callconv(.c) P,
    g_markup_escape_text: *const fn ([*]const u8, isize) callconv(.c) ?[*:0]u8,
    g_menu_new: *const fn () callconv(.c) P,
    g_menu_append_submenu: *const fn (P, Z, P) callconv(.c) void,
    g_menu_append_section: *const fn (P, ?Z, P) callconv(.c) void,
    g_menu_append_item: *const fn (P, P) callconv(.c) void,
    g_menu_item_new: *const fn (Z, ?Z) callconv(.c) P,
    g_menu_item_set_attribute_value: *const fn (P, Z, P) callconv(.c) void,
    g_variant_new_string: *const fn (Z) callconv(.c) P,
    g_variant_new_boolean: *const fn (c_int) callconv(.c) P,
    g_simple_action_group_new: *const fn () callconv(.c) P,
    g_action_map_add_action: *const fn (P, P) callconv(.c) void,
    g_action_map_lookup_action: *const fn (P, Z) callconv(.c) P,
    g_simple_action_new: *const fn (Z, P) callconv(.c) P,
    g_simple_action_new_stateful: *const fn (Z, P, P) callconv(.c) P,
    g_simple_action_set_enabled: *const fn (P, c_int) callconv(.c) void,
    g_simple_action_set_state: *const fn (P, P) callconv(.c) void,
    g_action_get_name: *const fn (P) callconv(.c) ?Z,
    gtk_widget_insert_action_group: *const fn (P, Z, P) callconv(.c) void,
    gtk_popover_menu_bar_new_from_model: *const fn (P) callconv(.c) P,
    gtk_popover_menu_bar_set_menu_model: *const fn (P, P) callconv(.c) void,
    gtk_popover_menu_new_from_model: *const fn (P) callconv(.c) P,
    gtk_popover_set_pointing_to: *const fn (P, *const GdkRectangle) callconv(.c) void,
    gtk_popover_set_has_arrow: *const fn (P, c_int) callconv(.c) void,
    gtk_popover_popup: *const fn (P) callconv(.c) void,
    gtk_popover_popdown: *const fn (P) callconv(.c) void,
    g_usleep: *const fn (c_ulong) callconv(.c) void,
    gtk_stack_get_type: *const fn () callconv(.c) usize,
    g_action_group_list_actions: *const fn (P) callconv(.c) ?[*:null]?[*:0]u8,
    g_strfreev: *const fn (?[*:null]?[*:0]u8) callconv(.c) void,
    gtk_stack_set_hhomogeneous: *const fn (P, c_int) callconv(.c) void,
    gtk_stack_set_interpolate_size: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_get_first_child: *const fn (P) callconv(.c) P,
    gtk_widget_get_next_sibling: *const fn (P) callconv(.c) P,
    g_type_check_instance_is_a: *const fn (P, usize) callconv(.c) c_int,
    gtk_menu_button_new: *const fn () callconv(.c) P,
    gtk_menu_button_set_icon_name: *const fn (P, Z) callconv(.c) void,
    gtk_menu_button_set_menu_model: *const fn (P, P) callconv(.c) void,
    gtk_menu_button_set_primary: *const fn (P, c_int) callconv(.c) void,
    gtk_menu_button_popup: *const fn (P) callconv(.c) void,
    gtk_menu_button_popdown: *const fn (P) callconv(.c) void,
    gtk_menu_button_get_popover: *const fn (P) callconv(.c) P,
    gtk_button_new_from_icon_name: *const fn (Z) callconv(.c) P,
    gtk_actionable_set_action_name: *const fn (P, Z) callconv(.c) void,
    gtk_widget_set_tooltip_text: *const fn (P, Z) callconv(.c) void,
    gtk_list_box_new: *const fn () callconv(.c) P,
    gtk_list_box_append: *const fn (P, P) callconv(.c) void,
    gtk_list_box_set_selection_mode: *const fn (P, c_int) callconv(.c) void,
    gtk_list_box_row_get_index: *const fn (P) callconv(.c) c_int,
    gtk_list_box_row_set_activatable: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_activate: *const fn (P) callconv(.c) c_int,
    gtk_image_new_from_icon_name: *const fn (Z) callconv(.c) P,
    g_cancellable_new: *const fn () callconv(.c) P,
    g_cancellable_cancel: *const fn (P) callconv(.c) void,
    gtk_widget_set_parent: *const fn (P, P) callconv(.c) void,
    gtk_widget_unparent: *const fn (P) callconv(.c) void,
    gtk_widget_set_halign: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_hexpand: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_vexpand: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_margin_top: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_margin_bottom: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_margin_start: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_set_margin_end: *const fn (P, c_int) callconv(.c) void,
    gtk_widget_add_css_class: *const fn (P, Z) callconv(.c) void,
    gtk_widget_grab_focus: *const fn (P) callconv(.c) c_int,
    gtk_widget_get_width: *const fn (P) callconv(.c) c_int,
    gtk_widget_compute_bounds: *const fn (P, P, *GrapheneRect) callconv(.c) c_int,
    gtk_widget_get_height: *const fn (P) callconv(.c) c_int,
    gtk_widget_get_scale_factor: *const fn (P) callconv(.c) c_int,
    gtk_box_new: *const fn (c_int, c_int) callconv(.c) P,
    gtk_box_append: *const fn (P, P) callconv(.c) void,
    gtk_label_new: *const fn (?Z) callconv(.c) P,
    gtk_label_set_text: *const fn (P, Z) callconv(.c) void,
    gtk_label_set_markup: *const fn (P, Z) callconv(.c) void,
    gtk_label_set_xalign: *const fn (P, f32) callconv(.c) void,
    gtk_label_set_wrap: *const fn (P, c_int) callconv(.c) void,
    gtk_label_set_max_width_chars: *const fn (P, c_int) callconv(.c) void,
    gtk_label_set_ellipsize: *const fn (P, c_int) callconv(.c) void,
    gtk_label_set_selectable: *const fn (P, c_int) callconv(.c) void,
    gtk_button_new: *const fn () callconv(.c) P,
    gtk_button_new_with_label: *const fn (Z) callconv(.c) P,
    gtk_button_set_child: *const fn (P, P) callconv(.c) void,
    gtk_check_button_new_with_label: *const fn (Z) callconv(.c) P,
    gtk_check_button_get_active: *const fn (P) callconv(.c) c_int,
    gtk_window_set_transient_for: *const fn (P, P) callconv(.c) void,
    gtk_window_set_modal: *const fn (P, c_int) callconv(.c) void,
    gtk_window_set_resizable: *const fn (P, c_int) callconv(.c) void,
    gtk_window_set_default_widget: *const fn (P, P) callconv(.c) void,
    gtk_event_controller_key_new: *const fn () callconv(.c) P,
    gtk_scrolled_window_new: *const fn () callconv(.c) P,
    gtk_scrolled_window_set_child: *const fn (P, P) callconv(.c) void,
    gtk_scrolled_window_set_min_content_height: *const fn (P, c_int) callconv(.c) void,
    gtk_scrolled_window_set_min_content_width: *const fn (P, c_int) callconv(.c) void,
    gtk_text_view_new: *const fn () callconv(.c) P,
    gtk_text_view_get_buffer: *const fn (P) callconv(.c) P,
    gtk_text_view_set_monospace: *const fn (P, c_int) callconv(.c) void,
    gtk_text_view_set_wrap_mode: *const fn (P, c_int) callconv(.c) void,
    gtk_alert_dialog_new: *const fn (Z, ...) callconv(.c) P,
    gtk_alert_dialog_set_detail: *const fn (P, Z) callconv(.c) void,
    gtk_alert_dialog_set_buttons: *const fn (P, [*:null]const ?Z) callconv(.c) void,
    gtk_alert_dialog_choose: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    gtk_alert_dialog_choose_finish: *const fn (P, P, P) callconv(.c) c_int,
    gtk_about_dialog_new: *const fn () callconv(.c) P,
    gtk_about_dialog_set_program_name: *const fn (P, Z) callconv(.c) void,
    gtk_about_dialog_set_version: *const fn (P, Z) callconv(.c) void,
    gtk_about_dialog_set_comments: *const fn (P, Z) callconv(.c) void,
    gtk_about_dialog_set_website: *const fn (P, Z) callconv(.c) void,
    gtk_about_dialog_set_website_label: *const fn (P, Z) callconv(.c) void,
    gtk_about_dialog_set_logo: *const fn (P, P) callconv(.c) void,
    gtk_icon_theme_get_for_display: *const fn (P) callconv(.c) P,
    gtk_icon_theme_add_search_path: *const fn (P, Z) callconv(.c) void,
    gtk_icon_theme_has_icon: *const fn (P, Z) callconv(.c) c_int,
    g_file_set_contents: *const fn (Z, [*]const u8, isize, P) callconv(.c) c_int,
    g_mkdir_with_parents: *const fn (Z, c_int) callconv(.c) c_int,
    g_get_user_runtime_dir: *const fn () callconv(.c) Z,
    g_bytes_new_static: *const fn ([*]const u8, usize) callconv(.c) P,
    g_bytes_unref: *const fn (P) callconv(.c) void,
    gdk_texture_new_from_bytes: *const fn (P, P) callconv(.c) P,
    gtk_css_provider_new: *const fn () callconv(.c) P,
    gtk_css_provider_load_from_string: *const fn (P, Z) callconv(.c) void,
    gtk_style_context_add_provider_for_display: *const fn (P, P, c_uint) callconv(.c) void,
    gdk_display_get_default: *const fn () callconv(.c) P,
    gtk_settings_get_default: *const fn () callconv(.c) P,
    gtk_settings_reset_property: *const fn (P, Z) callconv(.c) void,
    gtk_widget_paintable_new: *const fn (P) callconv(.c) P,
    gdk_paintable_snapshot: *const fn (P, P, f64, f64) callconv(.c) void,
    gtk_snapshot_new: *const fn () callconv(.c) P,
    gtk_snapshot_scale: *const fn (P, f32, f32) callconv(.c) void,
    gtk_snapshot_free_to_node: *const fn (P) callconv(.c) P,
    gtk_native_get_renderer: *const fn (P) callconv(.c) P,
    gsk_renderer_render_texture: *const fn (P, P, *const GrapheneRect) callconv(.c) P,
};

var lib: Lib = undefined;
var handles: [2]P = .{ null, null };

/// libadwaita 1.5+ (GNOME 46), when it is used.
const Adw = struct {
    adw_init: *const fn () callconv(.c) void,
    adw_window_new: *const fn () callconv(.c) P,
    adw_window_set_content: *const fn (P, P) callconv(.c) void,
    adw_toolbar_view_new: *const fn () callconv(.c) P,
    adw_toolbar_view_set_content: *const fn (P, P) callconv(.c) void,
    adw_toolbar_view_add_top_bar: *const fn (P, P) callconv(.c) void,
    adw_toolbar_view_add_bottom_bar: *const fn (P, P) callconv(.c) void,
    adw_header_bar_new: *const fn () callconv(.c) P,
    adw_header_bar_pack_start: *const fn (P, P) callconv(.c) void,
    adw_header_bar_pack_end: *const fn (P, P) callconv(.c) void,
    adw_style_manager_get_default: *const fn () callconv(.c) P,
    adw_style_manager_set_color_scheme: *const fn (P, c_int) callconv(.c) void,
    adw_style_manager_get_dark: *const fn (P) callconv(.c) c_int,
    adw_alert_dialog_new: *const fn (?Z, ?Z) callconv(.c) P,
    adw_alert_dialog_add_response: *const fn (P, Z, Z) callconv(.c) void,
    adw_alert_dialog_set_response_appearance: *const fn (P, Z, c_int) callconv(.c) void,
    adw_alert_dialog_set_default_response: *const fn (P, ?Z) callconv(.c) void,
    adw_alert_dialog_set_close_response: *const fn (P, Z) callconv(.c) void,
    adw_alert_dialog_set_extra_child: *const fn (P, P) callconv(.c) void,
    adw_alert_dialog_set_prefer_wide_layout: *const fn (P, c_int) callconv(.c) void,
    adw_alert_dialog_choose: *const fn (P, P, P, AsyncReady, P) callconv(.c) void,
    adw_alert_dialog_choose_finish: *const fn (P, P) callconv(.c) ?Z,
    adw_dialog_present: *const fn (P, P) callconv(.c) void,
    adw_dialog_close: *const fn (P) callconv(.c) c_int,
    adw_about_dialog_new: *const fn () callconv(.c) P,
    adw_about_dialog_set_application_name: *const fn (P, Z) callconv(.c) void,
    adw_about_dialog_set_application_icon: *const fn (P, Z) callconv(.c) void,
    adw_about_dialog_set_version: *const fn (P, Z) callconv(.c) void,
    adw_about_dialog_set_comments: *const fn (P, Z) callconv(.c) void,
    adw_about_dialog_set_website: *const fn (P, Z) callconv(.c) void,
    adw_action_row_new: *const fn () callconv(.c) P,
    adw_action_row_add_suffix: *const fn (P, P) callconv(.c) void,
    adw_action_row_set_subtitle: *const fn (P, Z) callconv(.c) void,
    adw_preferences_row_set_title: *const fn (P, Z) callconv(.c) void,
};
var adw: ?Adw = null;

/// libadwaita on GNOME, unless PSTVIEW_ADWAITA says otherwise (1: everywhere, 0: never).
fn loadAdwaita() void {
    const wanted = if (std.c.getenv("PSTVIEW_ADWAITA")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else blk: {
        const desktop = std.mem.span(std.c.getenv("XDG_CURRENT_DESKTOP") orelse break :blk false);
        var it = std.mem.splitScalar(u8, desktop, ':');
        while (it.next()) |d| if (std.ascii.eqlIgnoreCase(d, "GNOME")) break :blk true;
        break :blk false;
    };
    if (!wanted) return;
    const h = std.c.dlopen("libadwaita-1.so.0", .{ .LAZY = true }) orelse return;
    var t: Adw = undefined;
    inline for (@typeInfo(Adw).@"struct".field_names) |name| {
        @field(t, name) = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return)); // too old: plain GTK
    }
    adw = t;
}

fn lookup(name: Z) ?*anyopaque {
    for (handles) |h| if (std.c.dlsym(h, name)) |p| return p;
    return null;
}

/// Load GTK 4 and WebKitGTK 6.0 (the WebKitGTK built for GTK 4); null on success, else the
/// missing piece.
fn loadLibraries() ?[]const u8 {
    handles[0] = std.c.dlopen("libgtk-4.so.1", .{ .LAZY = true }) orelse return "libgtk-4.so.1 (GTK 4)";
    handles[1] = std.c.dlopen("libwebkitgtk-6.0.so.4", .{ .LAZY = true }) orelse return "libwebkitgtk-6.0.so.4 (WebKitGTK 6.0)";
    inline for (@typeInfo(Lib).@"struct".field_names) |name| {
        @field(lib, name) = @ptrCast(@alignCast(lookup(name) orelse return name));
    }
    return null;
}

var gpa: Allocator = undefined;
/// The main window (id 0), parent of the dialogs.
var window: P = null;
var network_session: P = null;
var main_loop: P = null;
var app_id: Z = "pstview";
/// Menu bar, status bar and dialogs are native (else the page draws them).
var native = true;

/// One window and its web view. Signal handlers get the id as their user data.
const Win = struct {
    id: u32,
    window: P,
    webview: P,
    first_load_done: bool = false,
    shown: bool = false,
    /// What is under the window: the web view, or the box of menu bar, web view and status bar.
    content: P = null,
    menubar: P = null,
    status: P = null,
    /// The actions of the menu bar ("m.<command>") and the layout they were made for.
    actions: P = null,
    menu_shape: []u8 = &.{},
};
var wins: std.ArrayList(Win) = .empty;
var next_id: u32 = 1;

fn winById(id: u32) ?*Win {
    for (wins.items) |*w| if (w.id == id) return w;
    return null;
}

fn idOf(data: P) u32 {
    return @intCast(@intFromPtr(data));
}

/// Run the main loop until `done` is set: the dialogs of GTK 4 answer asynchronously, the model
/// asks synchronously.
fn waitFor(done: *const bool) void {
    while (!done.*) _ = lib.g_main_context_iteration(null, 1);
}

// ================================================================ shell for webapp.zig

fn eval(win: u32, js: []const u8) void {
    const webview = (winById(win) orelse return).webview;
    lib.webkit_web_view_evaluate_javascript(webview, js.ptr, @intCast(js.len), null, null, null, null, null);
}

/// A window showing the page; requests from it arrive as script messages carrying its id.
fn createWindow(id: u32, title: []const u8, width: c_int, height: c_int) bool {
    const w = (if (adw) |ad| ad.adw_window_new() else lib.gtk_window_new()) orelse return false;
    const data: P = @ptrFromInt(id);
    var buf: [1024]u8 = undefined;
    lib.gtk_window_set_title(w, std.fmt.bufPrintSentinel(&buf, "{s}", .{title[0..@min(title.len, 1000)]}, 0) catch "pstview");
    lib.gtk_window_set_default_size(w, width, height);
    lib.gtk_window_set_icon_name(w, app_id);
    _ = lib.g_signal_connect_data(w, "destroy", &onDestroy, data, null, 0);

    // web view: an ephemeral session (nothing is written to disk), requests arrive as script messages
    const manager = lib.webkit_user_content_manager_new();
    _ = lib.g_signal_connect_data(manager, "script-message-received::pstview", &onScriptMessage, data, null, 0);
    _ = lib.webkit_user_content_manager_register_script_message_handler(manager, "pstview", null);
    const view = lib.g_object_new(lib.webkit_web_view_get_type(), "network-session", network_session, "user-content-manager", manager, @as(P, null));
    lib.g_object_unref(manager);
    _ = lib.g_signal_connect_data(view, "decide-policy", &onDecidePolicy, data, null, 0);
    _ = lib.g_signal_connect_data(view, "context-menu", &onContextMenu, null, null, 0);
    if (id == 0) addDropTarget(w);
    var win: Win = .{ .id = id, .window = w, .webview = view, .content = view };
    if (native and adw != null) {
        // header bar (Open, and the menus in the main menu: setMenus), web view, status bar
        const ad = adw.?;
        const view_box = ad.adw_toolbar_view_new();
        const header = ad.adw_header_bar_new();
        if (id == 0) {
            const open = lib.gtk_button_new_from_icon_name("document-open-symbolic");
            lib.gtk_actionable_set_action_name(open, "m.open");
            lib.gtk_widget_set_tooltip_text(open, "Open PST / OST / MBOX file (Ctrl+O)");
            ad.adw_header_bar_pack_start(header, open);
        }
        win.menubar = lib.gtk_menu_button_new();
        lib.gtk_menu_button_set_icon_name(win.menubar, "open-menu-symbolic");
        lib.gtk_menu_button_set_primary(win.menubar, 1); // F10
        lib.gtk_widget_set_tooltip_text(win.menubar, "Main Menu");
        ad.adw_header_bar_pack_end(header, win.menubar);
        ad.adw_toolbar_view_add_top_bar(view_box, header);
        ad.adw_toolbar_view_set_content(view_box, view);
        ad.adw_toolbar_view_add_bottom_bar(view_box, statusBar(&win));
        win.content = view_box;
    } else if (native) {
        // menu bar (filled by the page: setMenus), web view, status bar
        const vertical = 1;
        const box = lib.gtk_box_new(vertical, 0);
        win.menubar = lib.gtk_popover_menu_bar_new_from_model(null);
        lib.gtk_box_append(box, win.menubar);
        lib.gtk_widget_set_vexpand(view, 1);
        lib.gtk_box_append(box, view);
        lib.gtk_box_append(box, statusBar(&win));
        win.content = box;
    }
    wins.append(gpa, win) catch {
        lib.gtk_window_destroy(w);
        return false;
    };
    if (adw) |ad| ad.adw_window_set_content(w, win.content) else lib.gtk_window_set_child(w, win.content);
    // The window appears once its page has settled on light or dark (setDark), so that a dark
    // session never sees a white window first; and in any case after a moment.
    lib.webkit_web_view_load_html(view, webapp.page_html, null);
    _ = lib.g_timeout_add(1500, &showLater, data);
    return true;
}

fn openWindow(title: []const u8) ?u32 {
    const id = next_id;
    if (!createWindow(id, title, 1000, 760)) return null;
    next_id += 1;
    return id;
}

fn destroyLater(data: P) callconv(.c) c_int {
    if (winById(idOf(data))) |w| lib.gtk_window_destroy(w.window);
    return 0; // once
}

/// Closing happens from the main loop: the request that asked for it is still being answered.
fn closeWindow(win: u32) void {
    if (win != 0) _ = lib.g_idle_add(&destroyLater, @ptrFromInt(win));
}

fn show(w: *Win) void {
    if (w.shown) return;
    w.shown = true;
    lib.gtk_window_present(w.window);
}

fn showLater(data: P) callconv(.c) c_int {
    if (winById(idOf(data))) |w| show(w);
    return 0; // once
}

/// A page has applied its theme: the web views get the page's ground colour (what shows before
/// a page is painted), and windows waiting for their page appear.
var page_dark = false;

fn setDark(dark: bool) void {
    page_dark = dark;
    const ground: GdkRGBA = if (dark) .{ .r = 15.0 / 255.0, .g = 23.0 / 255.0, .b = 36.0 / 255.0 } else .{ .r = 1, .g = 1, .b = 1 };
    for (wins.items) |*w| {
        lib.webkit_web_view_set_background_color(w.webview, &ground);
        show(w);
    }
}

/// Let GTK handle what is waiting (bounded: a busy display must not hold up the request).
fn pump() void {
    var n: usize = 0;
    while (n < 500 and lib.g_main_context_pending(null) != 0) : (n += 1) _ = lib.g_main_context_iteration(null, 0);
}

// ================================================================ picture of the page (--screenshot)

fn onSnapshot(view: P, result: P, data: P) callconv(.c) void {
    const path: [*:0]const u8 = @ptrCast(data.?);
    const texture = lib.webkit_web_view_get_snapshot_finish(view, result, null) orelse return quit(1);
    quit(if (lib.gdk_texture_save_to_png(texture, path) != 0) 0 else 1);
}

fn snapshot(path: []const u8) void {
    const w = winById(0) orelse return quit(1);
    const z = gpa.dupeSentinel(u8, path, 0) catch return quit(1);
    if (adw != null and shots_dir != null and !menu_pictured) {
        // with PSTVIEW_SHOTS: first a picture of the open main menu (<folder>/menu-<theme>.png)
        menu_pictured = true;
        lib.gtk_menu_button_popup(w.menubar);
        snapshot_path = z;
        _ = lib.g_timeout_add(700, &pictureMenu, null);
        return;
    }
    if (!native) return lib.webkit_web_view_get_snapshot(w.webview, 0, 0, null, &onSnapshot, @constCast(z.ptr)); // the visible part, as shown
    // the window's content (menu bar and status bar included, no title bar or shadow)
    quit(if (writePngSoon(w.window, w.content, z.ptr)) 0 else 1);
}

var menu_pictured = false;
var snapshot_path: [:0]const u8 = "";

fn pictureMenu(_: P) callconv(.c) c_int {
    const w = winById(0) orelse return 0;
    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrintSentinel(&buf, "{s}/menu-{s}.png", .{ shots_dir.?, if (page_dark) "dark" else "light" }, 0)) |p| {
        const popover = lib.gtk_menu_button_get_popover(w.menubar);
        if (!writePngSoon(popover, popover, p.ptr)) std.debug.print("pstview: no picture of the main menu\n", .{});
    } else |_| {}
    lib.gtk_menu_button_popdown(w.menubar);
    snapshot(snapshot_path);
    return 0; // once
}

/// writePng, waiting for a frame: a window whose content has just changed (a dialog opened, a
/// menu closed) has none to picture until it has been drawn again.
fn writePngSoon(native_widget: P, part: P, path: Z) bool {
    for (0..20) |_| {
        if (writePng(native_widget, part, path)) return true;
        pump();
        lib.g_usleep(30_000);
    }
    return false;
}

/// Write a picture of `part` (a widget of the surface `native`, or all of it) as drawn, with the
/// surface's background, at the display's scale.
fn writePng(native_widget: P, part: P, path: Z) bool {
    var bounds: GrapheneRect = undefined;
    if (lib.gtk_widget_compute_bounds(part, native_widget, &bounds) == 0) return false;
    const scale: f32 = @floatFromInt(@max(lib.gtk_widget_get_scale_factor(native_widget), 1));
    const paintable = lib.gtk_widget_paintable_new(native_widget);
    defer lib.g_object_unref(paintable);
    const snap = lib.gtk_snapshot_new();
    lib.gtk_snapshot_scale(snap, scale, scale);
    lib.gdk_paintable_snapshot(paintable, snap, @floatFromInt(lib.gtk_widget_get_width(native_widget)), @floatFromInt(lib.gtk_widget_get_height(native_widget)));
    const node = lib.gtk_snapshot_free_to_node(snap) orelse return false; // not drawn yet
    const viewport: GrapheneRect = .{ .x = bounds.x * scale, .y = bounds.y * scale, .w = bounds.w * scale, .h = bounds.h * scale };
    const texture = lib.gsk_renderer_render_texture(lib.gtk_native_get_renderer(native_widget), node, &viewport) orelse return false;
    defer lib.g_object_unref(texture);
    return lib.gdk_texture_save_to_png(texture, path) != 0;
}

// ================================================================ self-test of the native dialogs

/// --selftest: every native dialog and menu the page opens closes itself after a moment, as if
/// cancelled. With PSTVIEW_SHOTS=<folder> each is pictured first (<folder>/<name>.png).
var selftest_mode = false;
/// The first choice of the question being shown: the self-test takes it, as a click does.
var selftest_choice: P = null;
/// A question (ask) is waiting for its answer.
var asking = false;
var shots_dir: ?[]const u8 = null;

const AutoClose = struct { kind: enum { modal, about, popover, alert, adw }, target: P, name: []const u8, shot: P = null };

fn autoClose(kind: @TypeOf(@as(AutoClose, undefined).kind), target: P, name: []const u8) void {
    autoCloseShot(kind, target, name, null);
}

/// `shot`: what to picture instead of the target (a libadwaita dialog is drawn in its window).
fn autoCloseShot(kind: @TypeOf(@as(AutoClose, undefined).kind), target: P, name: []const u8, shot: P) void {
    if (!selftest_mode) return;
    const ac = gpa.create(AutoClose) catch return;
    ac.* = .{ .kind = kind, .target = target, .name = name, .shot = shot };
    _ = lib.g_timeout_add(if (kind == .adw) 700 else 400, &onAutoClose, ac); // (after its animation)
}

fn onAutoClose(data: P) callconv(.c) c_int {
    const ac: *AutoClose = @ptrCast(@alignCast(data.?));
    defer gpa.destroy(ac);
    const widget: P = ac.shot orelse switch (ac.kind) {
        .modal => @as(*Modal, @ptrCast(@alignCast(ac.target.?))).window,
        .alert => null,
        else => ac.target,
    };
    if (shots_dir) |dir| if (widget) |wd| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&buf, "{s}/{s}-{s}.png", .{ dir, ac.name, if (page_dark) "dark" else "light" }, 0)) |path| {
            if (!writePngSoon(wd, wd, path.ptr)) std.debug.print("pstview selftest: no picture of {s}\n", .{ac.name});
        } else |_| {}
    };
    if (std.mem.eql(u8, ac.name, "ask")) if (selftest_choice) |choice| {
        selftest_choice = null;
        _ = lib.gtk_widget_activate(choice);
        // a choice that did not answer: closed after a moment, and the page reports it
        const again = gpa.create(AutoClose) catch return 0;
        again.* = .{ .kind = ac.kind, .target = ac.target, .name = "ask-unanswered" };
        _ = lib.g_timeout_add(1000, &onAutoClose, again);
        return 0;
    };
    if (std.mem.eql(u8, ac.name, "ask-unanswered")) {
        // still open: the choice did nothing (the page then reports a cancelled question);
        // closed and answered, the question's state has gone with it
        if (!asking) return 0;
    }
    switch (ac.kind) {
        .modal => @as(*Modal, @ptrCast(@alignCast(ac.target.?))).finish(null),
        .about => lib.gtk_window_destroy(ac.target),
        .popover => lib.gtk_popover_popdown(ac.target),
        .alert => lib.g_cancellable_cancel(ac.target),
        .adw => _ = adw.?.adw_dialog_close(ac.target),
    }
    return 0; // once
}

// ================================================================ files dropped on the window

// The web view is a drop target itself and gives its page the files without their paths. The
// window's own target sees the drag first (capture phase) and takes file lists; anything else
// (text dragged into the search field) still reaches the web view.
fn addDropTarget(w: P) void {
    const copy_action = 1;
    const phase_capture = 1;
    const target = lib.gtk_drop_target_new(lib.gdk_file_list_get_type(), copy_action);
    lib.gtk_event_controller_set_propagation_phase(target, phase_capture);
    _ = lib.g_signal_connect_data(target, "drop", &onDrop, null, null, 0);
    lib.gtk_widget_add_controller(w, target);
}

var dropped: std.ArrayList([]const u8) = .empty;

fn clearDropped() void {
    for (dropped.items) |p| gpa.free(p);
    dropped.clearRetainingCapacity();
}

fn openDropped(_: P) callconv(.c) c_int {
    if (dropped.items.len > 0) webapp.openFromShell(dropped.items);
    clearDropped();
    return 0; // once
}

fn onDrop(_: P, value: P, _: f64, _: f64, _: P) callconv(.c) c_int {
    const list = lib.g_value_get_boxed(value) orelse return 0;
    const files = lib.gdk_file_list_get_files(list);
    defer lib.g_slist_free(files);
    clearDropped();
    var node = files;
    while (node) |n| : (node = n.next) {
        const path = lib.g_file_get_path(n.data) orelse continue;
        defer lib.g_free(path);
        const copy = gpa.dupe(u8, std.mem.span(path)) catch continue;
        dropped.append(gpa, copy) catch gpa.free(copy);
    }
    if (dropped.items.len == 0) return 0;
    // opened from the main loop, once the drag has finished
    _ = lib.g_idle_add(&openDropped, null);
    return 1;
}

fn setTitle(title: []const u8) void {
    var buf: [1024]u8 = undefined;
    lib.gtk_window_set_title(window, std.fmt.bufPrintSentinel(&buf, "{s}", .{title[0..@min(title.len, 1000)]}, 0) catch "pstview");
}

// ================================================================ file choosers

const Pick = struct { done: bool = false, result: P = null, finish: *const fn (P, P, P) callconv(.c) P };

fn onPicked(dialog: P, result: P, data: P) callconv(.c) void {
    const pick: *Pick = @ptrCast(@alignCast(data.?));
    pick.result = pick.finish(dialog, result, null); // null when cancelled
    pick.done = true;
}

/// A file dialog titled `title`, starting in the home folder (without one it opens on "Recent",
/// where a folder cannot be confirmed).
fn fileDialog(a: Allocator, title: []const u8) ?P {
    const tz = a.dupeSentinel(u8, title, 0) catch return null;
    const dlg = lib.gtk_file_dialog_new() orelse return null;
    lib.gtk_file_dialog_set_title(dlg, tz.ptr);
    lib.gtk_file_dialog_set_modal(dlg, 1);
    if (lib.g_get_home_dir()) |home| {
        const folder = lib.g_file_new_for_path(home);
        lib.gtk_file_dialog_set_initial_folder(dlg, folder);
        lib.g_object_unref(folder);
    }
    return dlg;
}

/// The path of a GFile (which is released), copied into `a`.
fn takePath(a: Allocator, file: P) ?[]const u8 {
    defer lib.g_object_unref(file);
    const p = lib.g_file_get_path(file) orelse return null; // not a local file
    defer lib.g_free(p);
    return a.dupe(u8, std.mem.span(p)) catch null;
}

fn pickOpen(a: Allocator, title: []const u8, multiple: bool, folders: bool) ?[]const []const u8 {
    const dlg = fileDialog(a, title) orelse return null;
    defer lib.g_object_unref(dlg);
    var out: std.ArrayList([]const u8) = .empty;
    if (multiple and !folders) {
        var pick: Pick = .{ .finish = lib.gtk_file_dialog_open_multiple_finish };
        lib.gtk_file_dialog_open_multiple(dlg, window, null, &onPicked, &pick);
        waitFor(&pick.done);
        const list = pick.result orelse return null;
        defer lib.g_object_unref(list);
        for (0..lib.g_list_model_get_n_items(list)) |i| {
            const file = lib.g_list_model_get_item(list, @intCast(i)) orelse continue;
            out.append(a, takePath(a, file) orelse continue) catch return null;
        }
    } else {
        var pick: Pick = .{ .finish = if (folders) lib.gtk_file_dialog_select_folder_finish else lib.gtk_file_dialog_open_finish };
        (if (folders) lib.gtk_file_dialog_select_folder else lib.gtk_file_dialog_open)(dlg, window, null, &onPicked, &pick);
        waitFor(&pick.done);
        out.append(a, takePath(a, pick.result orelse return null) orelse return null) catch return null;
    }
    return if (out.items.len > 0) out.items else null;
}

/// The save dialog asks before replacing a file itself.
fn pickSave(a: Allocator, title: []const u8, name: []const u8) ?[]const u8 {
    const dlg = fileDialog(a, title) orelse return null;
    defer lib.g_object_unref(dlg);
    const nz = a.dupeSentinel(u8, name, 0) catch return null;
    lib.gtk_file_dialog_set_initial_name(dlg, nz.ptr);
    var pick: Pick = .{ .finish = lib.gtk_file_dialog_save_finish };
    lib.gtk_file_dialog_save(dlg, window, null, &onPicked, &pick);
    waitFor(&pick.done);
    return takePath(a, pick.result orelse return null);
}

fn openUrl(url: []const u8) void {
    var buf: [2048]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{url}, 0) catch return;
    const launcher = lib.gtk_uri_launcher_new(z.ptr) orelse return;
    lib.gtk_uri_launcher_launch(launcher, window, null, null, null);
    lib.g_object_unref(launcher);
}

fn openPath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return;
    const file = lib.g_file_new_for_path(z.ptr) orelse return;
    defer lib.g_object_unref(file);
    const launcher = lib.gtk_file_launcher_new(file) orelse return;
    lib.gtk_file_launcher_launch(launcher, window, null, null, null);
    lib.g_object_unref(launcher);
}

fn quit(code: u8) void {
    webapp.deinit();
    std.process.exit(code);
}

// ================================================================ signals

/// "script-message-received::pstview": a request from the page.
fn onScriptMessage(_: P, value: P, data: P) callconv(.c) void {
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
fn onContextMenu(_: P, _: P, _: P, _: P) callconv(.c) c_int {
    return 1;
}

fn onDestroy(_: P, data: P) callconv(.c) void {
    const id = idOf(data);
    for (wins.items, 0..) |w, i| if (w.id == id) {
        gpa.free(w.menu_shape);
        _ = wins.swapRemove(i);
        break;
    };
    if (id == 0) lib.g_main_loop_quit(main_loop) else webapp.windowClosed(id);
}

// ================================================================ start

pub fn run(gpa_: Allocator, io: Io, start_paths: []const []const u8, selftest: bool) u8 {
    gpa = gpa_;
    selftest_mode = selftest;
    if (std.c.getenv("PSTVIEW_SHOTS")) |d| shots_dir = std.mem.span(d);
    if (loadLibraries()) |missing| {
        std.debug.print("pstview needs GTK 4 and WebKitGTK 6.0 (packages libgtk-4-1 and libwebkitgtk-6.0-4 on Debian / Ubuntu, gtk4 and webkitgtk6.0 on Fedora, gtk4 and webkitgtk-6.0 on Arch).\nNot found: {s}\nThe command-line tool pstx works without them.\n", .{missing});
        return 1;
    }
    // the Wayland app id / X11 window class, which ties the windows to pstview.desktop (in a
    // Flatpak: <id>.desktop), and the name of the icon
    if (std.c.getenv("FLATPAK_ID")) |id| app_id = id;
    lib.g_set_prgname(app_id);
    lib.g_set_application_name("pstview");
    if (lib.gtk_init_check() == 0) {
        std.debug.print("pstview: cannot open a display (no X11 / Wayland session). The command-line tool pstx works without one.\n", .{});
        return 1;
    }
    if (std.c.getenv("PSTVIEW_NATIVE")) |v| native = !std.mem.eql(u8, std.mem.span(v), "0");
    if (native) loadAdwaita();
    if (adw) |ad| {
        ad.adw_init();
        _ = lib.g_signal_connect_data(ad.adw_style_manager_get_default(), "notify::dark", &onSystemDark, null, null, 0);
    }
    provideIcon();
    var shell: webapp.Shell = .{ .eval = &eval, .pickOpen = &pickOpen, .pickSave = &pickSave, .openPath = &openPath, .openUrl = &openUrl, .setTitle = &setTitle, .openWindow = &openWindow, .closeWindow = &closeWindow, .pump = &pump, .setDark = &setDark, .quit = &quit, .snapshot = &snapshot, .setTheme = &setTheme };
    if (native) {
        loadCss();
        // a selectable label (the program name in About) would open with its text selected
        lib.g_object_set(lib.gtk_settings_get_default(), "gtk-label-select-on-focus", @as(c_int, 0), @as(P, null));
        shell.setMenus = &setMenus;
        shell.selftest_closes = true;
        shell.selftest_takes_choice = true;
        shell.popup = &popup;
        shell.setStatus = &setStatus;
        shell.alert = &alert;
        shell.ask = &ask;
        shell.input = &input;
        shell.about = &about;
    }
    webapp.init(gpa, io, shell, start_paths, selftest);

    network_session = lib.webkit_network_session_new_ephemeral();
    main_loop = lib.g_main_loop_new(null, 0);
    if (!createWindow(0, "pstview", 1400, 900)) return 1;
    window = winById(0).?.window;

    lib.g_main_loop_run(main_loop);
    webapp.deinit();
    clearDropped();
    dropped.deinit(gpa);
    wins.deinit(gpa);
    return 0;
}

// ================================================================ icon

/// The windows are given the icon "pstview". Until Help > Install has put it into the icon theme,
/// it comes from the copy built into the program, written to the user's runtime folder (a
/// tmpfs) and added to the theme's search path. (GNOME's dash takes its icon from the installed
/// pstview.desktop only; other desktops take the window's.)
fn provideIcon() void {
    const theme = lib.gtk_icon_theme_get_for_display(lib.gdk_display_get_default()) orelse return;
    if (lib.gtk_icon_theme_has_icon(theme, app_id) != 0) return; // installed, or the Flatpak's
    var buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&buf, "{s}/pstview/icons", .{std.mem.span(lib.g_get_user_runtime_dir())}, 0) catch return;
    if (lib.g_mkdir_with_parents(dir.ptr, 0o700) != 0) return;
    var pbuf: [1100]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}.png", .{ dir, app_id }, 0) catch return;
    const png = @embedFile("icon_png");
    if (lib.g_file_set_contents(path.ptr, png.ptr, png.len, null) == 0) return;
    lib.gtk_icon_theme_add_search_path(theme, dir.ptr);
    if (selftest_mode and lib.gtk_icon_theme_has_icon(theme, app_id) == 0) std.debug.print("pstview selftest: the built-in icon was not found by the icon theme\n", .{});
}

// ================================================================ theme

/// The View menu's choice for the native chrome: "light" / "dark" set GTK's colour scheme for
/// this program, "system" gives the desktop's back. WebKit follows the same setting, so the page
/// (prefers-color-scheme) sees the desktop's scheme again when it follows the system.
fn setTheme(choice: []const u8) void {
    if (adw) |ad| {
        // (libadwaita keeps the scheme itself and warns when GtkSettings' is changed)
        const default = 0;
        const force_light = 1;
        const force_dark = 4;
        const scheme: c_int = if (std.mem.eql(u8, choice, "dark")) force_dark else if (std.mem.eql(u8, choice, "light")) force_light else default;
        following_system = scheme == default;
        ad.adw_style_manager_set_color_scheme(ad.adw_style_manager_get_default(), scheme);
        if (following_system) tellSystemTheme();
        return;
    }
    const settings = lib.gtk_settings_get_default() orelse return;
    const class: P = @as(*const P, @ptrCast(@alignCast(settings))).*; // G_OBJECT_GET_CLASS
    const has_scheme = lib.g_object_class_find_property(class, "gtk-interface-color-scheme") != null; // GTK 4.20+
    const name = if (has_scheme) "gtk-interface-color-scheme" else "gtk-application-prefer-dark-theme";
    if (std.mem.eql(u8, choice, "system")) return lib.gtk_settings_reset_property(settings, name);
    const dark = std.mem.eql(u8, choice, "dark");
    const scheme_dark: c_int = 2;
    const scheme_light: c_int = 3;
    const value: c_int = if (has_scheme) (if (dark) scheme_dark else scheme_light) else @intFromBool(dark);
    lib.g_object_set(settings, name, value, @as(P, null));
}

/// With libadwaita the page learns the system's scheme from its style manager (WebKit's
/// prefers-color-scheme does not always return to it after a forced one): when the page follows
/// the system, and whenever the system changes.
var following_system = true;

fn tellSystemTheme() void {
    const ad = adw orelse return;
    const js = if (ad.adw_style_manager_get_dark(ad.adw_style_manager_get_default()) != 0) "pv.systemTheme(true)" else "pv.systemTheme(false)";
    for (wins.items) |w| eval(w.id, js);
}

fn onSystemDark(_: P, _: P, _: P) callconv(.c) void {
    if (following_system) tellSystemTheme(); // (while forced, "dark" is the forced scheme)
}

/// The few touches of the app's own style on the native chrome: the amber "read-only" mark of the
/// status bar, and the command links of the questions.
fn loadCss() void {
    const provider = lib.gtk_css_provider_new();
    lib.gtk_css_provider_load_from_string(provider,
        \\.pv-status { padding: 3px 12px; border-top: 1px solid alpha(currentColor, 0.12); }
        \\.pv-dot { color: #F5B700; }
        \\.pv-ro { margin-right: 12px; }
        \\.pv-link { padding: 8px 10px; }
        \\.pv-link-arrow { color: #2E7D4F; font-weight: bold; }
        \\.pv-heading { font-weight: bold; font-size: 1.15em; }
    );
    const priority_application = 600;
    lib.gtk_style_context_add_provider_for_display(lib.gdk_display_get_default(), provider, priority_application);
    lib.g_object_unref(provider);
}

// ================================================================ status bar

fn label(text: Z, css: ?Z) P {
    const l = lib.gtk_label_new(text);
    if (css) |c| lib.gtk_widget_add_css_class(l, c);
    return l;
}

fn statusBar(w: *Win) P {
    const horizontal = 0;
    const ellipsize_end = 3;
    const bar = lib.gtk_box_new(horizontal, 6);
    lib.gtk_widget_add_css_class(bar, "pv-status");
    lib.gtk_box_append(bar, label("\u{25CF}", "pv-dot"));
    lib.gtk_box_append(bar, label("Read-only", "pv-ro"));
    w.status = label("", "dim-label");
    lib.gtk_label_set_xalign(w.status, 0);
    lib.gtk_label_set_ellipsize(w.status, ellipsize_end);
    lib.gtk_widget_set_hexpand(w.status, 1);
    lib.gtk_box_append(bar, w.status);
    return bar;
}

fn setStatus(win: u32, text: []const u8) void {
    const w = winById(win) orelse return;
    const z = gpa.dupeSentinel(u8, text, 0) catch return;
    defer gpa.free(z);
    lib.gtk_label_set_text(w.status, z.ptr);
}

// ================================================================ menus

/// GTK's name of a shortcut the page writes as "Mod+O", "Enter" or "Esc". The page handles the
/// keys itself; the menus only show them.
fn accelName(buf: []u8, key: []const u8) ?[:0]const u8 {
    if (key.len == 0) return null;
    if (std.mem.eql(u8, key, "Enter")) return "Return";
    if (std.mem.eql(u8, key, "Esc")) return "Escape";
    if (std.mem.startsWith(u8, key, "Mod+") and key.len == 5)
        return std.fmt.bufPrintSentinel(buf, "<Control>{c}", .{std.ascii.toLower(key[4])}, 0) catch null;
    return null;
}

/// A menu of `items` (separators start a new section) whose entries name actions "<prefix>.<command>".
fn buildMenu(a: Allocator, prefix: []const u8, items: []const ?webapp.MenuItem) P {
    const menu = lib.g_menu_new();
    var section = lib.g_menu_new();
    for (items) |entry| {
        const it = entry orelse {
            lib.g_menu_append_section(menu, null, section);
            lib.g_object_unref(section);
            section = lib.g_menu_new();
            continue;
        };
        const lz = a.dupeSentinel(u8, it.label, 0) catch continue;
        const detailed = std.fmt.allocPrintSentinel(a, "{s}.{s}", .{ prefix, it.action }, 0) catch continue;
        const item = lib.g_menu_item_new(lz.ptr, detailed.ptr);
        var kb: [32]u8 = undefined;
        if (accelName(&kb, it.key)) |accel| lib.g_menu_item_set_attribute_value(item, "accel", lib.g_variant_new_string(accel.ptr));
        lib.g_menu_append_item(section, item);
        lib.g_object_unref(item);
    }
    lib.g_menu_append_section(menu, null, section);
    lib.g_object_unref(section);
    return menu;
}

/// Add an action for every command of `items` to `group` (once per command), or update the one
/// there: enabled, and the check mark of items that have one.
fn updateActions(a: Allocator, group: P, items: []const ?webapp.MenuItem, data: P) void {
    for (items) |entry| {
        const it = entry orelse continue;
        const name = a.dupeSentinel(u8, it.action, 0) catch continue;
        var action = lib.g_action_map_lookup_action(group, name.ptr);
        if (action == null) {
            action = if (it.checked) |c| lib.g_simple_action_new_stateful(name.ptr, null, lib.g_variant_new_boolean(@intFromBool(c))) else lib.g_simple_action_new(name.ptr, null);
            _ = lib.g_signal_connect_data(action, "activate", &onAction, data, null, 0);
            lib.g_action_map_add_action(group, action);
            lib.g_object_unref(action);
        } else if (it.checked) |c| lib.g_simple_action_set_state(action, lib.g_variant_new_boolean(@intFromBool(c)));
        lib.g_simple_action_set_enabled(action, @intFromBool(it.enabled));
    }
}

/// "activate" of a menu action: the page runs the command; the keyboard goes back to the page.
fn onAction(action: P, _: P, data: P) callconv(.c) void {
    const name = lib.g_action_get_name(action) orelse return;
    const w = winById(idOf(data)) orelse return;
    _ = lib.gtk_widget_grab_focus(w.webview);
    webapp.menuAction(w.id, std.mem.span(name));
}

fn setMenus(win: u32, menus: []const webapp.Menu) usize {
    const w = winById(win) orelse return 0;
    updateMenus(w, menus);
    return countActions(w);
}

/// How many actions the window's menus have (the items GTK can show).
fn countActions(w: *Win) usize {
    const names = lib.g_action_group_list_actions(w.actions orelse return 0) orelse return 0;
    defer lib.g_strfreev(names);
    var n: usize = 0;
    while (names[n] != null) n += 1;
    return n;
}

fn updateMenus(w: *Win, menus: []const webapp.Menu) void {
    const win = w.id;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The menus are made again only when their layout changes (an item renamed, added or
    // removed); otherwise only the actions change, and an open menu stays open.
    var shape: std.ArrayList(u8) = .empty;
    for (menus) |m| {
        shape.print(a, "\x1e{s}", .{m.label}) catch return;
        for (m.items) |entry| if (entry) |it| shape.print(a, "\x1f{s}\x1d{s}\x1d{s}", .{ it.label, it.action, it.key }) catch return else shape.append(a, '|') catch return;
    }
    const data: P = @ptrFromInt(win);
    if (w.actions == null or !std.mem.eql(u8, shape.items, w.menu_shape)) {
        const bar = lib.g_menu_new();
        for (menus) |m| {
            const sub = buildMenu(a, "m", m.items);
            const lz = a.dupeSentinel(u8, m.label, 0) catch return;
            lib.g_menu_append_submenu(bar, lz.ptr, sub);
            lib.g_object_unref(sub);
        }
        const group = lib.g_simple_action_group_new();
        for (menus) |m| updateActions(a, group, m.items, data);
        lib.gtk_widget_insert_action_group(w.window, "m", group);
        lib.g_object_unref(group);
        w.actions = group; // (held by the window)
        if (adw != null) {
            lib.gtk_menu_button_set_menu_model(w.menubar, bar);
            fitToPage(lib.gtk_menu_button_get_popover(w.menubar));
        } else lib.gtk_popover_menu_bar_set_menu_model(w.menubar, bar);
        lib.g_object_unref(bar);
        gpa.free(w.menu_shape);
        w.menu_shape = gpa.dupe(u8, shape.items) catch &.{};
        return;
    }
    for (menus) |m| updateActions(a, w.actions, m.items, data);
}

/// The main menu shows its submenus as pages of one popover, which GTK makes as wide as the
/// widest page: let it take the size of the page shown instead, changing smoothly.
fn fitToPage(widget: P) void {
    var child = lib.gtk_widget_get_first_child(widget);
    while (child) |c| : (child = lib.gtk_widget_get_next_sibling(c)) {
        if (lib.g_type_check_instance_is_a(c, lib.gtk_stack_get_type()) != 0) {
            lib.gtk_stack_set_hhomogeneous(c, 0);
            lib.gtk_stack_set_interpolate_size(c, 1);
            return;
        }
        fitToPage(c);
    }
}

fn unparentLater(popover: P) callconv(.c) c_int {
    lib.gtk_widget_unparent(popover);
    return 0; // once
}

fn onPopoverClosed(popover: P, _: P) callconv(.c) void {
    // after the chosen item's action has run
    _ = lib.g_idle_add(&unparentLater, popover);
}

fn popup(win: u32, x: f64, y: f64, items: []const ?webapp.MenuItem) void {
    const w = winById(win) orelse return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const group = lib.g_simple_action_group_new();
    updateActions(a, group, items, @ptrFromInt(win));
    lib.gtk_widget_insert_action_group(w.window, "c", group);
    lib.g_object_unref(group);
    const menu = buildMenu(a, "c", items);
    const popover = lib.gtk_popover_menu_new_from_model(menu);
    lib.g_object_unref(menu);
    lib.gtk_widget_set_parent(popover, w.webview);
    const align_start = 1;
    lib.gtk_widget_set_halign(popover, align_start);
    lib.gtk_popover_set_has_arrow(popover, 0);
    lib.gtk_popover_set_pointing_to(popover, &.{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = 1, .h = 1 });
    _ = lib.g_signal_connect_data(popover, "closed", &onPopoverClosed, null, null, 0);
    lib.gtk_popover_popup(popover);
    autoClose(.popover, popover, "popup");
}

// ================================================================ dialogs

fn parentOf(win: u32) P {
    return if (winById(win)) |w| w.window else window;
}

const Alert = struct { done: bool = false };

fn onAlertDone(dialog: P, result: P, data: P) callconv(.c) void {
    const st: *Alert = @ptrCast(@alignCast(data.?));
    _ = lib.gtk_alert_dialog_choose_finish(dialog, result, null);
    st.done = true;
}

fn alert(a: Allocator, win: u32, title: []const u8, text: []const u8) void {
    if (adw != null) return adwAlert(a, win, title, text);
    const tz = a.dupeSentinel(u8, title, 0) catch return;
    const dz = a.dupeSentinel(u8, text, 0) catch return;
    const dlg = lib.gtk_alert_dialog_new("%s", tz.ptr) orelse return;
    defer lib.g_object_unref(dlg);
    lib.gtk_alert_dialog_set_detail(dlg, dz.ptr);
    const buttons = [_:null]?Z{"OK"};
    lib.gtk_alert_dialog_set_buttons(dlg, &buttons);
    var st: Alert = .{};
    const cancel = lib.g_cancellable_new();
    defer lib.g_object_unref(cancel);
    lib.gtk_alert_dialog_choose(dlg, parentOf(win), cancel, &onAlertDone, &st);
    autoClose(.alert, cancel, "alert");
    waitFor(&st.done);
}

/// What a modal dialog window of ours has been answered with. Its buttons carry their index.
const Modal = struct {
    window: P = null,
    done: bool = false,
    /// index of the button pressed; null: cancelled (Cancel, Escape, the close button)
    choice: ?usize = null,
    check: P = null,
    verified: bool = false,
    text_view: P = null,
    text: ?[]const u8 = null,
    a: Allocator,

    fn finish(m: *Modal, choice: ?usize) void {
        if (m.done) return;
        m.choice = choice;
        if (m.check) |c| m.verified = lib.gtk_check_button_get_active(c) != 0;
        if (choice != null) if (m.text_view) |tv| {
            var raw: ?[*:0]u8 = null;
            lib.g_object_get(lib.gtk_text_view_get_buffer(tv), "text", &raw, @as(P, null));
            if (raw) |r| {
                m.text = m.a.dupe(u8, std.mem.span(r)) catch null;
                lib.g_free(r);
            }
        };
        m.done = true;
        lib.gtk_window_destroy(m.window);
    }
};

/// What a button of a modal dialog answers: its index (null: Cancel).
const ButtonRef = struct { modal: *Modal, index: ?usize };

fn onModalButton(_: P, data: P) callconv(.c) void {
    const ref: *ButtonRef = @ptrCast(@alignCast(data.?));
    ref.modal.finish(ref.index);
}

fn onModalDestroy(_: P, data: P) callconv(.c) void {
    const m: *Modal = @ptrCast(@alignCast(data.?));
    m.done = true; // closed by the window manager: cancelled
}

fn onModalKey(_: P, keyval: c_uint, _: c_uint, _: c_uint, data: P) callconv(.c) c_int {
    const escape = 0xff1b;
    if (keyval != escape) return 0;
    const m: *Modal = @ptrCast(@alignCast(data.?));
    m.finish(null);
    return 1;
}

/// A modal dialog window over window `win`, its content in a vertical box (returned).
fn modalWindow(m: *Modal, win: u32, title: Z) P {
    const dlg = lib.gtk_window_new();
    m.window = dlg;
    lib.gtk_window_set_title(dlg, title);
    lib.gtk_window_set_transient_for(dlg, parentOf(win));
    lib.gtk_window_set_modal(dlg, 1);
    lib.gtk_window_set_resizable(dlg, 0);
    lib.gtk_window_set_icon_name(dlg, app_id);
    _ = lib.g_signal_connect_data(dlg, "destroy", &onModalDestroy, m, null, 0);
    const keys = lib.gtk_event_controller_key_new();
    _ = lib.g_signal_connect_data(keys, "key-pressed", &onModalKey, m, null, 0);
    lib.gtk_widget_add_controller(dlg, keys);
    const box = lib.gtk_box_new(1, 10);
    lib.gtk_widget_set_margin_top(box, 20);
    lib.gtk_widget_set_margin_bottom(box, 16);
    lib.gtk_widget_set_margin_start(box, 22);
    lib.gtk_widget_set_margin_end(box, 22);
    lib.gtk_window_set_child(dlg, box);
    return box;
}

fn wrapped(text: Z, css: ?Z) P {
    const l = label(text, css);
    lib.gtk_label_set_wrap(l, 1);
    lib.gtk_label_set_max_width_chars(l, 64);
    lib.gtk_label_set_xalign(l, 0);
    return l;
}

fn modalButton(a: Allocator, m: *Modal, child_or_label: union(enum) { label: Z, child: P }, index: ?usize) P {
    const b = switch (child_or_label) {
        .label => |l| lib.gtk_button_new_with_label(l),
        .child => |c| blk: {
            const b = lib.gtk_button_new();
            lib.gtk_button_set_child(b, c);
            break :blk b;
        },
    };
    const ref = a.create(ButtonRef) catch return b;
    ref.* = .{ .modal = m, .index = index };
    _ = lib.g_signal_connect_data(b, "clicked", &onModalButton, ref, null, 0);
    return b;
}

/// The question of a Windows task dialog: command links (label and note), an optional check box
/// and Cancel.
fn ask(a: Allocator, q: webapp.Ask) ?webapp.Answer {
    if (adw != null) return adwAsk(a, q);
    var m: Modal = .{ .a = a };
    const tz = a.dupeSentinel(u8, q.title, 0) catch return null;
    const box = modalWindow(&m, q.win, tz.ptr);
    lib.gtk_box_append(box, wrapped(tz.ptr, "pv-heading"));
    if (q.text.len > 0) lib.gtk_box_append(box, wrapped(a.dupeSentinel(u8, q.text, 0) catch return null, null));
    const links = lib.gtk_box_new(1, 2);
    lib.gtk_widget_set_margin_top(links, 8);
    var first: P = null;
    for (q.choices, 0..) |c, i| {
        const row = lib.gtk_box_new(0, 10);
        lib.gtk_box_append(row, label("\u{2192}", "pv-link-arrow"));
        const text = lib.gtk_box_new(1, 2);
        lib.gtk_box_append(text, wrapped(a.dupeSentinel(u8, c.label, 0) catch return null, "pv-heading"));
        if (c.note.len > 0) lib.gtk_box_append(text, wrapped(a.dupeSentinel(u8, c.note, 0) catch return null, "dim-label"));
        lib.gtk_box_append(row, text);
        const b = modalButton(a, &m, .{ .child = row }, i);
        lib.gtk_widget_add_css_class(b, "flat");
        lib.gtk_widget_add_css_class(b, "pv-link");
        lib.gtk_box_append(links, b);
        if (first == null) first = b;
    }
    lib.gtk_box_append(box, links);
    const foot = lib.gtk_box_new(0, 8);
    lib.gtk_widget_set_margin_top(foot, 10);
    if (q.verification.len > 0) {
        m.check = lib.gtk_check_button_new_with_label(a.dupeSentinel(u8, q.verification, 0) catch return null);
        lib.gtk_box_append(foot, m.check);
    }
    const spacer = lib.gtk_box_new(0, 0);
    lib.gtk_widget_set_hexpand(spacer, 1);
    lib.gtk_box_append(foot, spacer);
    lib.gtk_box_append(foot, modalButton(a, &m, .{ .label = "Cancel" }, null));
    lib.gtk_box_append(box, foot);
    lib.gtk_window_present(m.window);
    if (first) |b| _ = lib.gtk_widget_grab_focus(b);
    selftest_choice = first;
    autoClose(.modal, &m, "ask");
    asking = true;
    waitFor(&m.done);
    asking = false;
    return .{ .choice = m.choice, .verified = m.verified };
}

/// A text to paste or type (the headers of a message), with `ok` and Cancel.
fn input(a: Allocator, win: u32, title: []const u8, prompt: []const u8, ok: []const u8) ?[]const u8 {
    if (adw != null) return adwInput(a, win, title, prompt, ok);
    var m: Modal = .{ .a = a };
    const tz = a.dupeSentinel(u8, title, 0) catch return null;
    const box = modalWindow(&m, win, tz.ptr);
    lib.gtk_box_append(box, wrapped(a.dupeSentinel(u8, prompt, 0) catch return null, null));
    const scroll = lib.gtk_scrolled_window_new();
    lib.gtk_scrolled_window_set_min_content_width(scroll, 600);
    lib.gtk_scrolled_window_set_min_content_height(scroll, 320);
    lib.gtk_widget_add_css_class(scroll, "frame");
    m.text_view = lib.gtk_text_view_new();
    const wrap_word_char = 3;
    lib.gtk_text_view_set_monospace(m.text_view, 1);
    lib.gtk_text_view_set_wrap_mode(m.text_view, wrap_word_char);
    lib.gtk_scrolled_window_set_child(scroll, m.text_view);
    lib.gtk_box_append(box, scroll);
    const foot = lib.gtk_box_new(0, 8);
    lib.gtk_widget_set_margin_top(foot, 8);
    lib.gtk_widget_set_halign(foot, 2); // end
    lib.gtk_box_append(foot, modalButton(a, &m, .{ .label = "Cancel" }, null));
    const okb = modalButton(a, &m, .{ .label = a.dupeSentinel(u8, if (ok.len > 0) ok else "OK", 0) catch return null }, 0);
    lib.gtk_widget_add_css_class(okb, "suggested-action");
    lib.gtk_box_append(foot, okb);
    lib.gtk_box_append(box, foot);
    lib.gtk_window_present(m.window);
    _ = lib.gtk_widget_grab_focus(m.text_view);
    autoClose(.modal, &m, "input");
    waitFor(&m.done);
    if (m.choice == null) return null;
    return m.text orelse "";
}

fn about(a: Allocator, win: u32, info: webapp.About) void {
    if (adw != null) return adwAbout(a, win, info);
    const dlg = lib.gtk_about_dialog_new();
    lib.gtk_about_dialog_set_program_name(dlg, "pstview");
    lib.gtk_about_dialog_set_version(dlg, a.dupeSentinel(u8, info.version, 0) catch return);
    lib.gtk_about_dialog_set_comments(dlg, a.dupeSentinel(u8, info.comments, 0) catch return);
    const url = a.dupeSentinel(u8, info.url, 0) catch return;
    lib.gtk_about_dialog_set_website(dlg, url.ptr);
    lib.gtk_about_dialog_set_website_label(dlg, if (std.mem.startsWith(u8, url, "https://")) url[8..].ptr else url.ptr);
    // the icon built into the program (the icon theme has it only once pstview is installed)
    const png = @embedFile("icon_png");
    const bytes = lib.g_bytes_new_static(png.ptr, png.len);
    defer lib.g_bytes_unref(bytes);
    if (lib.gdk_texture_new_from_bytes(bytes, null)) |logo| {
        lib.gtk_about_dialog_set_logo(dlg, logo);
        lib.g_object_unref(logo);
    }
    lib.gtk_window_set_transient_for(dlg, parentOf(win));
    lib.gtk_window_set_modal(dlg, 1);
    lib.gtk_window_present(dlg);
    autoClose(.about, dlg, "about");
}

// ================================================================ dialogs (libadwaita)

/// An AdwAlertDialog being answered; `response` is its response id once it has closed.
const AdwAnswer = struct {
    done: bool = false,
    response: []const u8 = "",
    /// the row chosen in a question (adwAsk), its check box and text field (adwInput)
    choice: ?usize = null,
    check: P = null,
    verified: bool = false,
    dialog: P = null,
};

fn onAdwChosen(dialog: P, result: P, data: P) callconv(.c) void {
    const st: *AdwAnswer = @ptrCast(@alignCast(data.?));
    if (adw.?.adw_alert_dialog_choose_finish(dialog, result)) |r| st.response = std.mem.span(r);
    st.done = true;
}

/// Show `dlg` over window `win` and wait for its answer (the self-test closes it after a picture).
fn adwRun(dlg: P, win: u32, st: *AdwAnswer, name: []const u8) void {
    st.dialog = dlg;
    const parent = parentOf(win);
    adw.?.adw_alert_dialog_choose(dlg, parent, null, &onAdwChosen, st);
    autoCloseShot(.adw, dlg, name, parent);
    waitFor(&st.done);
}

fn adwAlert(a: Allocator, win: u32, title: []const u8, text: []const u8) void {
    const ad = adw.?;
    const dlg = ad.adw_alert_dialog_new(a.dupeSentinel(u8, title, 0) catch return, a.dupeSentinel(u8, text, 0) catch return);
    ad.adw_alert_dialog_add_response(dlg, "ok", "OK");
    ad.adw_alert_dialog_set_default_response(dlg, "ok");
    ad.adw_alert_dialog_set_close_response(dlg, "ok");
    var st: AdwAnswer = .{};
    adwRun(dlg, win, &st, "alert");
}

fn onAdwCheck(check: P, data: P) callconv(.c) void {
    const st: *AdwAnswer = @ptrCast(@alignCast(data.?));
    st.verified = lib.gtk_check_button_get_active(check) != 0;
}

fn onAdwRow(_: P, row: P, data: P) callconv(.c) void {
    const st: *AdwAnswer = @ptrCast(@alignCast(data.?));
    st.choice = @intCast(@max(lib.gtk_list_box_row_get_index(row), 0));
    _ = adw.?.adw_dialog_close(st.dialog); // answers with the close response; the row is kept
}

/// The question with command links: a boxed list of rows (label, note), the check box, Cancel.
fn adwAsk(a: Allocator, q: webapp.Ask) ?webapp.Answer {
    const ad = adw.?;
    const dlg = ad.adw_alert_dialog_new(a.dupeSentinel(u8, q.title, 0) catch return null, if (q.text.len > 0) (a.dupeSentinel(u8, q.text, 0) catch return null) else null);
    ad.adw_alert_dialog_add_response(dlg, "cancel", "Cancel");
    ad.adw_alert_dialog_set_close_response(dlg, "cancel");
    ad.adw_alert_dialog_set_default_response(dlg, null);
    var st: AdwAnswer = .{ .dialog = dlg };
    var first_row: P = null;
    const box = lib.gtk_box_new(1, 12);
    const list = lib.gtk_list_box_new();
    const selection_none = 0;
    lib.gtk_list_box_set_selection_mode(list, selection_none);
    lib.gtk_widget_add_css_class(list, "boxed-list");
    for (q.choices) |c| {
        const row = ad.adw_action_row_new();
        ad.adw_preferences_row_set_title(row, a.dupeSentinel(u8, c.label, 0) catch return null);
        if (c.note.len > 0) ad.adw_action_row_set_subtitle(row, a.dupeSentinel(u8, c.note, 0) catch return null);
        ad.adw_action_row_add_suffix(row, lib.gtk_image_new_from_icon_name("go-next-symbolic"));
        lib.gtk_list_box_row_set_activatable(row, 1); // (an AdwActionRow is not, by itself)
        lib.gtk_list_box_append(list, row);
        if (first_row == null) first_row = row;
    }
    _ = lib.g_signal_connect_data(list, "row-activated", &onAdwRow, &st, null, 0);
    lib.gtk_box_append(box, list);
    if (q.verification.len > 0) {
        st.check = lib.gtk_check_button_new_with_label(a.dupeSentinel(u8, q.verification, 0) catch return null);
        // followed as it changes: the dialog's widgets are gone once it has answered
        _ = lib.g_signal_connect_data(st.check, "toggled", &onAdwCheck, &st, null, 0);
        lib.gtk_box_append(box, st.check);
    }
    ad.adw_alert_dialog_set_extra_child(dlg, box);
    selftest_choice = first_row;
    asking = true;
    adwRun(dlg, q.win, &st, "ask");
    asking = false;
    return .{ .choice = st.choice, .verified = st.verified };
}

fn adwInput(a: Allocator, win: u32, title: []const u8, prompt: []const u8, ok: []const u8) ?[]const u8 {
    const ad = adw.?;
    const dlg = ad.adw_alert_dialog_new(a.dupeSentinel(u8, title, 0) catch return null, a.dupeSentinel(u8, prompt, 0) catch return null);
    ad.adw_alert_dialog_add_response(dlg, "cancel", "Cancel");
    ad.adw_alert_dialog_add_response(dlg, "ok", a.dupeSentinel(u8, if (ok.len > 0) ok else "OK", 0) catch return null);
    const suggested = 1;
    ad.adw_alert_dialog_set_response_appearance(dlg, "ok", suggested);
    ad.adw_alert_dialog_set_close_response(dlg, "cancel");
    ad.adw_alert_dialog_set_prefer_wide_layout(dlg, 1);
    const scroll = lib.gtk_scrolled_window_new();
    lib.gtk_scrolled_window_set_min_content_width(scroll, 520);
    lib.gtk_scrolled_window_set_min_content_height(scroll, 280);
    lib.gtk_widget_add_css_class(scroll, "card");
    const text_view = lib.gtk_text_view_new();
    const wrap_word_char = 3;
    lib.gtk_text_view_set_monospace(text_view, 1);
    lib.gtk_text_view_set_wrap_mode(text_view, wrap_word_char);
    lib.gtk_widget_add_css_class(text_view, "inline");
    lib.gtk_scrolled_window_set_child(scroll, text_view);
    ad.adw_alert_dialog_set_extra_child(dlg, scroll);
    var st: AdwAnswer = .{};
    adwRun(dlg, win, &st, "input");
    if (!std.mem.eql(u8, st.response, "ok")) return null;
    var raw: ?[*:0]u8 = null;
    lib.g_object_get(lib.gtk_text_view_get_buffer(text_view), "text", &raw, @as(P, null));
    const r = raw orelse return "";
    defer lib.g_free(r);
    return a.dupe(u8, std.mem.span(r)) catch null;
}

fn adwAbout(a: Allocator, win: u32, info: webapp.About) void {
    const ad = adw.?;
    const dlg = ad.adw_about_dialog_new();
    ad.adw_about_dialog_set_application_name(dlg, "pstview");
    ad.adw_about_dialog_set_application_icon(dlg, app_id); // (provideIcon: also before installing)
    ad.adw_about_dialog_set_version(dlg, a.dupeSentinel(u8, info.version, 0) catch return);
    ad.adw_about_dialog_set_comments(dlg, a.dupeSentinel(u8, info.comments, 0) catch return);
    ad.adw_about_dialog_set_website(dlg, a.dupeSentinel(u8, info.url, 0) catch return);
    const parent = parentOf(win);
    ad.adw_dialog_present(dlg, parent);
    autoCloseShot(.adw, dlg, "about", parent);
}
