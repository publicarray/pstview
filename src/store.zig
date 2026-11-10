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

pub const Store = union(enum) {
    pst: *pst.Pst,
    mbox: *mbox.Mbox,

    /// Open `path`: a PST/OST (by signature), an mbox file, or a directory of mailboxes.
    pub fn open(gpa: Allocator, io: Io, path: []const u8) !Store {
        const st = try Io.Dir.cwd().statFile(io, path, .{});
        if (st.kind == .directory) return .{ .mbox = try mbox.Mbox.open(gpa, io, path) };
        var sig: [4]u8 = undefined;
        {
            const f = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
            defer f.close(io);
            const n = try f.readPositionalAll(io, &sig, 0);
            if (n == 4 and std.mem.eql(u8, &sig, "!BDN")) return .{ .pst = try pst.Pst.open(gpa, io, path) };
        }
        if (mbox.isMboxFile(io, path)) return .{ .mbox = try mbox.Mbox.open(gpa, io, path) };
        return error.NotMailbox;
    }

    pub fn close(self: Store) void {
        switch (self) {
            inline else => |s| s.close(),
        }
    }

    pub fn isPst(self: Store) bool {
        return self == .pst;
    }

    pub fn rootFolder(self: Store) u32 {
        return switch (self) {
            .pst => pst.NID.root_folder,
            .mbox => |m| m.rootFolder(),
        };
    }

    pub fn folderInfo(self: Store, a: Allocator, id: u32) !pst.FolderInfo {
        return switch (self) {
            .pst => |p| pst.folderInfo(a, p, id),
            .mbox => |m| m.folderInfo(a, id),
        };
    }

    pub fn subFolders(self: Store, a: Allocator, id: u32) ![]u32 {
        return switch (self) {
            .pst => |p| pst.subFolders(a, p, id),
            .mbox => |m| m.subFolders(a, id),
        };
    }

    pub fn folderMessages(self: Store, a: Allocator, id: u32) ![]pst.MessageSummary {
        return switch (self) {
            .pst => |p| pst.folderMessages(a, p, id),
            .mbox => |m| m.folderMessages(a, id),
        };
    }

    pub fn loadMessage(self: Store, a: Allocator, id: u32) !pst.Message {
        return switch (self) {
            .pst => |p| pst.loadMessage(a, p, id),
            .mbox => |m| m.loadMessage(a, id),
        };
    }

    /// Properties and recipients only (no attachment data) - for search and triage.
    pub fn loadMessageHeaders(self: Store, a: Allocator, id: u32) !pst.Message {
        return switch (self) {
            .pst => |p| pst.loadMessageHeaders(a, p, id),
            .mbox => |m| m.loadMessageHeaders(a, id),
        };
    }

    /// The message exactly as stored (MBOX), for byte-exact .eml export; null for PST items.
    pub fn rawMessage(self: Store, a: Allocator, id: u32) !?[]const u8 {
        return switch (self) {
            .pst => null,
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
        };
    }

    pub fn totalSize(self: Store) u64 {
        return switch (self) {
            .pst => |p| p.file_size,
            .mbox => |m| m.totalSize(),
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
        else => pst.Pst.openErrorText(e),
    };
}
