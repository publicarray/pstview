//! Message search and per-folder index.
//!
//! Query syntax (case-insensitive, all terms must match):
//!   word                  sender, any recipient, subject
//!   from:  sender:        sender name / address        e.g. from:example.com  from:*@example.com
//!   to:  recipient:       any recipient (To, Cc, Bcc)
//!   cc:   bcc:            that recipient type only
//!   subject:              subject
//!   risk:                 header-analysis result       e.g. risk:high  risk:impersonation
//!   "quoted phrase"       keeps words together; * and ? are wildcards
//! A value that looks like a domain (example.com, @example.com, *@example.com)
//! matches addresses in that domain or its sub-domains.

const std = @import("std");
const pst = @import("pst.zig");
const headers = @import("headers.zig");
const Store = @import("store.zig").Store;
const Allocator = std.mem.Allocator;

pub const Fields = struct {
    from: []const u8 = "",
    to: []const u8 = "",
    cc: []const u8 = "",
    bcc: []const u8 = "",
    subject: []const u8 = "",
    risk: []const u8 = "",
};

pub const Field = enum { any, from, to, cc, bcc, subject, risk };
pub const Term = struct { field: Field, text: []const u8 };

/// Searchable fields from a loaded message (sender name + all sender addresses, recipients by type).
pub fn fieldsFromMessage(a: Allocator, m: *const pst.Message, s: pst.MessageSummary) Fields {
    var out: Fields = .{ .from = s.from, .to = s.to, .cc = s.cc, .subject = s.subject };
    var from: std.ArrayList(u8) = .empty;
    inline for (.{ pst.Tag.sent_repr_name, pst.Tag.sent_repr_email, pst.Tag.sent_repr_smtp, pst.Tag.sender_name, pst.Tag.sender_email, pst.Tag.sender_smtp }) |t| {
        const v = m.pc.string(a, t) catch "";
        if (v.len > 0) {
            from.appendSlice(a, v) catch {};
            from.appendSlice(a, " ; ") catch {};
        }
    }
    if (from.items.len > 0) out.from = from.items;
    var lists = [3]std.ArrayList(u8){ .empty, .empty, .empty };
    for (m.recipients) |r| {
        const k: usize = if (r.kind >= 1 and r.kind <= 3) @intCast(r.kind - 1) else 0;
        lists[k].print(a, "{s} <{s}> ; ", .{ r.name, r.email }) catch {};
    }
    const disp = [3]u16{ pst.Tag.display_to, pst.Tag.display_cc, pst.Tag.display_bcc };
    for (&lists, disp) |*l, tag| {
        const d = m.pc.string(a, tag) catch "";
        if (d.len > 0) l.appendSlice(a, d) catch {};
    }
    out.to = lists[0].items;
    out.cc = lists[1].items;
    out.bcc = lists[2].items;
    const subj = m.subject(a) catch "";
    if (subj.len > 0) out.subject = subj;
    return out;
}

pub fn parse(a: Allocator, q: []const u8) []Term {
    var terms: std.ArrayList(Term) = .empty;
    var i: usize = 0;
    while (i < q.len) {
        while (i < q.len and q[i] == ' ') i += 1;
        if (i >= q.len) break;
        var field: Field = .any;
        const prefixes = [_]struct { p: []const u8, f: Field }{
            .{ .p = "from:", .f = .from },       .{ .p = "sender:", .f = .from }, .{ .p = "to:", .f = .to },
            .{ .p = "recipient:", .f = .to },    .{ .p = "cc:", .f = .cc },       .{ .p = "bcc:", .f = .bcc },
            .{ .p = "subject:", .f = .subject }, .{ .p = "risk:", .f = .risk },
        };
        for (prefixes) |p| if (std.ascii.startsWithIgnoreCase(q[i..], p.p)) {
            field = p.f;
            i += p.p.len;
            break;
        };
        var text: []const u8 = "";
        if (i < q.len and q[i] == '"') {
            const e = std.mem.indexOfScalarPos(u8, q, i + 1, '"') orelse q.len;
            text = q[i + 1 .. e];
            i = @min(e + 1, q.len);
        } else {
            const s = i;
            while (i < q.len and q[i] != ' ') i += 1;
            text = q[s..i];
        }
        if (text.len > 0) terms.append(a, .{ .field = field, .text = text }) catch break;
    }
    return terms.items;
}

/// Case-insensitive glob with * and ?.
fn glob(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (si < s.len) {
        if (pi < p.len and (p[pi] == '?' or std.ascii.toLower(p[pi]) == std.ascii.toLower(s[si]))) {
            pi += 1;
            si += 1;
        } else if (pi < p.len and p[pi] == '*') {
            star = pi;
            pi += 1;
            mark = si;
        } else if (star) |st| {
            pi = st + 1;
            mark += 1;
            si = mark;
        } else return false;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

const token_seps = " \t;,<>\"'()[]";

/// Domain-style term? -> the domain part ("example.com" from "*@example.com" etc.)
fn domainTerm(t: []const u8) ?[]const u8 {
    var d = t;
    if (std.mem.startsWith(u8, d, "*@")) d = d[2..] else if (std.mem.startsWith(u8, d, "@")) d = d[1..] else if (std.mem.indexOfScalar(u8, d, '@') != null) return null;
    if (d.len < 3 or std.mem.indexOfScalar(u8, d, '.') == null) return null;
    for (d) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return null;
    return d;
}

fn has(hay: []const u8, t: []const u8) bool {
    // domain match against every address in the field
    if (domainTerm(t)) |dom| {
        var it = std.mem.tokenizeAny(u8, hay, token_seps);
        while (it.next()) |tok| {
            if (std.mem.indexOfScalar(u8, tok, '@')) |at| if (headers.domainIs(tok[at + 1 ..], dom)) return true;
        }
        // plain term without @ also matches anywhere as text (e.g. a domain in a display name)
        if (t[0] != '@' and t[0] != '*') return std.ascii.indexOfIgnoreCase(hay, t) != null;
        return false;
    }
    if (std.mem.indexOfAny(u8, t, "*?") != null) {
        var it = std.mem.tokenizeAny(u8, hay, token_seps);
        while (it.next()) |tok| if (glob(t, tok)) return true;
        return glob(t, hay);
    }
    return std.ascii.indexOfIgnoreCase(hay, t) != null;
}

pub fn matches(f: Fields, terms: []const Term) bool {
    for (terms) |t| {
        const ok = switch (t.field) {
            .from => has(f.from, t.text),
            .to => has(f.to, t.text) or has(f.cc, t.text) or has(f.bcc, t.text),
            .cc => has(f.cc, t.text),
            .bcc => has(f.bcc, t.text),
            .subject => has(f.subject, t.text),
            .risk => has(f.risk, t.text),
            .any => has(f.from, t.text) or has(f.to, t.text) or has(f.cc, t.text) or has(f.bcc, t.text) or has(f.subject, t.text),
        };
        if (!ok) return false;
    }
    return true;
}

/// Everything known about a folder's messages for search and header triage.
pub const FolderIndex = struct {
    fields: []Fields,
    analyses: []headers.Analysis,
    ctx: headers.Context,
};

/// Organisation knowledge from the WHOLE mailbox: the main recipient domain and the display names
/// of everyone with an address in it (senders and recipients in every folder, incl. Sent Items).
pub fn buildMailboxContext(a: Allocator, f: Store, progress: ?*const fn (done: usize, total: usize) void) headers.Context {
    var dir: headers.DirectoryBuilder = .{};
    var queue: std.ArrayList(u32) = .empty;
    queue.append(a, f.rootFolder()) catch return .{};
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var done: usize = 0;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const fnid = queue.items[qi];
        if (seen.contains(fnid)) continue;
        seen.put(a, fnid, {}) catch {};
        const kids = f.subFolders(a, fnid) catch &.{};
        for (kids) |k| queue.append(a, k) catch {};
        var tmp = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tmp.deinit();
        const ta = tmp.allocator();
        const msgs = f.folderMessages(ta, fnid) catch continue;
        for (msgs) |s| {
            const m = f.loadMessageHeaders(ta, s.nid) catch continue;
            // copy what we keep into the long-lived allocator
            for (m.recipients) |r| {
                dir.addRecipientDomain(a, a.dupe(u8, r.email) catch continue);
                dir.addPerson(a, a.dupe(u8, r.name) catch continue, a.dupe(u8, r.email) catch continue);
            }
            const sn = m.senderName(ta) catch "";
            const se = m.senderEmail(ta) catch "";
            dir.addPerson(a, a.dupe(u8, sn) catch continue, a.dupe(u8, se) catch continue);
            done += 1;
            if (progress) |p| if (done % 100 == 0) p(done, 0);
        }
    }
    const names = a.create(std.StringHashMapUnmanaged([]const u8)) catch return .{};
    names.* = .empty;
    return dir.finish(a, names);
}

/// Load every message's headers/recipients once, build the organisation directory
/// (or use `mailbox_ctx` when given), then analyse each message's internet headers.
pub fn buildIndex(a: Allocator, f: Store, msgs: []const pst.MessageSummary, progress: ?*const fn (done: usize, total: usize) void) FolderIndex {
    return buildIndexCtx(a, f, msgs, progress, null);
}

pub fn buildIndexCtx(a: Allocator, f: Store, msgs: []const pst.MessageSummary, progress: ?*const fn (done: usize, total: usize) void, mailbox_ctx: ?headers.Context) FolderIndex {
    const fields = a.alloc(Fields, msgs.len) catch return .{ .fields = &.{}, .analyses = &.{}, .ctx = .{} };
    const inputs = a.alloc(headers.Input, msgs.len) catch return .{ .fields = &.{}, .analyses = &.{}, .ctx = .{} };
    var dir: headers.DirectoryBuilder = .{};
    for (msgs, 0..) |s, i| {
        if (f.loadMessageHeaders(a, s.nid)) |m| {
            fields[i] = fieldsFromMessage(a, &m, s);
            inputs[i] = headers.inputFromMessage(a, &m);
            for (m.recipients) |r| {
                dir.addRecipientDomain(a, r.email);
                dir.addPerson(a, r.name, r.email);
            }
            dir.addPerson(a, m.senderName(a) catch "", m.senderEmail(a) catch "");
        } else |_| {
            fields[i] = .{ .from = s.from, .to = s.to, .cc = s.cc, .subject = s.subject };
            inputs[i] = .{ .headers = "", .sender_name = s.from, .sender_email = "", .recipient_addrs = &.{} };
        }
        if (progress) |p| if (i % 50 == 0) p(i, msgs.len);
    }
    const ctx = mailbox_ctx orelse blk: {
        const names = a.create(std.StringHashMapUnmanaged([]const u8)) catch return .{ .fields = fields, .analyses = &.{}, .ctx = .{} };
        names.* = .empty;
        break :blk dir.finish(a, names);
    };
    const analyses = a.alloc(headers.Analysis, msgs.len) catch return .{ .fields = fields, .analyses = &.{}, .ctx = ctx };
    for (inputs, 0..) |in, i| {
        analyses[i] = headers.analyse(a, in, ctx);
        const an = analyses[i];
        fields[i].risk = std.fmt.allocPrint(a, "{s} {s}", .{ if (an.risk == .none) "none" else an.risk.label(), an.summary() }) catch "";
    }
    return .{ .fields = fields, .analyses = analyses, .ctx = ctx };
}
