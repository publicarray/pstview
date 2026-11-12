//! Folder glyph kinds and the mapping from a mailbox folder to its glyph (portable; each GUI draws
//! the glyphs its own way).

const std = @import("std");

pub const Glyph = enum(u8) { folder, mailbox, inbox, sent, drafts, deleted, junk, archive, calendar, contacts, tasks, notes, journal, search, hidden, recovered, document };

/// Glyph for a mailbox folder, from its container class and well-known names.
pub fn folderGlyph(name: []const u8, class: []const u8) Glyph {
    const ic = std.ascii.startsWithIgnoreCase;
    if (ic(class, "IPF.Appointment")) return .calendar;
    if (ic(class, "IPF.Contact")) return .contacts;
    if (ic(class, "IPF.Task")) return .tasks;
    if (ic(class, "IPF.StickyNote")) return .notes;
    if (ic(class, "IPF.Journal")) return .journal;
    const eq = std.ascii.eqlIgnoreCase;
    const names = [_]struct { []const u8, Glyph }{
        .{ "Inbox", .inbox },           .{ "Sent Items", .sent },           .{ "Sent", .sent },
        .{ "Sent Mail", .sent },        .{ "Outbox", .sent },               .{ "Drafts", .drafts },
        .{ "Deleted Items", .deleted }, .{ "Trash", .deleted },             .{ "Bin", .deleted },
        .{ "Junk Email", .junk },       .{ "Junk E-mail", .junk },          .{ "Junk", .junk },
        .{ "Spam", .junk },             .{ "Archive", .archive },           .{ "Calendar", .calendar },
        .{ "Contacts", .contacts },     .{ "Tasks", .tasks },               .{ "Notes", .notes },
        .{ "Journal", .journal },       .{ "Recoverable Items", .deleted }, .{ "Search Folders", .search },
        .{ "Finder", .search },
    };
    for (names) |n| if (eq(name, n[0])) return n[1];
    return .folder;
}
