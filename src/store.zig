//! A mail source opened read-only: an Outlook PST/OST or an MBOX file/folder.
//!
//! Front ends (GUI, CLI, search) talk to this instead of a specific format. Folders and messages
//! are addressed by u32 ids; messages come back as `pst.MessageSummary` / `pst.Message` for every
//! source type. PST-only tools (hidden-item scan, block verification, integrity log) are reached
//! through the `.pst` variant.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const pst = @import("pst.zig");
pub const mbox = @import("mbox.zig");
pub const mime = @import("mime.zig");
pub const multi = @import("multi.zig");
pub const recover = @import("recover.zig");

pub const Store = union(enum) {
    pst: *pst.Pst,
    mbox: *mbox.Mbox,
    /// Several PST/OST files merged into one mailbox (e.g. an Acronis export in parts).
    set: *multi.Set,

    /// Open `path`: a PST/OST (by signature), an mbox file, a directory (PST/OST parts are merged
    /// into one mailbox; otherwise MBOX mailboxes), or a ';'-separated list of PST/OST files.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !Store {
        if (std.mem.indexOfScalar(u8, path, ';') != null) {
            var list: std.ArrayList([]const u8) = .empty;
            defer list.deinit(gpa);
            var it = std.mem.tokenizeScalar(u8, path, ';');
            while (it.next()) |p| try list.append(gpa, std.mem.trim(u8, p, " \t\""));
            return openMany(gpa, io, list.items);
        }
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        if (st.kind == .directory) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const parts = try pstFilesIn(arena.allocator(), io, path);
            if (parts.len > 0) return openMany(gpa, io, parts);
            return .{ .mbox = try mbox.Mbox.open(gpa, io, path) };
        }
        if (isPstFile(io, path)) return .{ .pst = try pst.Pst.open(gpa, io, path) };
        if (mbox.isMboxFile(io, path)) return .{ .mbox = try mbox.Mbox.open(gpa, io, path) };
        return error.NotMailbox;
    }

    /// Open several files: one file opens normally; several PST/OST files become one merged mailbox.
    pub fn openMany(gpa: Allocator, io: Io, paths: []const []const u8) anyerror!Store {
        if (paths.len == 0) return error.NotMailbox;
        if (paths.len == 1) return open(gpa, io, paths[0]);
        for (paths) |p| if (!isPstFile(io, p)) return error.MixedSources;
        return .{ .set = try multi.Set.open(gpa, io, paths) };
    }

    fn isPstFile(io: Io, path: []const u8) bool {
        var sig: [4]u8 = undefined;
        const f = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return false;
        defer f.close(io);
        const n = f.readPositionalAll(io, &sig, 0) catch return false;
        return n == 4 and std.mem.eql(u8, &sig, "!BDN");
    }

    /// PST/OST files directly inside a directory.
    fn pstFilesIn(a: Allocator, io: Io, dir_path: []const u8) ![]const []const u8 {
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var out: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file) continue;
            if (!std.ascii.endsWithIgnoreCase(e.name, ".pst") and !std.ascii.endsWithIgnoreCase(e.name, ".ost")) continue;
            const full = try std.fs.path.join(a, &.{ dir_path, e.name });
            if (isPstFile(io, full)) try out.append(a, full);
        }
        return out.items;
    }

    pub fn close(self: Store) void {
        switch (self) {
            inline else => |s| s.close(),
        }
    }

    pub fn isPst(self: Store) bool {
        return self == .pst;
    }

    pub const PstPart = struct { name: []const u8, file: *pst.Pst };

    /// The PST/OST files behind the source (one, several for a merged set, none for MBOX) -
    /// for checksum verification and the integrity log.
    pub fn pstParts(self: Store, a: Allocator, path: []const u8) ![]PstPart {
        switch (self) {
            .pst => |p| {
                const out = try a.alloc(PstPart, 1);
                out[0] = .{ .name = std.fs.path.basename(path), .file = p };
                return out;
            },
            .set => |s| {
                const out = try a.alloc(PstPart, s.parts.len);
                for (out, s.parts) |*o, p| o.* = .{ .name = p.name, .file = p.file };
                return out;
            },
            .mbox => return &.{},
        }
    }

    pub const Recovery = struct {
        deleted: []pst.MessageSummary,
        versions: []pst.MessageSummary,
        stale_node_pages: usize = 0,
        stale_block_pages: usize = 0,
        blocks: usize = 0,
    };

    /// Recover items from stale index pages of every PST/OST part (see recover.zig). The returned
    /// summaries carry ids that load through this store. MBOX sources return nothing (deleted
    /// Thunderbird messages that are still in the file are already marked in the lists).
    pub fn recoverDeleted(self: Store, a: Allocator, path: []const u8, progress: ?*const fn (done: u64, total: u64) void) !Recovery {
        var deleted: std.ArrayList(pst.MessageSummary) = .empty;
        var versions: std.ArrayList(pst.MessageSummary) = .empty;
        var res: Recovery = .{ .deleted = &.{}, .versions = &.{} };
        for (try self.pstParts(a, path), 0..) |part, i| {
            const r = try recover.scan(a, part.file, progress);
            res.stale_node_pages += r.stale_node_pages;
            res.stale_block_pages += r.stale_block_pages;
            res.blocks += r.blocks_found;
            for (r.items) |it| {
                var s = it.summary;
                if (self == .set) {
                    s.nid = self.set.packId(@intCast(i), it.nid);
                    s.note = try std.fmt.allocPrint(a, "{s}: {s}", .{ part.name, s.note });
                }
                try (if (it.kind == .deleted) &deleted else &versions).append(a, s);
            }
        }
        res.deleted = deleted.items;
        res.versions = versions.items;
        return res;
    }

    pub fn rootFolder(self: Store) u32 {
        return switch (self) {
            .pst => pst.NID.root_folder,
            .mbox => |m| m.rootFolder(),
            .set => |s| s.rootFolder(),
        };
    }

    pub fn folderInfo(self: Store, a: Allocator, id: u32) !pst.FolderInfo {
        return switch (self) {
            .pst => |p| pst.folderInfo(a, p, id),
            .mbox => |m| m.folderInfo(a, id),
            .set => |s| s.folderInfo(a, id),
        };
    }

    pub fn subFolders(self: Store, a: Allocator, id: u32) ![]u32 {
        return switch (self) {
            .pst => |p| pst.subFolders(a, p, id),
            .mbox => |m| m.subFolders(a, id),
            .set => |s| s.subFolders(a, id),
        };
    }

    pub fn folderMessages(self: Store, a: Allocator, id: u32) ![]pst.MessageSummary {
        return switch (self) {
            .pst => |p| pst.folderMessages(a, p, id),
            .mbox => |m| m.folderMessages(a, id),
            .set => |s| s.folderMessages(a, id),
        };
    }

    pub fn loadMessage(self: Store, a: Allocator, id: u32) !pst.Message {
        return switch (self) {
            .pst => |p| pst.loadMessage(a, p, id),
            .mbox => |m| m.loadMessage(a, id),
            .set => |s| s.loadMessage(a, id),
        };
    }

    /// Properties and recipients only (no attachment data) - for search and triage.
    pub fn loadMessageHeaders(self: Store, a: Allocator, id: u32) !pst.Message {
        return switch (self) {
            .pst => |p| pst.loadMessageHeaders(a, p, id),
            .mbox => |m| m.loadMessageHeaders(a, id),
            .set => |s| s.loadMessageHeaders(a, id),
        };
    }

    /// The message exactly as stored (MBOX), for byte-exact .eml export; null for PST items.
    pub fn rawMessage(self: Store, a: Allocator, id: u32) !?[]const u8 {
        return switch (self) {
            .pst, .set => null,
            .mbox => |m| try m.rawMessage(a, id),
        };
    }

    pub fn describe(self: Store, buf: []u8) []const u8 {
        return switch (self) {
            inline else => |s| s.describe(buf),
        };
    }

    /// Integrity problems found so far (PST/OST only; MBOX has no checksums).
    pub fn issueCount(self: Store) usize {
        return switch (self) {
            .pst => |p| p.issues.items.len,
            .mbox => 0,
            .set => |s| s.issueCount(),
        };
    }

    pub fn totalSize(self: Store) u64 {
        return switch (self) {
            .pst => |p| p.file_size,
            .mbox => |m| m.totalSize(),
            .set => |s| s.totalSize(),
        };
    }

    pub const SourceFile = struct { path: []const u8, size: u64 };

    /// The files that make up the source, for hashing and reports.
    pub fn sourceFiles(self: Store, a: Allocator, path: []const u8) ![]SourceFile {
        switch (self) {
            .pst => |p| {
                const out = try a.alloc(SourceFile, 1);
                out[0] = .{ .path = path, .size = p.file_size };
                return out;
            },
            .mbox => |m| {
                const out = try a.alloc(SourceFile, m.sources.items.len);
                for (out, m.sources.items) |*o, s| o.* = .{ .path = s.path, .size = s.size };
                return out;
            },
            .set => |s| {
                const out = try a.alloc(SourceFile, s.parts.len);
                for (out, s.parts) |*o, p| o.* = .{ .path = p.path, .size = p.file.file_size };
                return out;
            },
        }
    }

    /// SHA-256 (lower-case hex) of one source file, streamed.
    pub fn sha256File(gpa: Allocator, io: Io, path: []const u8) ![64]u8 {
        const f = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer f.close(io);
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        const buf = try gpa.alloc(u8, 8 * 1024 * 1024);
        defer gpa.free(buf);
        var off: u64 = 0;
        while (true) {
            const n = try f.readPositionalAll(io, buf, off);
            if (n == 0) break;
            h.update(buf[0..n]);
            off += n;
        }
        var d: [32]u8 = undefined;
        h.final(&d);
        return std.fmt.bytesToHex(d, .lower);
    }
};

/// Human-readable reason for an `open` failure.
pub fn openErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.NotMailbox => "Not a recognised mail file: expected an Outlook PST/OST, an MBOX file, or a folder of MBOX mailboxes (Thunderbird / Apple Mail).",
        error.NotMbox => "No MBOX mailboxes found (files must start with a \"From \" separator line).",
        error.MixedSources => "Several files can be opened together only when they are all PST/OST files (they are merged into one mailbox).",
        error.TooManyParts => "Too many files: at most 126 PST/OST parts can be merged.",
        else => pst.Pst.openErrorText(e),
    };
}
