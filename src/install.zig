//! Per-user installation of the portable exe.
//!
//! `install` copies pstview.exe (and pstx.exe when it sits next to it) to
//! %LOCALAPPDATA%\Programs\pstview, adds a Start menu shortcut, registers "Open with" handlers for
//! .pst / .ost / .mbox / .mbx, lists pstview under Settings > Default apps and adds an uninstall
//! entry to Settings > Apps. Everything lives under HKCU, so no administrator rights are needed.
//! Nothing is written to the PC until the user asks for it; portable use writes nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const w = @import("win.zig");

pub const extensions = [_][]const u8{ ".pst", ".ost", ".mbox", ".mbx" };
pub const prog_id = "pstview.mailbox";
const app_key = "Software\\pstview";
const uninstall_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\pstview";
const classes = "Software\\Classes";
const publisher = "publicarray";
const homepage = "https://github.com/publicarray/pstview";

/// Where an installation goes. `defaultLayout` gives the real locations; tests point everything at
/// a scratch directory and a registry sub-key.
pub const Layout = struct {
    /// Install directory (pstview.exe, pstx.exe).
    dir: []const u8,
    /// Start menu shortcut (.lnk); empty = none.
    shortcut: []const u8,
    /// Where uninstall moves the exes it cannot delete because they are running (a folder under
    /// %TEMP%, on the same drive as `dir` so the move is a rename); emptied by later installs and
    /// uninstalls. Empty = none.
    trash: []const u8 = "",
    /// Prefix for every HKCU key ("" = the real locations).
    reg_root: []const u8 = "",
    /// Tell Explorer that file associations changed.
    notify_shell: bool = true,
};

pub fn defaultLayout(a: Allocator) !Layout {
    const programs = try knownFolder(a, &w.FOLDERID_UserProgramFiles);
    const start = try knownFolder(a, &w.FOLDERID_Programs);
    var buf: [600]u16 = undefined;
    const n = w.GetTempPathW(buf.len, &buf);
    const temp = if (n == 0 or n >= buf.len) "" else try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
    return .{
        .dir = try std.fs.path.join(a, &.{ programs, "pstview" }),
        .shortcut = try std.fs.path.join(a, &.{ start, "pstview.lnk" }),
        .trash = if (temp.len == 0) "" else try std.fs.path.join(a, &.{ temp, "pstview", "uninstalled" }),
    };
}

/// Full path of the running exe.
pub fn selfPath(a: Allocator) ![]u8 {
    var buf: [32768]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.ModulePath;
    return std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
}

pub fn installedExe(a: Allocator, l: Layout) ![]u8 {
    return std.fs.path.join(a, &.{ l.dir, "pstview.exe" });
}

/// Installed for this user: the uninstall entry exists and its exe is present.
pub fn isInstalled(a: Allocator, l: Layout) bool {
    const loc = getStr(a, w.HKEY_CURRENT_USER, key(a, l, uninstall_key) catch return false, "InstallLocation") orelse return false;
    const exe = std.fs.path.join(a, &.{ loc, "pstview.exe" }) catch return false;
    return fileExists(a, exe);
}

/// The running exe is the installed copy.
pub fn runningInstalled(a: Allocator, l: Layout) bool {
    const self = selfPath(a) catch return false;
    const inst = installedExe(a, l) catch return false;
    return std.ascii.eqlIgnoreCase(self, inst);
}

/// The user chose "Don't ask again" on the first-run install offer.
pub fn promptDismissed(a: Allocator) bool {
    return getDword(a, app_key, "NoInstallPrompt") == 1;
}

pub fn dismissPrompt(a: Allocator) void {
    setDword(a, app_key, "NoInstallPrompt", 1) catch {};
}

pub const InstallError = error{ CopyFailed, InstallDir } || RegistryError || Allocator.Error;

/// Install (or update) the running exe for the current user. `version` goes to Settings > Apps.
pub fn install(a: Allocator, io: std.Io, l: Layout, version: []const u8) InstallError!void {
    const self = selfPath(a) catch return error.CopyFailed;
    const exe = try installedExe(a, l);
    emptyTrash(a, l);
    try makeDir(a, l.dir);
    var size: u64 = 0;
    if (!std.ascii.eqlIgnoreCase(self, exe)) try copy(a, self, exe);
    size += fileSize(io, exe);
    // pstx.exe travels with pstview.exe in the release zip
    const pstx_src = try std.fs.path.join(a, &.{ std.fs.path.dirname(self) orelse ".", "pstx.exe" });
    const pstx_dst = try std.fs.path.join(a, &.{ l.dir, "pstx.exe" });
    if (fileExists(a, pstx_src) and !std.ascii.eqlIgnoreCase(pstx_src, pstx_dst)) try copy(a, pstx_src, pstx_dst);
    if (fileExists(a, pstx_dst)) size += fileSize(io, pstx_dst);

    if (l.shortcut.len > 0) createShortcut(a, l.shortcut, exe, "pstview - read-only PST / OST / MBOX viewer") catch {};

    const open_cmd = try std.fmt.allocPrint(a, "\"{s}\" \"%1\"", .{exe});
    const icon = try std.fmt.allocPrint(a, "{s},0", .{exe});

    // ProgID shared by all mailbox types
    const pid = try std.fmt.allocPrint(a, "{s}\\{s}", .{ classes, prog_id });
    try setStr(a, try key(a, l, pid), null, "Mailbox file (pstview, read-only)");
    try setStr(a, try key(a, l, pid), "FriendlyTypeName", "Mailbox file (pstview, read-only)");
    try setStr(a, try key(a, l, try cat(a, pid, "\\DefaultIcon")), null, icon);
    try setStr(a, try key(a, l, try cat(a, pid, "\\shell\\open\\command")), null, open_cmd);

    // the exe itself, for "Open with"
    const app = classes ++ "\\Applications\\pstview.exe";
    try setStr(a, try key(a, l, app), "FriendlyAppName", "pstview");
    try setStr(a, try key(a, l, app ++ "\\shell\\open\\command"), null, open_cmd);
    for (extensions) |ext| try setNone(a, try key(a, l, app ++ "\\SupportedTypes"), ext);

    // extensions: always an "Open with" entry; the default only where no other app has one
    for (extensions) |ext| {
        const ek = try std.fmt.allocPrint(a, "{s}\\{s}", .{ classes, ext });
        try setNone(a, try key(a, l, try cat(a, ek, "\\OpenWithProgids")), prog_id);
        const existing = getStr(a, w.HKEY_CLASSES_ROOT, ext, null);
        if (existing == null or existing.?.len == 0) {
            try setStr(a, try key(a, l, ek), null, prog_id);
            try setDword(a, try key(a, l, app_key ++ "\\OwnedExtensions"), ext, 1);
        }
    }

    // Settings > Default apps
    const caps = app_key ++ "\\Capabilities";
    try setStr(a, try key(a, l, caps), "ApplicationName", "pstview");
    try setStr(a, try key(a, l, caps), "ApplicationDescription", "Read-only viewer for Outlook PST / OST and MBOX mailboxes, with header analysis and recovery of deleted items.");
    for (extensions) |ext| try setStr(a, try key(a, l, caps ++ "\\FileAssociations"), ext, prog_id);
    try setStr(a, try key(a, l, "Software\\RegisteredApplications"), "pstview", try key(a, l, caps));

    // Settings > Apps
    const uk = try key(a, l, uninstall_key);
    try setStr(a, uk, "DisplayName", "pstview");
    try setStr(a, uk, "DisplayVersion", version);
    try setStr(a, uk, "Publisher", publisher);
    try setStr(a, uk, "DisplayIcon", icon);
    try setStr(a, uk, "InstallLocation", l.dir);
    try setStr(a, uk, "UninstallString", try std.fmt.allocPrint(a, "\"{s}\" --uninstall", .{exe}));
    try setStr(a, uk, "URLInfoAbout", homepage);
    try setDword(a, uk, "NoModify", 1);
    try setDword(a, uk, "NoRepair", 1);
    try setDword(a, uk, "EstimatedSize", @intCast(@min(size / 1024, std.math.maxInt(u32))));

    if (l.notify_shell) w.SHChangeNotify(w.SHCNE_ASSOCCHANGED, 0, null, null);
}

pub const Removal = enum {
    /// Files removed.
    removed,
    /// The running exe is the installed copy: it was moved out of the install folder (to
    /// `Layout.trash`) and pstview should now exit.
    after_exit,
};

/// Remove everything `install` created. Only the files it copied are deleted, and the folder only
/// when it is then empty.
pub fn uninstall(a: Allocator, l: Layout) !Removal {
    // file handlers: remove only our own values, then keys that became empty
    for (extensions) |ext| {
        const ek = try std.fmt.allocPrint(a, "{s}\\{s}", .{ classes, ext });
        const owp = try key(a, l, try cat(a, ek, "\\OpenWithProgids"));
        deleteValue(a, owp, prog_id);
        deleteIfEmpty(a, owp);
        if (getDword(a, try key(a, l, app_key ++ "\\OwnedExtensions"), ext) == 1) {
            const cur = getStr(a, w.HKEY_CURRENT_USER, try key(a, l, ek), null);
            if (cur != null and std.mem.eql(u8, cur.?, prog_id)) deleteValue(a, try key(a, l, ek), null);
        }
        deleteIfEmpty(a, try key(a, l, ek));
    }
    deleteTree(a, try key(a, l, try std.fmt.allocPrint(a, "{s}\\{s}", .{ classes, prog_id })));
    deleteTree(a, try key(a, l, classes ++ "\\Applications\\pstview.exe"));
    deleteValue(a, try key(a, l, "Software\\RegisteredApplications"), "pstview");
    deleteTree(a, try key(a, l, app_key));
    deleteTree(a, try key(a, l, uninstall_key));
    if (l.notify_shell) w.SHChangeNotify(w.SHCNE_ASSOCCHANGED, 0, null, null);

    if (l.shortcut.len > 0) _ = w.DeleteFileW(try wz(a, l.shortcut));

    const running = runningInstalled(a, l);
    emptyTrash(a, l);
    try removeExe(a, l, "pstview.exe");
    try removeExe(a, l, "pstx.exe");
    _ = w.RemoveDirectoryW(try wz(a, l.dir)); // fails harmlessly if anything else is in it
    return if (running) .after_exit else .removed;
}

/// Delete `name` from the install folder. A running exe cannot be deleted, but it can be renamed:
/// it is moved to `Layout.trash` instead (what a later install or uninstall deletes, as does the
/// cleanup of %TEMP%). No other process is started for this.
fn removeExe(a: Allocator, l: Layout, name: []const u8) Allocator.Error!void {
    const path = try wz(a, try std.fs.path.join(a, &.{ l.dir, name }));
    if (w.DeleteFileW(path) != 0 or l.trash.len == 0) return;
    if (w.GetFileAttributesW(path) == w.INVALID_FILE_ATTRIBUTES) return; // was not there
    try makeDirs(a, l.trash);
    const to = try std.fs.path.join(a, &.{ l.trash, name });
    if (w.MoveFileExW(path, try wz(a, to), w.MOVEFILE_REPLACE_EXISTING) != 0) return;
    // an earlier uninstalled copy of the same name is still running: a name of its own
    const unique = try std.fmt.allocPrint(a, "{s}.{d}", .{ to, w.GetCurrentProcessId() });
    _ = w.MoveFileExW(path, try wz(a, unique), w.MOVEFILE_REPLACE_EXISTING);
}

/// Delete what earlier uninstalls moved to `Layout.trash` (copies that still run stay).
fn emptyTrash(a: Allocator, l: Layout) void {
    if (l.trash.len == 0) return;
    const pattern = wz(a, std.fs.path.join(a, &.{ l.trash, "*" }) catch return) catch return;
    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileW(pattern, &fd);
    if (h == w.INVALID_HANDLE_VALUE) return;
    defer _ = w.FindClose(h);
    while (true) {
        const n = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
        if (fd.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY == 0) {
            const file = std.unicode.wtf16LeToWtf8Alloc(a, fd.cFileName[0..n]) catch break;
            const p = std.fs.path.join(a, &.{ l.trash, file }) catch break;
            _ = w.DeleteFileW(wz(a, p) catch break);
        }
        if (w.FindNextFileW(h, &fd) == 0) break;
    }
    _ = w.RemoveDirectoryW(wz(a, l.trash) catch return);
}

// ================================================================ helpers

pub const RegistryError = error{Registry};

fn wz(a: Allocator, s: []const u8) Allocator.Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return std.unicode.wtf8ToWtf16LeAllocZ(a, "?") catch error.OutOfMemory,
    };
}

fn cat(a: Allocator, x: []const u8, y: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(a, u8, &.{ x, y });
}

/// HKCU path of `sub` in this layout.
fn key(a: Allocator, l: Layout, sub: []const u8) Allocator.Error![]const u8 {
    return if (l.reg_root.len == 0) sub else cat(a, l.reg_root, sub);
}

fn knownFolder(a: Allocator, id: *const w.GUID) ![]u8 {
    var p: ?[*:0]u16 = null;
    if (w.SHGetKnownFolderPath(id, w.KF_FLAG_CREATE, null, &p) < 0 or p == null) return error.KnownFolder;
    defer w.CoTaskMemFree(p);
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(p.?));
}

fn fileExists(a: Allocator, path: []const u8) bool {
    const attr = w.GetFileAttributesW(wz(a, path) catch return false);
    return attr != w.INVALID_FILE_ATTRIBUTES and attr & w.FILE_ATTRIBUTE_DIRECTORY == 0;
}

fn fileSize(io: std.Io, path: []const u8) u64 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return 0;
    defer f.close(io);
    const st = f.stat(io) catch return 0;
    return st.size;
}

fn makeDir(a: Allocator, path: []const u8) InstallError!void {
    if (w.CreateDirectoryW(try wz(a, path), null) == 0 and w.GetLastError() != w.ERROR_ALREADY_EXISTS) return error.InstallDir;
}

/// `path` and the folders above it that are missing.
fn makeDirs(a: Allocator, path: []const u8) Allocator.Error!void {
    const p = try wz(a, path);
    if (w.CreateDirectoryW(p, null) != 0 or w.GetLastError() == w.ERROR_ALREADY_EXISTS) return;
    if (std.fs.path.dirname(path)) |parent| if (parent.len < path.len) {
        try makeDirs(a, parent);
        _ = w.CreateDirectoryW(p, null);
    };
}

fn copy(a: Allocator, src: []const u8, dst: []const u8) InstallError!void {
    if (w.CopyFileW(try wz(a, src), try wz(a, dst), 0) == 0) return error.CopyFailed;
}

fn createShortcut(a: Allocator, lnk: []const u8, target: []const u8, description: []const u8) !void {
    var obj: ?*anyopaque = null;
    if (w.CoCreateInstance(&w.CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &w.IID_IShellLinkW, &obj) < 0 or obj == null) return error.Shortcut;
    const sl = obj.?;
    const vt: *const w.IShellLinkWVtbl = @as(*const *const w.IShellLinkWVtbl, @ptrCast(@alignCast(sl))).*;
    defer _ = vt.Release(sl);
    _ = vt.SetPath(sl, try wz(a, target));
    _ = vt.SetWorkingDirectory(sl, try wz(a, std.fs.path.dirname(target) orelse "."));
    _ = vt.SetDescription(sl, try wz(a, description));
    _ = vt.SetIconLocation(sl, try wz(a, target), 0);
    var pf: ?*anyopaque = null;
    if (vt.QueryInterface(sl, &w.IID_IPersistFile, &pf) < 0 or pf == null) return error.Shortcut;
    const pvt: *const w.IPersistFileVtbl = @as(*const *const w.IPersistFileVtbl, @ptrCast(@alignCast(pf.?))).*;
    defer _ = pvt.Release(pf.?);
    if (pvt.Save(pf.?, try wz(a, lnk), 1) < 0) return error.Shortcut;
}

fn openKey(a: Allocator, root: w.HKEY, path: []const u8, sam: u32) ?w.HKEY {
    var k: ?w.HKEY = null;
    const p = wz(a, path) catch return null;
    if (w.RegOpenKeyExW(root, p, 0, sam, &k) != w.ERROR_SUCCESS) return null;
    return k;
}

fn createKey(a: Allocator, path: []const u8) (RegistryError || Allocator.Error)!w.HKEY {
    var k: ?w.HKEY = null;
    if (w.RegCreateKeyExW(w.HKEY_CURRENT_USER, try wz(a, path), 0, null, 0, w.KEY_WRITE | w.KEY_READ, null, &k, null) != w.ERROR_SUCCESS or k == null) return error.Registry;
    return k.?;
}

fn setStr(a: Allocator, path: []const u8, name: ?[]const u8, value: []const u8) (RegistryError || Allocator.Error)!void {
    const k = try createKey(a, path);
    defer _ = w.RegCloseKey(k);
    const v = try wz(a, value);
    const n: ?[*:0]const u16 = if (name) |s| (try wz(a, s)).ptr else null;
    if (w.RegSetValueExW(k, n, 0, w.REG_SZ, @ptrCast(v.ptr), @intCast((v.len + 1) * 2)) != w.ERROR_SUCCESS) return error.Registry;
}

fn setDword(a: Allocator, path: []const u8, name: []const u8, value: u32) (RegistryError || Allocator.Error)!void {
    const k = try createKey(a, path);
    defer _ = w.RegCloseKey(k);
    const v = value;
    if (w.RegSetValueExW(k, try wz(a, name), 0, w.REG_DWORD, @ptrCast(&v), 4) != w.ERROR_SUCCESS) return error.Registry;
}

/// An empty REG_NONE value (how OpenWithProgids / SupportedTypes entries are written).
fn setNone(a: Allocator, path: []const u8, name: []const u8) (RegistryError || Allocator.Error)!void {
    const k = try createKey(a, path);
    defer _ = w.RegCloseKey(k);
    if (w.RegSetValueExW(k, try wz(a, name), 0, w.REG_NONE, null, 0) != w.ERROR_SUCCESS) return error.Registry;
}

fn getStr(a: Allocator, root: w.HKEY, path: []const u8, name: ?[]const u8) ?[]u8 {
    const k = openKey(a, root, path, w.KEY_READ) orelse return null;
    defer _ = w.RegCloseKey(k);
    const n: ?[*:0]const u16 = if (name) |s| (wz(a, s) catch return null).ptr else null;
    var typ: u32 = 0;
    var cb: u32 = 0;
    if (w.RegQueryValueExW(k, n, null, &typ, null, &cb) != w.ERROR_SUCCESS or typ != w.REG_SZ) return null;
    const buf = a.alloc(u16, cb / 2 + 1) catch return null;
    cb = @intCast(buf.len * 2);
    if (w.RegQueryValueExW(k, n, null, &typ, @ptrCast(buf.ptr), &cb) != w.ERROR_SUCCESS) return null;
    var len: usize = cb / 2;
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    return std.unicode.wtf16LeToWtf8Alloc(a, buf[0..len]) catch null;
}

fn getDword(a: Allocator, path: []const u8, name: []const u8) ?u32 {
    const k = openKey(a, w.HKEY_CURRENT_USER, path, w.KEY_READ) orelse return null;
    defer _ = w.RegCloseKey(k);
    var typ: u32 = 0;
    var v: u32 = 0;
    var cb: u32 = 4;
    if (w.RegQueryValueExW(k, wz(a, name) catch return null, null, &typ, @ptrCast(&v), &cb) != w.ERROR_SUCCESS or typ != w.REG_DWORD) return null;
    return v;
}

fn deleteValue(a: Allocator, path: []const u8, name: ?[]const u8) void {
    const k = openKey(a, w.HKEY_CURRENT_USER, path, w.KEY_WRITE) orelse return;
    defer _ = w.RegCloseKey(k);
    const n: ?[*:0]const u16 = if (name) |s| (wz(a, s) catch return).ptr else null;
    _ = w.RegDeleteValueW(k, n);
}

fn deleteTree(a: Allocator, path: []const u8) void {
    _ = w.RegDeleteTreeW(w.HKEY_CURRENT_USER, wz(a, path) catch return);
}

/// Delete the key when it has no values and no sub-keys left.
fn deleteIfEmpty(a: Allocator, path: []const u8) void {
    const k = openKey(a, w.HKEY_CURRENT_USER, path, w.KEY_READ) orelse return;
    var subkeys: u32 = 1;
    var values: u32 = 1;
    const ok = w.RegQueryInfoKeyW(k, null, null, null, &subkeys, null, null, &values, null, null, null, null) == w.ERROR_SUCCESS;
    _ = w.RegCloseKey(k);
    if (ok and subkeys == 0 and values == 0) _ = w.RegDeleteKeyW(w.HKEY_CURRENT_USER, wz(a, path) catch return);
}
