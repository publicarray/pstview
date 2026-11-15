//! Read-only MBOX mailbox source.
//!
//! Layouts:
//!   * a single mbox file (any extension) - one folder;
//!   * Google Takeout - one large mbox whose X-Gmail-Labels become virtual folders;
//!   * Thunderbird mail folders - extension-less mbox files with `Name.sbd` subfolder directories
//!     (messages flagged expunged in X-Mozilla-Status but not yet compacted are marked);
//!   * Apple Mail exports - `Name.mbox` bundle directories holding an `mbox` file, nestable;
//!   * any directory containing the above.
//!
//! Message boundaries are "From " lines that carry a date and are followed by a header line.
//! Escaped ">From " lines (mboxo/mboxrd) are unescaped when a message is read. Files are scanned
//! lazily, one at a time, in a streaming pass, so multi-gigabyte mailboxes work.
//!
//! Messages are exposed as `pst.MessageSummary` / `pst.Message` with MAPI-style properties
//! synthesized from the MIME message, so the viewer, header analysis, search and .msg export
//! work unchanged; `rawMessage` returns the original bytes for exact .eml export.
//! Nothing is ever written next to the source: no index or cache files.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
const mime = @import("mime.zig");

pub const Error = error{ NotMbox, NotFound };

pub const Layout = enum {
    single,
    takeout,
    thunderbird,
    apple,
    folder,

    pub fn label(l: Layout) []const u8 {
        return switch (l) {
            .single => "MBOX file",
            .takeout => "MBOX, Google Takeout (Gmail labels as folders)",
            .thunderbird => "MBOX, Thunderbird mail folder",
            .apple => "MBOX, Apple Mail export",
            .folder => "MBOX folder",
        };
    }
};

/// Progress of long scans (bytes done, bytes total); set by front ends.
pub var scan_progress: ?*const fn (done: u64, total: u64) void = null;

const Folder = struct {
    name: []const u8,
    parent: u32,
    children: std.ArrayList(u32) = .empty,
    /// mbox file whose messages this folder lists
    source: ?u32 = null,
    /// virtual folder (Gmail label): message ids
    members: std.ArrayList(u32) = .empty,
};

pub const Source = struct {
    path: []const u8,
    size: u64,
    folder: u32,
    file: ?Io.File = null,
    scanned: bool = false,
    takeout: bool = false,
    first: u32 = 0,
    count: u32 = 0,
};

const Entry = struct {
    source: u32,
    /// first byte after the From_ line
    off: u64,
    len: u64,
    summary: pst.MessageSummary,
};

const MSGFLAG_READ: i64 = 0x1;
const max_header_window = 1024 * 1024;

pub const Mbox = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    layout: Layout = .single,
    folders: std.ArrayList(Folder) = .empty,
    sources: std.ArrayList(Source) = .empty,
    msgs: std.ArrayList(Entry) = .empty,
    label_folders: std.StringHashMapUnmanaged(u32) = .empty,
    saw_thunderbird: bool = false,
    saw_apple: bool = false,

    /// Open an mbox file or a directory of mailboxes (Thunderbird / Apple Mail / any) read-only.
    pub fn open(gpa: Allocator, io: Io, path_in: []const u8) !*Mbox {
        const self = try gpa.create(Mbox);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .path = "" };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const path = try a.dupe(u8, std.mem.trimEnd(u8, path_in, "\\/"));
        self.path = path;
        const cwd = Io.Dir.cwd();
        const st = try cwd.statFile(io, path, .{});
        try self.folders.append(a, .{ .name = std.fs.path.basename(path), .parent = 0 });

        if (st.kind == .directory) {
            const base = std.fs.path.basename(path);
            if (endsWithIc(base, ".mbox") and isMboxFile(io, try std.fs.path.join(a, &.{ path, "mbox" }))) {
                // the Apple bundle itself was opened
                self.saw_apple = true;
                try self.addBundle(path, try self.addFolder(0, base[0 .. base.len - 5]), 0);
            } else {
                try self.addDir(path, 0, 0);
            }
            if (self.sources.items.len == 0) return error.NotMbox;
            self.layout = if (self.saw_thunderbird) .thunderbird else if (self.saw_apple) .apple else .folder;
        } else {
            if (!isMboxFile(io, path)) return error.NotMbox;
            const fid = try self.addSourceFolder(0, stemOf(std.fs.path.basename(path)), path, st.size);
            const sbd = try std.fmt.allocPrint(a, "{s}.sbd", .{path});
            if (isDir(io, sbd)) {
                self.saw_thunderbird = true;
                try self.addDir(sbd, fid, 1);
            }
            self.layout = if (self.saw_thunderbird) .thunderbird else .single;
        }
        // Scan every mailbox now, in tree order: message ids are then stable between runs (the
        // CLI addresses messages by id), the tree shows counts, and Google Takeout label folders
        // exist before the tree is built.
        for (self.sources.items) |*s| s.takeout = self.peekTakeout(s.path);
        for (0..self.sources.items.len) |i| try self.scan(@intCast(i));
        if (self.sources.items.len == 1 and self.sources.items[0].takeout) self.layout = .takeout;
        return self;
    }

    pub fn close(self: *Mbox) void {
        for (self.sources.items) |s| if (s.file) |f| f.close(self.io);
        self.label_folders.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self);
    }

    pub fn rootFolder(_: *const Mbox) u32 {
        return 0;
    }

    pub fn describe(self: *const Mbox, buf: []u8) []const u8 {
        var total: u64 = 0;
        for (self.sources.items) |s| total += s.size;
        const n = self.sources.items.len;
        return std.fmt.bufPrint(buf, "{s}, {d} file{s}, {d} MB", .{ self.layout.label(), n, if (n == 1) "" else "s", total / (1024 * 1024) }) catch "";
    }

    pub fn totalSize(self: *const Mbox) u64 {
        var total: u64 = 0;
        for (self.sources.items) |s| total += s.size;
        return total;
    }

    // ------------------------------------------------------------ folder tree

    fn addFolder(self: *Mbox, parent: u32, name: []const u8) !u32 {
        const a = self.arena.allocator();
        const id: u32 = @intCast(self.folders.items.len);
        try self.folders.append(a, .{ .name = try a.dupe(u8, name), .parent = parent });
        try self.folders.items[parent].children.append(a, id);
        return id;
    }

    fn addSourceFolder(self: *Mbox, parent: u32, name: []const u8, path: []const u8, size: u64) !u32 {
        const a = self.arena.allocator();
        const fid = try self.addFolder(parent, name);
        const sid: u32 = @intCast(self.sources.items.len);
        try self.sources.append(a, .{ .path = try a.dupe(u8, path), .size = size, .folder = fid });
        self.folders.items[fid].source = sid;
        return fid;
    }

    const DirEntry = struct { name: []const u8, kind: Io.File.Kind };

    fn listDir(self: *Mbox, path: []const u8) ![]DirEntry {
        const a = self.arena.allocator();
        var dir = try Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer dir.close(self.io);
        var out: std.ArrayList(DirEntry) = .empty;
        var it = dir.iterate();
        while (try it.next(self.io)) |e| try out.append(a, .{ .name = try a.dupe(u8, e.name), .kind = e.kind });
        std.mem.sort(DirEntry, out.items, {}, struct {
            fn lt(_: void, x: DirEntry, y: DirEntry) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.lt);
        return out.items;
    }

    /// Add the mailboxes found in a directory as children of folder `parent`.
    fn addDir(self: *Mbox, path: []const u8, parent: u32, depth: u32) !void {
        if (depth > 12) return;
        const a = self.arena.allocator();
        const entries = self.listDir(path) catch return;
        // files first, so a "Name.sbd" directory can attach to the "Name" mailbox
        var by_name: std.StringHashMapUnmanaged(u32) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (entries) |e| if (e.kind == .file) try names.put(a, e.name, {});
        for (entries) |e| {
            if (e.kind != .file) continue;
            if (endsWithIc(e.name, ".msf")) self.saw_thunderbird = true;
            if (skipFile(e.name)) continue;
            const full = try std.fs.path.join(a, &.{ path, e.name });
            const st = Io.Dir.cwd().statFile(self.io, full, .{}) catch continue;
            const msf = try std.fmt.allocPrint(a, "{s}.msf", .{e.name});
            if (!isMboxFile(self.io, full) and !(st.size == 0 and names.contains(msf))) continue;
            const fid = try self.addSourceFolder(parent, stemOf(e.name), full, st.size);
            try by_name.put(a, e.name, fid);
        }
        for (entries) |e| {
            if (e.kind != .directory or e.name[0] == '.') continue;
            const full = try std.fs.path.join(a, &.{ path, e.name });
            if (endsWithIc(e.name, ".sbd")) {
                self.saw_thunderbird = true;
                const stem = e.name[0 .. e.name.len - 4];
                const target = by_name.get(stem) orelse try self.addFolder(parent, stem);
                try self.addDir(full, target, depth + 1);
            } else if (endsWithIc(e.name, ".mbox")) {
                self.saw_apple = true;
                const fid = try self.addFolder(parent, e.name[0 .. e.name.len - 5]);
                try self.addBundle(full, fid, depth + 1);
            } else {
                const fid = try self.addFolder(parent, e.name);
                try self.addDir(full, fid, depth + 1); // shown only if it holds mailboxes
            }
        }
    }

    /// Apple Mail bundle: `<dir>/mbox` holds the messages of folder `fid`; nested bundles are subfolders.
    fn addBundle(self: *Mbox, dir_path: []const u8, fid: u32, depth: u32) !void {
        const a = self.arena.allocator();
        const mpath = try std.fs.path.join(a, &.{ dir_path, "mbox" });
        if (isMboxFile(self.io, mpath)) {
            const st = Io.Dir.cwd().statFile(self.io, mpath, .{}) catch null;
            const sid: u32 = @intCast(self.sources.items.len);
            try self.sources.append(a, .{ .path = mpath, .size = if (st) |s| s.size else 0, .folder = fid });
            self.folders.items[fid].source = sid;
        }
        if (depth > 12) return;
        const entries = self.listDir(dir_path) catch return;
        for (entries) |e| {
            if (e.kind != .directory or !endsWithIc(e.name, ".mbox")) continue;
            const child = try self.addFolder(fid, e.name[0 .. e.name.len - 5]);
            try self.addBundle(try std.fs.path.join(a, &.{ dir_path, e.name }), child, depth + 1);
        }
    }

    /// A folder is shown if it lists a mailbox or label, or has such a descendant.
    fn visible(self: *const Mbox, fid: u32) bool {
        const f = self.folders.items[fid];
        if (f.source != null or f.members.items.len > 0) return true;
        for (f.children.items) |c| if (self.visible(c)) return true;
        return false;
    }

    pub fn folderInfo(self: *Mbox, a: Allocator, id: u32) !pst.FolderInfo {
        _ = a;
        if (id >= self.folders.items.len) return error.NotFound;
        const f = self.folders.items[id];
        var count: i64 = 0;
        if (f.source) |s| {
            if (self.sources.items[s].scanned) count = self.sources.items[s].count;
        } else count = @intCast(f.members.items.len);
        return .{ .nid = id, .name = f.name, .count = count, .unread = 0, .has_subfolders = f.children.items.len > 0, .container_class = "" };
    }

    pub fn subFolders(self: *Mbox, a: Allocator, id: u32) ![]u32 {
        if (id >= self.folders.items.len) return error.NotFound;
        var out: std.ArrayList(u32) = .empty;
        for (self.folders.items[id].children.items) |c| if (self.visible(c)) try out.append(a, c);
        return out.toOwnedSlice(a);
    }

    pub fn folderMessages(self: *Mbox, a: Allocator, id: u32) ![]pst.MessageSummary {
        if (id >= self.folders.items.len) return error.NotFound;
        const f = self.folders.items[id];
        if (f.source) |s| {
            try self.scan(s);
            const src = self.sources.items[s];
            const out = try a.alloc(pst.MessageSummary, src.count);
            for (out, 0..) |*m, k| m.* = self.msgs.items[src.first + k].summary;
            return out;
        }
        const out = try a.alloc(pst.MessageSummary, f.members.items.len);
        for (out, f.members.items) |*m, mid| m.* = self.msgs.items[mid].summary;
        return out;
    }

    // ------------------------------------------------------------ scanning

    fn fileOf(self: *Mbox, sid: u32) !Io.File {
        const s = &self.sources.items[sid];
        if (s.file) |f| return f;
        const f = try Io.Dir.cwd().openFile(self.io, s.path, .{ .mode = .read_only });
        s.file = f;
        return f;
    }

    fn readAt(self: *Mbox, sid: u32, buf: []u8, off: u64) ![]u8 {
        const f = try self.fileOf(sid);
        const n = try f.readPositionalAll(self.io, buf, off);
        return buf[0..n];
    }

    /// Does the first message carry Gmail labels?
    fn peekTakeout(self: *Mbox, path: []const u8) bool {
        var buf: [64 * 1024]u8 = undefined;
        const f = Io.Dir.cwd().openFile(self.io, path, .{ .mode = .read_only }) catch return false;
        defer f.close(self.io);
        const n = f.readPositionalAll(self.io, &buf, 0) catch return false;
        const head = mime.splitMessage(buf[0..n]).head;
        return std.ascii.findIgnoreCase(head, "\nX-Gmail-Labels:") != null;
    }

    /// Find all messages of a source and build their list entries (once).
    fn scan(self: *Mbox, sid: u32) !void {
        if (self.sources.items[sid].scanned) return;
        const size = self.sources.items[sid].size;
        const starts = try self.findStarts(sid, size);
        defer self.gpa.free(starts);

        const first: u32 = @intCast(self.msgs.items.len);
        var win = try self.gpa.alloc(u8, 64 * 1024);
        defer self.gpa.free(win);
        var tmp = std.heap.ArenaAllocator.init(self.gpa);
        defer tmp.deinit();
        for (starts, 0..) |from_off, k| {
            _ = tmp.reset(.retain_capacity);
            const next = if (k + 1 < starts.len) starts[k + 1] else size;
            const total = next - from_off;
            var w = try self.readAt(sid, win, from_off);
            w = w[0..@min(w.len, total)];
            const nl = std.mem.indexOfScalar(u8, w, '\n') orelse w.len;
            const off = from_off + @min(nl + 1, total);
            var sp = mime.splitMessage(w[@min(nl + 1, w.len)..]);
            if (sp.body.len == 0 and w.len < total and win.len < max_header_window) {
                // header block longer than the window: read up to 1 MiB
                self.gpa.free(win);
                win = try self.gpa.alloc(u8, max_header_window);
                w = try self.readAt(sid, win, from_off);
                w = w[0..@min(w.len, total)];
                sp = mime.splitMessage(w[@min(nl + 1, w.len)..]);
            }
            const from_line = std.mem.trimEnd(u8, w[0..@min(nl, w.len)], "\r");
            const id: u32 = @intCast(self.msgs.items.len);
            const summary = try self.summarize(tmp.allocator(), sid, id, sp.head, from_line, next - off);
            try self.msgs.append(self.arena.allocator(), .{ .source = sid, .off = off, .len = next - off, .summary = summary });
            if (scan_progress) |p| if (k % 2000 == 0) p(from_off, size);
        }
        const s = &self.sources.items[sid];
        s.first = first;
        s.count = @intCast(self.msgs.items.len - first);
        s.scanned = true;
        if (s.takeout) self.sortLabelFolders(s.folder);
    }

    /// Offsets of all valid From_ lines (streaming over the file in 8 MiB chunks).
    fn findStarts(self: *Mbox, sid: u32, size: u64) ![]u64 {
        var starts: std.ArrayList(u64) = .empty;
        errdefer starts.deinit(self.gpa);
        const chunk = 8 * 1024 * 1024;
        const buf = try self.gpa.alloc(u8, chunk);
        defer self.gpa.free(buf);
        var small: [2048]u8 = undefined;
        var base: u64 = 0;
        var last: ?u64 = null;
        while (base < size) {
            const got = try self.readAt(sid, buf, base);
            if (got.len == 0) break;
            var i: usize = 0;
            while (true) {
                // candidate line starts: offset 0 of the file, or just after a '\n'
                var ls: usize = undefined;
                if (base == 0 and i == 0 and last == null) {
                    ls = if (std.mem.startsWith(u8, got, "﻿")) 3 else 0;
                } else {
                    const hit = std.mem.indexOfPos(u8, got, i, "\nFrom ") orelse break;
                    ls = hit + 1;
                }
                i = ls + 1;
                const abs = base + ls;
                if (last != null and abs <= last.?) continue;
                // the From_ line and the following line, from the chunk or a small extra read
                var view = got[ls..];
                if (std.mem.count(u8, view[0..@min(view.len, small.len)], "\n") < 2 and base + got.len < size) {
                    view = try self.readAt(sid, &small, abs);
                }
                if (isFromLine(view)) {
                    try starts.append(self.gpa, abs);
                    last = abs;
                }
            }
            if (base + got.len >= size or got.len <= 6) break;
            base += got.len - 6; // overlap so a "\nFrom " across the chunk border is seen
            if (scan_progress) |p| p(base, size * 2);
        }
        return starts.toOwnedSlice(self.gpa);
    }

    fn summarize(self: *Mbox, t: Allocator, sid: u32, id: u32, head: []const u8, from_line: []const u8, len: u64) !pst.MessageSummary {
        const a = self.arena.allocator();
        const h = try mime.parseHeaders(t, head);
        const from = mime.parseAddresses(t, h.get("from") orelse "");
        const submit = if (h.get("date")) |d| mime.parseDate(d) else null;
        const delivery = receivedDate(h) orelse fromLineDate(from_line) orelse submit;
        var flags: ?i64 = null;
        var note: []const u8 = "";
        if (h.get("x-mozilla-status")) |v| if (std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 16)) |ms| {
            flags = if (ms & 0x0001 != 0) MSGFLAG_READ else 0;
            if (ms & 0x0008 != 0) note = "deleted in Thunderbird (expunged, not yet compacted)";
        } else |_| {};
        if (flags == null) if (h.get("status")) |v| {
            flags = if (std.mem.indexOfScalar(u8, v, 'R') != null) MSGFLAG_READ else 0;
        };
        if (self.sources.items[sid].takeout) {
            const labels = parseLabels(t, h.get("x-gmail-labels") orelse "");
            var unread = false;
            for (labels) |l| {
                if (std.mem.eql(u8, l, "Unread")) unread = true;
                try self.addToLabel(sid, l, id);
            }
            flags = if (unread) 0 else MSGFLAG_READ;
            note = try std.mem.join(t, ", ", labels);
        }
        const ctype = mime.mediaType(t, h.get("content-type") orelse "");
        return .{
            .nid = id,
            .subject = try a.dupe(u8, mime.decodeHeader(t, h.get("subject") orelse "")),
            .from = try a.dupe(u8, if (from.len > 0) (if (from[0].name.len > 0) from[0].name else from[0].email) else ""),
            .to = try a.dupe(u8, mime.displayList(t, mime.parseAddresses(t, h.get("to") orelse ""))),
            .cc = try a.dupe(u8, mime.displayList(t, mime.parseAddresses(t, h.get("cc") orelse ""))),
            .message_class = classFor(ctype),
            .delivery_time = delivery,
            .submit_time = submit,
            .modified_time = null,
            .size = @intCast(@min(len, std.math.maxInt(i64))),
            .flags = flags,
            .note = try a.dupe(u8, note),
        };
    }

    fn addToLabel(self: *Mbox, sid: u32, label: []const u8, id: u32) !void {
        const a = self.arena.allocator();
        var parent = self.sources.items[sid].folder;
        var it = std.mem.splitScalar(u8, label, '/');
        var pos: usize = 0;
        var fid: u32 = parent;
        while (it.next()) |part| {
            pos += part.len;
            const key = try std.fmt.allocPrint(a, "{d}\x00{s}", .{ sid, label[0..pos] });
            pos += 1;
            if (self.label_folders.get(key)) |f| {
                fid = f;
            } else {
                fid = try self.addFolder(parent, if (part.len > 0) part else "(unnamed)");
                try self.label_folders.put(self.gpa, key, fid);
            }
            parent = fid;
        }
        try self.folders.items[fid].members.append(a, id);
    }

    /// Gmail system labels first (Inbox, Sent, ...), then user labels alphabetically.
    fn sortLabelFolders(self: *Mbox, fid: u32) void {
        const Ctx = struct {
            m: *Mbox,
            fn rank(name: []const u8) u8 {
                const order = [_][]const u8{ "Inbox", "Starred", "Important", "Sent", "Drafts", "Archived", "Spam", "Trash", "Chat" };
                for (order, 0..) |o, i| if (std.mem.eql(u8, name, o)) return @intCast(i);
                if (std.mem.startsWith(u8, name, "Category ")) return 20;
                if (std.mem.eql(u8, name, "Opened") or std.mem.eql(u8, name, "Unread")) return 30;
                return 25;
            }
            fn lt(c: @This(), x: u32, y: u32) bool {
                const nx = c.m.folders.items[x].name;
                const ny = c.m.folders.items[y].name;
                const rx = rank(nx);
                const ry = rank(ny);
                if (rx != ry) return rx < ry;
                return std.ascii.lessThanIgnoreCase(nx, ny);
            }
        };
        std.mem.sort(u32, self.folders.items[fid].children.items, Ctx{ .m = self }, Ctx.lt);
        for (self.folders.items[fid].children.items) |c| self.sortLabelFolders(c);
    }

    // ------------------------------------------------------------ messages

    /// Original message bytes (">From " unescaped, the mbox separator line removed), for exact .eml export.
    pub fn rawMessage(self: *Mbox, a: Allocator, id: u32) ![]const u8 {
        if (id >= self.msgs.items.len) return error.NotFound;
        const e = self.msgs.items[id];
        const buf = try a.alloc(u8, @intCast(e.len));
        const got = try self.readAt(e.source, buf, e.off);
        return unescapeFrom(a, stripSeparator(got));
    }

    pub fn loadMessage(self: *Mbox, a: Allocator, id: u32) !pst.Message {
        const raw = try self.rawMessage(a, id);
        const m = try mime.parse(a, raw, 0);
        return synthesize(a, id, m, raw.len, self.msgs.items[id].summary);
    }

    /// Headers and recipients only (no body or attachments) - used for search and triage.
    pub fn loadMessageHeaders(self: *Mbox, a: Allocator, id: u32) !pst.Message {
        if (id >= self.msgs.items.len) return error.NotFound;
        const e = self.msgs.items[id];
        var buf = try a.alloc(u8, @intCast(@min(e.len, 64 * 1024)));
        var got = try self.readAt(e.source, buf, e.off);
        if (mime.splitMessage(got).body.len == 0 and e.len > got.len) {
            buf = try a.alloc(u8, @intCast(@min(e.len, max_header_window)));
            got = try self.readAt(e.source, buf, e.off);
        }
        const m = try mime.parseHead(a, got);
        return synthesize(a, id, m, @intCast(e.len), e.summary);
    }
};

/// One raw message (an .eml) as a `pst.Message`, without a mailbox around it. This is the whole
/// path untrusted mail takes on its way to the viewer, which is what the fuzz targets drive.
pub fn messageFromRaw(a: Allocator, raw: []const u8) !pst.Message {
    const m = try mime.parse(a, raw, 0);
    const empty: pst.MessageSummary = .{ .nid = 0, .subject = "", .from = "", .to = "", .cc = "", .message_class = "", .delivery_time = null, .submit_time = null, .modified_time = null, .size = null, .flags = null };
    return synthesize(a, 0, m, raw.len, empty);
}

// ================================================================ helpers

fn endsWithIc(s: []const u8, suffix: []const u8) bool {
    return s.len >= suffix.len and std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn stemOf(name: []const u8) []const u8 {
    for ([_][]const u8{ ".mbox", ".mbx", ".mbs" }) |ext| if (endsWithIc(name, ext) and name.len > ext.len) return name[0 .. name.len - ext.len];
    return name;
}

/// Files in mail folders that are never mailboxes (indexes, settings, caches).
fn skipFile(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const exts = [_][]const u8{ ".msf", ".dat", ".json", ".sqlite", ".html", ".htm", ".zip", ".xml", ".plist", ".log", ".wal", ".js", ".ini", ".mab", ".bak", ".toc", ".lock", ".png", ".jpg", ".txt", ".eml", ".pst", ".ost", ".mozmsgs", ".sqlite-wal", ".sqlite-shm" };
    for (exts) |e| if (endsWithIc(name, e)) return true;
    return std.ascii.eqlIgnoreCase(name, "table_of_contents") or std.ascii.eqlIgnoreCase(name, "Info.plist");
}

fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Does the file start (after an optional BOM / blank lines) with a valid From_ line?
pub fn isMboxFile(io: Io, path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    return startsLikeMbox(buf[0..n]);
}

pub fn startsLikeMbox(data: []const u8) bool {
    var d = data;
    if (std.mem.startsWith(u8, d, "\xEF\xBB\xBF")) d = d[3..];
    d = std.mem.trimStart(u8, d, "\r\n");
    return isFromLine(d);
}

/// A message separator: "From " + sender + a date (time or 4-digit year), and the next line
/// looks like a header field. The second check (as in eneam/mboxviewer) rejects unescaped
/// "From " lines inside message bodies.
pub fn isFromLine(view: []const u8) bool {
    if (!std.mem.startsWith(u8, view, "From ")) return false;
    const e1 = std.mem.indexOfScalar(u8, view, '\n') orelse return false;
    const line = std.mem.trimEnd(u8, view[5..e1], "\r");
    var has_time = false;
    var has_year = false;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    _ = it.next(); // sender
    while (it.next()) |tok| {
        if (tok.len >= 4 and std.ascii.isDigit(tok[0]) and std.mem.indexOfScalar(u8, tok, ':') != null) has_time = true;
        if (tok.len == 4 and std.ascii.isDigit(tok[0]) and std.ascii.isDigit(tok[3])) has_year = true;
    }
    if (!has_time and !has_year) return false;
    const rest = view[e1 + 1 ..];
    const e2 = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const next = std.mem.trimEnd(u8, rest[0..e2], "\r");
    return headerLike(next);
}

fn headerLike(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    if (colon == 0) return false;
    for (line[0..colon]) |c| if (c <= ' ' or c >= 0x7F) return false;
    return true;
}

/// Drop the empty line that separates a message from the next "From " line (RFC 4155: it belongs
/// to the mbox format, not to the message). Only a trailing blank line is removed.
pub fn stripSeparator(m: []const u8) []const u8 {
    if (std.mem.endsWith(u8, m, "\n\r\n")) return m[0 .. m.len - 2];
    if (std.mem.endsWith(u8, m, "\n\n")) return m[0 .. m.len - 1];
    return m;
}

/// Undo From_ escaping: a line of one or more '>' followed by "From " loses one '>' (mboxrd;
/// also correct for the single-level escaping of mboxo writers).
pub fn unescapeFrom(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, raw, ">From ") == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        const eol = if (std.mem.indexOfScalarPos(u8, raw, i, '\n')) |p| p + 1 else raw.len;
        const line = raw[i..eol];
        var k: usize = 0;
        while (k < line.len and line[k] == '>') k += 1;
        if (k > 0 and std.mem.startsWith(u8, line[k..], "From ")) out.appendSliceAssumeCapacity(line[1..]) else out.appendSliceAssumeCapacity(line);
        i = eol;
    }
    return out.items;
}

/// Date of the most recent Received hop (the first Received header), i.e. final delivery.
fn receivedDate(h: mime.Headers) ?i64 {
    const v = h.get("received") orelse return null;
    const semi = std.mem.lastIndexOfScalar(u8, v, ';') orelse return null;
    return mime.parseDate(v[semi + 1 ..]);
}

fn fromLineDate(line: []const u8) ?i64 {
    if (line.len <= 5) return null;
    const rest = line[5..];
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    return mime.parseDate(rest[sp..]);
}

/// X-Gmail-Labels: comma-separated, quoted labels may contain commas, words may be encoded.
pub fn parseLabels(a: Allocator, v: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var in_q = false;
    var i: usize = 0;
    while (i <= v.len) : (i += 1) {
        const c: u8 = if (i < v.len) v[i] else ',';
        if (c == '"') in_q = !in_q;
        if (c == ',' and !in_q) {
            var l = std.mem.trim(u8, v[start..@min(i, v.len)], " \t\r\n");
            if (l.len >= 2 and l[0] == '"' and l[l.len - 1] == '"') l = l[1 .. l.len - 1];
            l = mime.decodeHeader(a, l);
            if (l.len > 0) out.append(a, l) catch break;
            start = i + 1;
        }
    }
    return out.items;
}

fn classFor(ctype: []const u8) []const u8 {
    if (std.mem.eql(u8, ctype, "multipart/report")) return "REPORT.IPM.Note";
    if (std.mem.eql(u8, ctype, "text/calendar")) return "IPM.Schedule.Meeting.Request";
    return "IPM.Note";
}

// ================================================================ MIME -> MAPI-style properties

const Props = struct {
    a: Allocator,
    list: std.ArrayList(pst.Prop) = .empty,

    fn add(self: *Props, id: u16, ptype: u16, data: []const u8) void {
        self.list.append(self.a, .{ .id = id, .ptype = ptype, .data = data }) catch {};
    }
    fn str(self: *Props, id: u16, s: []const u8) void {
        if (s.len == 0) return;
        self.add(id, pst.PT.unicode, utf16le(self.a, s) catch return);
    }
    fn bin(self: *Props, id: u16, d: []const u8) void {
        self.add(id, pst.PT.binary, d);
    }
    fn int(self: *Props, id: u16, v: i64) void {
        const b = self.a.alloc(u8, 4) catch return;
        std.mem.writeInt(i32, b[0..4], @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32))), .little);
        self.add(id, pst.PT.int32, b);
    }
    fn boolean(self: *Props, id: u16, v: bool) void {
        const b = self.a.alloc(u8, 1) catch return;
        b[0] = @intFromBool(v);
        self.add(id, pst.PT.boolean, b);
    }
    fn time(self: *Props, id: u16, t: ?i64) void {
        const v = t orelse return;
        if (v < -11_644_473_600) return;
        const b = self.a.alloc(u8, 8) catch return;
        std.mem.writeInt(u64, b[0..8], @intCast((v + 11_644_473_600) * 10_000_000), .little);
        self.add(id, pst.PT.systime, b);
    }
};

fn utf16le(a: Allocator, s: []const u8) ![]u8 {
    const src = if (std.unicode.utf8ValidateSlice(s)) s else try mime.cp1252ToUtf8(a, s);
    const w = try std.unicode.utf8ToUtf16LeAlloc(a, src);
    return std.mem.sliceAsBytes(w);
}

/// Build a pst.Message (MAPI-style properties) from a parsed MIME message.
fn synthesize(a: Allocator, id: u32, m: mime.Message, size: usize, s: pst.MessageSummary) !pst.Message {
    const T = pst.Tag;
    var p: Props = .{ .a = a };
    const h = m.headers;
    const from = mime.parseAddresses(a, h.get("from") orelse "");
    const sender = mime.parseAddresses(a, h.get("sender") orelse "");
    const f0: mime.Address = if (from.len > 0) from[0] else .{ .name = "", .email = "" };
    const s0: mime.Address = if (sender.len > 0) sender[0] else f0;
    const to = mime.parseAddresses(a, h.get("to") orelse "");
    const cc = mime.parseAddresses(a, h.get("cc") orelse "");
    const bcc = mime.parseAddresses(a, h.get("bcc") orelse "");

    p.str(T.message_class, s.message_class);
    p.str(T.subject, mime.decodeHeader(a, h.get("subject") orelse ""));
    p.str(T.sent_repr_name, if (f0.name.len > 0) f0.name else f0.email);
    p.str(T.sent_repr_email, f0.email);
    p.str(T.sent_repr_smtp, f0.email);
    if (f0.email.len > 0) p.str(T.sent_repr_addrtype, "SMTP");
    p.str(T.sender_name, if (s0.name.len > 0) s0.name else s0.email);
    p.str(T.sender_email, s0.email);
    p.str(T.sender_smtp, s0.email);
    if (s0.email.len > 0) p.str(T.sender_addrtype, "SMTP");
    p.str(T.display_to, mime.displayList(a, to));
    p.str(T.display_cc, mime.displayList(a, cc));
    p.str(T.display_bcc, mime.displayList(a, bcc));
    p.time(T.client_submit_time, if (h.get("date")) |d| mime.parseDate(d) else null);
    p.time(T.delivery_time, s.delivery_time);
    p.str(T.transport_headers, mime.toUtf8(a, "", m.head));
    p.str(T.internet_message_id, std.mem.trim(u8, h.get("message-id") orelse "", " \t"));
    p.str(T.body, m.text);
    if (m.html.len > 0) {
        p.bin(T.body_html, m.html);
        p.int(T.internet_cpid, 65001); // the HTML body has been converted to UTF-8
    }
    p.int(T.message_size, @intCast(@min(size, std.math.maxInt(i32))));
    p.int(T.message_flags, s.flags orelse MSGFLAG_READ);
    p.boolean(T.has_attachments, m.attachments.len > 0);

    var recips: std.ArrayList(pst.Recipient) = .empty;
    inline for (.{ .{ to, 1 }, .{ cc, 2 }, .{ bcc, 3 } }) |grp| {
        for (grp[0]) |ad| {
            var rp: Props = .{ .a = a };
            rp.int(T.recipient_type, grp[1]);
            rp.str(T.display_name, if (ad.name.len > 0) ad.name else ad.email);
            rp.str(T.email_address, ad.email);
            rp.str(T.smtp_address, ad.email);
            rp.str(T.addrtype, "SMTP");
            try recips.append(a, .{ .kind = grp[1], .name = if (ad.name.len > 0) ad.name else ad.email, .email = ad.email, .addrtype = "SMTP", .props = rp.list.items });
        }
    }

    var atts: std.ArrayList(pst.Attachment) = .empty;
    for (m.attachments, 0..) |att, k| {
        var ap: Props = .{ .a = a };
        const method: i64 = if (att.embedded != null) 5 else 1;
        ap.int(T.attach_method, method);
        ap.str(T.attach_long_filename, att.filename);
        ap.str(T.attach_filename, att.filename);
        ap.str(T.display_name, att.filename);
        ap.str(T.attach_mime_tag, att.mime);
        ap.str(T.attach_content_id, att.content_id);
        ap.int(T.attach_size, @intCast(@min(att.data.len, std.math.maxInt(i32))));
        var embedded: ?*pst.Message = null;
        if (att.embedded) |inner| {
            ap.add(T.attach_data, pst.PT.object, &.{});
            const em = try a.create(pst.Message);
            const isum: pst.MessageSummary = .{ .nid = id, .subject = "", .from = "", .to = "", .cc = "", .message_class = "IPM.Note", .delivery_time = receivedDate(inner.headers), .submit_time = null, .modified_time = null, .size = null, .flags = null };
            em.* = try synthesize(a, id, inner.*, att.data.len, isum);
            embedded = em;
        } else ap.bin(T.attach_data, att.data);
        try atts.append(a, .{
            .sub_nid = @intCast(k),
            .filename = att.filename,
            .mime = att.mime,
            .content_id = att.content_id,
            .method = method,
            .size = @intCast(att.data.len),
            .pc = .{ .props = ap.list.items },
            .node = null,
            .embedded = embedded,
        });
    }
    return .{ .nid = id, .node = null, .pc = .{ .props = p.list.items }, .recipients = recips.items, .attachments = atts.items };
}

// ================================================================ tests

const testing = std.testing;

test "From_ line detection" {
    try testing.expect(isFromLine("From user@x.com  Sun Apr 29 12:15:30 2007\nReturn-Path: <a@b>\n"));
    try testing.expect(isFromLine("From - Mon Jan 01 00:00:00 2024\r\nX-Mozilla-Status: 0001\r\n"));
    try testing.expect(isFromLine("From 1781234567890@xxx Sat Jan 01 00:00:00 +0000 2022\nX-GM-THRID: 1\n"));
    try testing.expect(!isFromLine("From the desk of the CEO, we are happy\nto announce\n"));
    try testing.expect(!isFromLine("From me Mon Jan 01 00:00:00 2024\n\nbody\n"));
    try testing.expect(!isFromLine("Subject: x\n"));
}

test "From_ unescaping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("a\nFrom here\n>From there\nb>From x\n", try unescapeFrom(a, "a\n>From here\n>>From there\nb>From x\n"));
    try testing.expectEqualStrings("plain\n", try unescapeFrom(a, "plain\n"));
}

test "Gmail labels" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const l = parseLabels(arena.allocator(), "Inbox,\"Work, Projects\",Category Promotions,=?UTF-8?Q?R=C3=A9sum=C3=A9?=,Opened");
    try testing.expectEqual(@as(usize, 5), l.len);
    try testing.expectEqualStrings("Work, Projects", l[1]);
    try testing.expectEqualStrings("Résumé", l[3]);
}

test "separator line stripping" {
    try testing.expectEqualStrings("a\r\nb\r\n", stripSeparator("a\r\nb\r\n\r\n"));
    try testing.expectEqualStrings("a\nb\n", stripSeparator("a\nb\n\n"));
    try testing.expectEqualStrings("a\nb\n", stripSeparator("a\nb\n"));
}
