//! pstview in the web browser: the model (webapp.zig) compiled to WebAssembly (wasm32-wasi),
//! running in a Web Worker (web/worker.js) beside the same page (webui.html) the desktop
//! programs show. Nothing leaves the computer: the mailbox is read where it is.
//!
//! Files: the page hands the worker the File objects the user picked or dropped; the worker
//! names them ("/in/<n>/<name>", folders with their relative paths) and reads slices of them
//! synchronously (FileReaderSync) when the readers ask, so a mailbox of any size is read in place.
//! What the model writes goes to memory under "/out" and becomes downloads when the request is
//! answered (several files: one .zip, made by the page).
//!
//! All of this is an std.Io: the PST / MBOX readers and the exporters are unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const webapp = @import("webapp.zig");

const gpa = std.heap.wasm_allocator;

// ================================================================ functions of web/worker.js

extern "pstview" fn js_eval(win: u32, js: [*]const u8, len: usize) void;
/// Reads `len` bytes at `offset` of file `id` into `ptr`; the number read, or -1.
extern "pstview" fn read_file(id: u32, offset: f64, ptr: [*]u8, len: usize) isize;
/// A file written by the request being answered (`name` relative to "/out").
extern "pstview" fn out_file(name: [*]const u8, name_len: usize, data: [*]const u8, len: usize) void;
/// The files of the request are complete: they are offered as downloads.
extern "pstview" fn out_done() void;
extern "pstview" fn open_url(url: [*]const u8, len: usize) void;
extern "pstview" fn set_title(title: [*]const u8, len: usize) void;

// ================================================================ the files

const Input = struct { path: []u8, id: u32, size: u64 };
const Output = struct { path: []u8, data: std.ArrayList(u8) = .empty };

/// Files from the page (never written) and files written by the model.
var inputs: std.ArrayList(Input) = .empty;
var outputs: std.ArrayList(*Output) = .empty;

const out_dir = "/out";

const Open = struct {
    what: union(enum) { input: Input, output: *Output, dir: []u8 },
    /// Position of streaming reads and writes.
    pos: u64 = 0,
};
var open: std.AutoHashMapUnmanaged(i32, Open) = .empty;
var next_handle: i32 = 10;
/// Io.Dir.cwd() on wasi.
const cwd_handle: i32 = 3;

fn findInput(path: []const u8) ?Input {
    for (inputs.items) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

fn findOutput(path: []const u8) ?*Output {
    for (outputs.items) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

fn under(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return path.len > 1;
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

/// A folder: the root, "/out", or one that holds a file.
fn isDir(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, out_dir)) return true;
    for (inputs.items) |f| if (under(f.path, path)) return true;
    for (outputs.items) |f| if (under(f.path, path)) return true;
    return false;
}

fn dirPath(dir: Io.Dir) []const u8 {
    if (dir.handle == cwd_handle) return "/";
    const o = open.get(dir.handle) orelse return "/";
    return switch (o.what) {
        .dir => |p| p,
        else => "/",
    };
}

/// `sub` (absolute, or relative to `dir`) as a normal absolute path, in `buf`.
fn resolve(buf: []u8, dir: Io.Dir, sub: []const u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const base = if (sub.len > 0 and sub[0] == '/') "/" else dirPath(dir);
    return std.fs.path.resolvePosix(fba.allocator(), &.{ base, sub }) catch null;
}

fn newHandle(o: Open) ?i32 {
    const h = next_handle;
    open.put(gpa, h, o) catch return null;
    next_handle += 1;
    return h;
}

fn fileOf(h: i32) Io.File {
    return .{ .handle = h, .flags = .{ .nonblocking = false } };
}

fn stat(size: u64, kind: Io.File.Kind) Io.File.Stat {
    var s = std.mem.zeroes(Io.File.Stat);
    s.size = size;
    s.kind = kind;
    return s;
}

fn newOutput(path: []const u8) ?*Output {
    const o = gpa.create(Output) catch return null;
    o.* = .{ .path = gpa.dupe(u8, path) catch {
        gpa.destroy(o);
        return null;
    } };
    outputs.append(gpa, o) catch {
        gpa.free(o.path);
        gpa.destroy(o);
        return null;
    };
    return o;
}

fn removeOutput(o: *Output) void {
    for (outputs.items, 0..) |x, i| if (x == o) {
        _ = outputs.orderedRemove(i);
        break;
    };
    o.data.deinit(gpa);
    gpa.free(o.path);
    gpa.destroy(o);
}

// ================================================================ the std.Io

const vtable: Io.VTable = blk: {
    var v = Io.failing.vtable.*;
    v.dirCreateDir = dirCreateDir;
    v.dirCreateDirPath = dirCreateDirPath;
    v.dirOpenDir = dirOpenDir;
    v.dirStatFile = dirStatFile;
    v.dirAccess = dirAccess;
    v.dirCreateFile = dirCreateFile;
    v.dirOpenFile = dirOpenFile;
    v.dirClose = dirClose;
    v.dirRead = dirRead;
    v.dirRealPathFile = dirRealPathFile;
    v.dirDeleteFile = dirDeleteFile;
    v.dirRename = dirRename;
    v.fileStat = fileStat;
    v.fileLength = fileLength;
    v.fileClose = fileClose;
    v.fileWritePositional = fileWritePositional;
    v.fileReadPositional = fileReadPositional;
    v.fileSeekBy = fileSeekBy;
    v.fileSeekTo = fileSeekTo;
    v.fileSync = fileSync;
    v.fileSetLength = fileSetLength;
    v.operate = operate;
    break :blk v;
};
const io: Io = .{ .userdata = null, .vtable = &vtable };

fn dirCreateDir(_: ?*anyopaque, _: Io.Dir, _: []const u8, _: Io.Dir.Permissions) Io.Dir.CreateDirError!void {}

fn dirCreateDirPath(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, _: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    return if (isDir(path)) .existed else .created; // (folders are where files are)
}

fn dirOpenDir(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, _: Io.Dir.OpenOptions) Io.Dir.OpenError!Io.Dir {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    if (!isDir(path)) return if (findInput(path) != null or findOutput(path) != null) error.NotDir else error.FileNotFound;
    const copy = gpa.dupe(u8, path) catch return error.SystemResources;
    const h = newHandle(.{ .what = .{ .dir = copy } }) orelse return error.SystemResources;
    return .{ .handle = h };
}

fn statPath(path: []const u8) ?Io.File.Stat {
    if (findInput(path)) |f| return stat(f.size, .file);
    if (findOutput(path)) |f| return stat(f.data.items.len, .file);
    if (isDir(path)) return stat(0, .directory);
    return null;
}

fn dirStatFile(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, _: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    var buf: [4096]u8 = undefined;
    return statPath(resolve(&buf, dir, sub) orelse return error.NameTooLong) orelse error.FileNotFound;
}

fn dirAccess(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, _: Io.Dir.AccessOptions) Io.Dir.AccessError!void {
    var buf: [4096]u8 = undefined;
    _ = statPath(resolve(&buf, dir, sub) orelse return error.NameTooLong) orelse return error.FileNotFound;
}

fn dirCreateFile(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, opts: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    // the files the user opened are only read
    if (findInput(path) != null) return error.AccessDenied;
    if (isDir(path)) return error.IsDir;
    const o = findOutput(path) orelse (newOutput(path) orelse return error.SystemResources);
    if (opts.truncate) o.data.clearRetainingCapacity();
    const h = newHandle(.{ .what = .{ .output = o } }) orelse return error.SystemResources;
    return fileOf(h);
}

fn dirOpenFile(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, _: Io.Dir.OpenFileOptions) Io.File.OpenError!Io.File {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    const what: @FieldType(Open, "what") = if (findInput(path)) |f| .{ .input = f } else if (findOutput(path)) |o| .{ .output = o } else return if (isDir(path)) error.IsDir else error.FileNotFound;
    const h = newHandle(.{ .what = what }) orelse return error.SystemResources;
    return fileOf(h);
}

fn closeHandle(h: i32) void {
    const o = open.fetchRemove(h) orelse return;
    switch (o.value.what) {
        .dir => |p| gpa.free(p),
        else => {},
    }
}

fn dirClose(_: ?*anyopaque, dirs: []const Io.Dir) void {
    for (dirs) |d| if (d.handle != cwd_handle) closeHandle(d.handle);
}

/// The names in folder `dir`, sorted (files and folders, once each).
fn children(a: Allocator, dir: []const u8) ![]Io.Dir.Entry {
    var names: std.StringArrayHashMapUnmanaged(Io.File.Kind) = .empty;
    const paths = try a.alloc([]const u8, inputs.items.len + outputs.items.len);
    for (inputs.items, 0..) |f, i| paths[i] = f.path;
    for (outputs.items, 0..) |f, i| paths[inputs.items.len + i] = f.path;
    for (paths) |p| {
        if (!under(p, dir)) continue;
        const rest = p[(if (std.mem.eql(u8, dir, "/")) 1 else dir.len + 1)..];
        const slash = std.mem.indexOfScalar(u8, rest, '/');
        const gop = try names.getOrPut(a, rest[0 .. slash orelse rest.len]);
        if (!gop.found_existing or slash != null) gop.value_ptr.* = if (slash != null) .directory else .file;
    }
    const keys = names.keys();
    const order = try a.alloc(usize, keys.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, keys, struct {
        fn lt(k: [][]const u8, x: usize, y: usize) bool {
            return std.mem.lessThan(u8, k[x], k[y]);
        }
    }.lt);
    const out = try a.alloc(Io.Dir.Entry, keys.len);
    for (order, out) |i, *e| e.* = .{ .name = keys[i], .kind = names.values()[i], .inode = std.mem.zeroes(Io.File.INode) };
    return out;
}

/// Names handed out by dirRead live as long as the program (a few bytes per folder listed).
var names_arena: std.heap.ArenaAllocator = .init(gpa);

fn dirRead(_: ?*anyopaque, r: *Io.Dir.Reader, entries: []Io.Dir.Entry) Io.Dir.Reader.Error!usize {
    if (r.state == .finished) return 0;
    if (r.state == .reset) {
        r.index = 0;
        r.state = .reading;
    }
    const all = children(names_arena.allocator(), dirPath(r.dir)) catch return error.SystemResources;
    if (r.index >= all.len) {
        r.state = .finished;
        return 0;
    }
    const n = @min(entries.len, all.len - r.index);
    @memcpy(entries[0..n], all[r.index..][0..n]);
    r.index += n;
    return n;
}

fn dirRealPathFile(_: ?*anyopaque, dir: Io.Dir, sub: []const u8, out: []u8) Io.Dir.RealPathFileError!usize {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    if (statPath(path) == null) return error.FileNotFound;
    if (path.len > out.len) return error.NameTooLong;
    @memcpy(out[0..path.len], path);
    return path.len;
}

fn dirDeleteFile(_: ?*anyopaque, dir: Io.Dir, sub: []const u8) Io.Dir.DeleteFileError!void {
    var buf: [4096]u8 = undefined;
    const path = resolve(&buf, dir, sub) orelse return error.NameTooLong;
    if (findInput(path) != null) return error.AccessDenied;
    removeOutput(findOutput(path) orelse return error.FileNotFound);
}

fn dirRename(_: ?*anyopaque, old_dir: Io.Dir, old_sub: []const u8, new_dir: Io.Dir, new_sub: []const u8) Io.Dir.RenameError!void {
    var b1: [4096]u8 = undefined;
    var b2: [4096]u8 = undefined;
    const from = resolve(&b1, old_dir, old_sub) orelse return error.NameTooLong;
    const to = resolve(&b2, new_dir, new_sub) orelse return error.NameTooLong;
    if (findInput(from) != null or findInput(to) != null) return error.AccessDenied;
    const o = findOutput(from) orelse return error.FileNotFound;
    if (findOutput(to)) |old| if (old != o) removeOutput(old);
    const copy = gpa.dupe(u8, to) catch return error.SystemResources;
    gpa.free(o.path);
    o.path = copy;
}

fn openOf(f: Io.File) ?*Open {
    return open.getPtr(f.handle);
}

fn sizeOf(o: *const Open) u64 {
    return switch (o.what) {
        .input => |f| f.size,
        .output => |x| x.data.items.len,
        .dir => 0,
    };
}

fn fileStat(_: ?*anyopaque, f: Io.File) Io.File.StatError!Io.File.Stat {
    const o = openOf(f) orelse return error.Unexpected;
    return stat(sizeOf(o), if (o.what == .dir) .directory else .file);
}

fn fileLength(_: ?*anyopaque, f: Io.File) Io.File.LengthError!u64 {
    return sizeOf(openOf(f) orelse return error.Unexpected);
}

fn fileClose(_: ?*anyopaque, files: []const Io.File) void {
    for (files) |f| closeHandle(f.handle);
}

/// Read into `data` at `offset`; the number of bytes read.
fn readAt(o: *Open, data: []const []u8, offset: u64) !usize {
    var off = offset;
    var total: usize = 0;
    for (data) |buf| {
        if (buf.len == 0) continue;
        const n: usize = switch (o.what) {
            .input => |f| blk: {
                if (off >= f.size) break :blk 0;
                const want: usize = @intCast(@min(buf.len, f.size - off));
                const got = read_file(f.id, @floatFromInt(off), buf.ptr, want);
                if (got < 0) return error.InputOutput;
                break :blk @intCast(got);
            },
            .output => |x| blk: {
                if (off >= x.data.items.len) break :blk 0;
                const start: usize = @intCast(off);
                const k = @min(buf.len, x.data.items.len - start);
                @memcpy(buf[0..k], x.data.items[start..][0..k]);
                break :blk k;
            },
            .dir => return error.IsDir,
        };
        total += n;
        off += n;
        if (n < buf.len) break;
    }
    return total;
}

/// Write `header`, then `data` (its last slice `splat` times) at `offset`; the bytes written.
fn writeAt(o: *Open, header: []const u8, data: []const []const u8, splat: usize, offset: u64) !usize {
    const out = switch (o.what) {
        .output => |x| x,
        else => return error.NotOpenForWriting,
    };
    var at: usize = std.math.cast(usize, offset) orelse return error.FileTooBig;
    const put = struct {
        fn f(x: *Output, pos: *usize, bytes: []const u8) !void {
            const end = pos.* + bytes.len;
            if (end > x.data.items.len) {
                const old = x.data.items.len;
                x.data.resize(gpa, end) catch return error.NoSpaceLeft;
                if (pos.* > old) @memset(x.data.items[old..pos.*], 0);
            }
            @memcpy(x.data.items[pos.*..end], bytes);
            pos.* = end;
        }
    }.f;
    const start = at;
    try put(out, &at, header);
    for (data, 0..) |d, i| {
        if (i == data.len - 1) {
            for (0..splat) |_| try put(out, &at, d);
        } else try put(out, &at, d);
    }
    return at - start;
}

fn fileWritePositional(_: ?*anyopaque, f: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
    const o = openOf(f) orelse return error.Unexpected;
    return writeAt(o, header, data, splat, offset) catch |e| switch (e) {
        error.NotOpenForWriting => error.NotOpenForWriting,
        error.FileTooBig => error.FileTooBig,
        error.NoSpaceLeft => error.NoSpaceLeft,
    };
}

fn fileReadPositional(_: ?*anyopaque, f: Io.File, data: []const []u8, offset: u64) Io.File.ReadPositionalError!usize {
    const o = openOf(f) orelse return error.Unexpected;
    return readAt(o, data, offset) catch |e| switch (e) {
        error.InputOutput => error.InputOutput,
        error.IsDir => error.IsDir,
    };
}

fn fileSeekBy(_: ?*anyopaque, f: Io.File, by: i64) Io.File.SeekError!void {
    const o = openOf(f) orelse return error.Unexpected;
    const p: i64 = @as(i64, @intCast(o.pos)) + by;
    o.pos = @intCast(@max(p, 0));
}

fn fileSeekTo(_: ?*anyopaque, f: Io.File, to: u64) Io.File.SeekError!void {
    (openOf(f) orelse return error.Unexpected).pos = to;
}

fn fileSync(_: ?*anyopaque, _: Io.File) Io.File.SyncError!void {}

fn fileSetLength(_: ?*anyopaque, f: Io.File, len: u64) Io.File.SetLengthError!void {
    const o = openOf(f) orelse return error.Unexpected;
    const x = switch (o.what) {
        .output => |x| x,
        else => return error.AccessDenied,
    };
    const n = std.math.cast(usize, len) orelse return error.FileTooBig;
    const old = x.data.items.len;
    x.data.resize(gpa, n) catch return error.FileTooBig;
    if (n > old) @memset(x.data.items[old..], 0);
}

fn operate(_: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
    switch (op) {
        .file_read_streaming => |r| {
            const o = openOf(r.file) orelse return .{ .file_read_streaming = error.InputOutput };
            const n = readAt(o, r.data, o.pos) catch return .{ .file_read_streaming = error.InputOutput };
            o.pos += n;
            if (n == 0 and r.data.len > 0) return .{ .file_read_streaming = error.EndOfStream };
            return .{ .file_read_streaming = n };
        },
        .file_write_streaming => |w| {
            const o = openOf(w.file) orelse return .{ .file_write_streaming = error.InputOutput };
            const n = writeAt(o, w.header, w.data, w.splat, o.pos) catch |e| return .{ .file_write_streaming = switch (e) {
                error.NotOpenForWriting => error.NotOpenForWriting,
                error.FileTooBig => error.FileTooBig,
                error.NoSpaceLeft => error.NoSpaceLeft,
            } };
            o.pos += n;
            return .{ .file_write_streaming = n };
        },
        else => return Io.failing.vtable.operate(null, op),
    }
}

// ================================================================ shell for webapp.zig

fn eval(win: u32, js: []const u8) void {
    js_eval(win, js.ptr, js.len);
}

/// What the page picked before asking (files, or the folder of a picked folder).
var picked: std.ArrayList([]u8) = .empty;

fn clearPicked() void {
    for (picked.items) |p| gpa.free(p);
    picked.clearRetainingCapacity();
}

/// The files the page has just had picked; with none, a folder to write to is "/out" (an
/// export: it becomes downloads), and anything else was cancelled.
fn pickOpen(a: Allocator, _: []const u8, _: bool, folders: bool) ?[]const []const u8 {
    if (picked.items.len > 0) {
        const out = a.alloc([]const u8, picked.items.len) catch return null;
        for (picked.items, out) |p, *o| o.* = a.dupe(u8, p) catch return null;
        clearPicked();
        return out;
    }
    if (!folders) return null;
    const out = a.alloc([]const u8, 1) catch return null;
    out[0] = out_dir;
    return out;
}

fn pickSave(a: Allocator, _: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ out_dir, std.fs.path.basename(name) }) catch null;
}

fn openPath(_: []const u8) void {} // (an export's folder: its files are downloads)

fn openUrl(url: []const u8) void {
    open_url(url.ptr, url.len);
}

fn setTitle(title: []const u8) void {
    set_title(title.ptr, title.len);
}

fn openWindow(_: []const u8) ?u32 {
    return null; // one page; a message is enlarged in it instead
}

fn closeWindow(_: u32) void {}
fn pump() void {} // (the worker posts progress as it goes)
fn setDark(_: bool) void {}
fn quit(_: u8) void {}

/// The files written while answering: offered as downloads, then forgotten.
fn flush() void {
    var any = false;
    for (outputs.items) |o| {
        const name = if (std.mem.startsWith(u8, o.path, out_dir ++ "/")) o.path[out_dir.len + 1 ..] else std.fs.path.basename(o.path);
        out_file(name.ptr, name.len, o.data.items.ptr, o.data.items.len);
        any = true;
    }
    if (any) out_done();
    while (outputs.items.len > 0) removeOutput(outputs.items[0]);
}

// ================================================================ exports for web/worker.js

export fn pv_alloc(len: usize) ?[*]u8 {
    const m = gpa.alloc(u8, len) catch return null;
    return m.ptr;
}

export fn pv_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

export fn pv_init() void {
    webapp.init(gpa, io, .{
        .eval = &eval,
        .pickOpen = &pickOpen,
        .pickSave = &pickSave,
        .openPath = &openPath,
        .openUrl = &openUrl,
        .setTitle = &setTitle,
        .openWindow = &openWindow,
        .closeWindow = &closeWindow,
        .pump = &pump,
        .setDark = &setDark,
        .quit = &quit,
    }, &.{}, false);
}

/// A request from the page.
export fn pv_message(win: u32, ptr: [*]const u8, len: usize) void {
    webapp.onMessage(win, ptr[0..len]);
    flush();
}

/// A file from the page, at `path` (made by the worker), read through `id`.
export fn pv_add_file(path: [*]const u8, len: usize, id: u32, size: f64) void {
    if (findInput(path[0..len]) != null) return;
    const p = gpa.dupe(u8, path[0..len]) catch return;
    inputs.append(gpa, .{ .path = p, .id = id, .size = @intFromFloat(size) }) catch gpa.free(p);
}

/// What the next request that picks files gets (a file or folder path).
export fn pv_pick(path: [*]const u8, len: usize) void {
    const p = gpa.dupe(u8, path[0..len]) catch return;
    picked.append(gpa, p) catch gpa.free(p);
}

/// Files dropped on the page: opened at once.
export fn pv_drop() void {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    for (picked.items) |p| list.append(gpa, p) catch {};
    webapp.openFromShell(list.items);
    clearPicked();
    flush();
}
