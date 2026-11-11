//! Every MAPI property of an item (message, recipients, attachments) with its tag, name and
//! decoded value - the raw view of tools like PST Walker. Named properties (0x8000+) are resolved
//! through the PST's name-to-id map. Portable; output as an HTML page or text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pst = @import("pst.zig");
const nm = @import("namemap.zig");

pub const TimeFmt = *const fn (buf: []u8, t: ?i64) []const u8;

/// Common MAPI property names ([MS-OXPROPS] canonical names without the "PidTag" prefix).
const names = [_]struct { u16, []const u8 }{
    .{ 0x0001, "TemplateData" },                    .{ 0x0002, "AlternateRecipientAllowed" },         .{ 0x0017, "Importance" },
    .{ 0x001A, "MessageClass" },                    .{ 0x0023, "OriginatorDeliveryReportRequested" }, .{ 0x0026, "Priority" },
    .{ 0x0029, "ReadReceiptRequested" },            .{ 0x002B, "RecipientReassignmentProhibited" },   .{ 0x002E, "OriginalSensitivity" },
    .{ 0x0036, "Sensitivity" },                     .{ 0x0037, "Subject" },                           .{ 0x0039, "ClientSubmitTime" },
    .{ 0x003B, "SentRepresentingSearchKey" },       .{ 0x003D, "SubjectPrefix" },                     .{ 0x003F, "ReceivedByEntryId" },
    .{ 0x0040, "ReceivedByName" },                  .{ 0x0041, "SentRepresentingEntryId" },           .{ 0x0042, "SentRepresentingName" },
    .{ 0x0043, "ReceivedRepresentingEntryId" },     .{ 0x0044, "ReceivedRepresentingName" },          .{ 0x0047, "MessageSubmissionId" },
    .{ 0x004F, "ReplyRecipientEntries" },           .{ 0x0050, "ReplyRecipientNames" },               .{ 0x0051, "ReceivedBySearchKey" },
    .{ 0x0052, "ReceivedRepresentingSearchKey" },   .{ 0x0057, "MessageToMe" },                       .{ 0x0058, "MessageCcMe" },
    .{ 0x005E, "CreatorEntryId" },                  .{ 0x0060, "StartDate" },                         .{ 0x0061, "EndDate" },
    .{ 0x0064, "SentRepresentingAddressType" },     .{ 0x0065, "SentRepresentingEmailAddress" },      .{ 0x0070, "ConversationTopic" },
    .{ 0x0071, "ConversationIndex" },               .{ 0x0075, "ReceivedByAddressType" },             .{ 0x0076, "ReceivedByEmailAddress" },
    .{ 0x0077, "ReceivedRepresentingAddressType" }, .{ 0x0078, "ReceivedRepresentingEmailAddress" },  .{ 0x007D, "TransportMessageHeaders" },
    .{ 0x0C15, "RecipientType" },                   .{ 0x0C17, "ReplyRequested" },                    .{ 0x0C19, "SenderEntryId" },
    .{ 0x0C1A, "SenderName" },                      .{ 0x0C1D, "SenderSearchKey" },                   .{ 0x0C1E, "SenderAddressType" },
    .{ 0x0C1F, "SenderEmailAddress" },              .{ 0x0E01, "DeleteAfterSubmit" },                 .{ 0x0E02, "DisplayBcc" },
    .{ 0x0E03, "DisplayCc" },                       .{ 0x0E04, "DisplayTo" },                         .{ 0x0E06, "MessageDeliveryTime" },
    .{ 0x0E07, "MessageFlags" },                    .{ 0x0E08, "MessageSize" },                       .{ 0x0E0F, "Responsibility" },
    .{ 0x0E12, "MessageRecipients" },               .{ 0x0E13, "MessageAttachments" },                .{ 0x0E17, "MessageStatus" },
    .{ 0x0E1B, "HasAttachments" },                  .{ 0x0E1D, "NormalizedSubject" },                 .{ 0x0E1F, "RtfInSync" },
    .{ 0x0E20, "AttachSize" },                      .{ 0x0E21, "AttachNumber" },                      .{ 0x0E28, "PrimarySendAccount" },
    .{ 0x0E29, "NextSendAccount" },                 .{ 0x0E2B, "ToDoItemFlags" },                     .{ 0x0E79, "TrustSender" },
    .{ 0x0FF4, "Access" },                          .{ 0x0FF7, "AccessLevel" },                       .{ 0x0FF8, "MappingSignature" },
    .{ 0x0FF9, "RecordKey" },                       .{ 0x0FFB, "StoreEntryId" },                      .{ 0x0FFE, "ObjectType" },
    .{ 0x0FFF, "EntryId" },                         .{ 0x1000, "Body" },                              .{ 0x1009, "RtfCompressed" },
    .{ 0x1013, "BodyHtml" },                        .{ 0x1015, "BodyContentId" },                     .{ 0x1035, "InternetMessageId" },
    .{ 0x1039, "InternetReferences" },              .{ 0x1042, "InReplyToId" },                       .{ 0x1043, "ListHelp" },
    .{ 0x1044, "ListSubscribe" },                   .{ 0x1045, "ListUnsubscribe" },                   .{ 0x1080, "IconIndex" },
    .{ 0x1081, "LastVerbExecuted" },                .{ 0x1082, "LastVerbExecutionTime" },             .{ 0x1090, "FlagStatus" },
    .{ 0x1091, "FlagCompleteTime" },                .{ 0x1095, "FollowupIcon" },                      .{ 0x1096, "BlockStatus" },
    .{ 0x10C3, "ICalendarStartTime" },              .{ 0x10C4, "ICalendarEndTime" },                  .{ 0x10F4, "AttributeHidden" },
    .{ 0x10F6, "AttributeReadOnly" },               .{ 0x3001, "DisplayName" },                       .{ 0x3002, "AddressType" },
    .{ 0x3003, "EmailAddress" },                    .{ 0x3004, "Comment" },                           .{ 0x3007, "CreationTime" },
    .{ 0x3008, "LastModificationTime" },            .{ 0x300B, "SearchKey" },                         .{ 0x3010, "TargetEntryId" },
    .{ 0x3013, "ConversationId" },                  .{ 0x3016, "ConversationIndexTracking" },         .{ 0x3701, "AttachDataBinary/Object" },
    .{ 0x3702, "AttachEncoding" },                  .{ 0x3703, "AttachExtension" },                   .{ 0x3704, "AttachFilename" },
    .{ 0x3705, "AttachMethod" },                    .{ 0x3707, "AttachLongFilename" },                .{ 0x3708, "AttachPathname" },
    .{ 0x3709, "AttachRendering" },                 .{ 0x370A, "AttachTag" },                         .{ 0x370B, "RenderingPosition" },
    .{ 0x370E, "AttachMimeTag" },                   .{ 0x3712, "AttachContentId" },                   .{ 0x3713, "AttachContentLocation" },
    .{ 0x3714, "AttachFlags" },                     .{ 0x3716, "AttachContentDisposition" },          .{ 0x371D, "AttachmentLinkId" },
    .{ 0x3900, "DisplayType" },                     .{ 0x3905, "DisplayTypeEx" },                     .{ 0x39FE, "SmtpAddress" },
    .{ 0x3A00, "Account" },                         .{ 0x3A05, "Generation" },                        .{ 0x3A06, "GivenName" },
    .{ 0x3A08, "BusinessTelephoneNumber" },         .{ 0x3A09, "HomeTelephoneNumber" },               .{ 0x3A11, "Surname" },
    .{ 0x3A16, "CompanyName" },                     .{ 0x3A17, "Title" },                             .{ 0x3A18, "DepartmentName" },
    .{ 0x3A19, "OfficeLocation" },                  .{ 0x3A1C, "MobileTelephoneNumber" },             .{ 0x3A20, "TransmittableDisplayName" },
    .{ 0x3A24, "BusinessFaxNumber" },               .{ 0x3A26, "Country" },                           .{ 0x3A27, "Locality" },
    .{ 0x3A28, "StateOrProvince" },                 .{ 0x3A29, "StreetAddress" },                     .{ 0x3A2A, "PostalCode" },
    .{ 0x3A40, "SendRichInfo" },                    .{ 0x3A41, "WeddingAnniversary" },                .{ 0x3A42, "Birthday" },
    .{ 0x3A44, "MiddleName" },                      .{ 0x3A45, "DisplayNamePrefix" },                 .{ 0x3A4F, "Nickname" },
    .{ 0x3A51, "BusinessHomePage" },                .{ 0x3FDE, "InternetCodepage" },                  .{ 0x3FE0, "AccessControlListData" },
    .{ 0x3FF1, "MessageLocaleId" },                 .{ 0x3FF8, "CreatorName" },                       .{ 0x3FF9, "CreatorEntryId" },
    .{ 0x3FFA, "LastModifierName" },                .{ 0x3FFB, "LastModifierEntryId" },               .{ 0x3FFD, "MessageCodepage" },
    .{ 0x4019, "SenderFlags" },                     .{ 0x401A, "SentRepresentingFlags" },             .{ 0x5902, "InternetMailOverrideFormat" },
    .{ 0x5909, "MessageEditorFormat" },             .{ 0x5D01, "SenderSmtpAddress" },                 .{ 0x5D02, "SentRepresentingSmtpAddress" },
    .{ 0x5FF6, "RecipientDisplayName" },            .{ 0x5FF7, "RecipientEntryId" },                  .{ 0x5FFD, "RecipientFlags" },
    .{ 0x5FFF, "RecipientTrackStatus" },            .{ 0x6619, "UserEntryId" },                       .{ 0x67F2, "LtpRowId" },
    .{ 0x67F3, "LtpRowVer" },                       .{ 0x67FF, "PstPassword" },                       .{ 0x7FFA, "AttachmentLinkId" },
    .{ 0x7FFB, "ExceptionStartTime" },              .{ 0x7FFC, "ExceptionEndTime" },                  .{ 0x7FFD, "AttachmentFlags" },
    .{ 0x7FFE, "AttachmentHidden" },                .{ 0x7FFF, "AttachmentContactPhoto" },
};

pub fn tagName(id: u16) []const u8 {
    for (names) |n| if (n[0] == id) return n[1];
    return "";
}

pub fn typeName(t: u16) []const u8 {
    return switch (t) {
        pst.PT.int16 => "Int16",
        pst.PT.int32 => "Int32",
        pst.PT.float32 => "Float",
        pst.PT.float64 => "Double",
        pst.PT.currency => "Currency",
        pst.PT.apptime => "AppTime",
        pst.PT.err => "Error",
        pst.PT.boolean => "Boolean",
        pst.PT.object => "Object",
        pst.PT.int64 => "Int64",
        pst.PT.string8 => "String8",
        pst.PT.unicode => "Unicode",
        pst.PT.systime => "Time",
        pst.PT.guid => "Guid",
        pst.PT.binary => "Binary",
        pst.PT.mv_flag | pst.PT.unicode => "MV Unicode",
        pst.PT.mv_flag | pst.PT.string8 => "MV String8",
        pst.PT.mv_flag | pst.PT.int32 => "MV Int32",
        pst.PT.mv_flag | pst.PT.binary => "MV Binary",
        pst.PT.mv_flag | pst.PT.guid => "MV Guid",
        pst.PT.mv_flag | pst.PT.systime => "MV Time",
        else => "?",
    };
}

pub const Row = struct { tag: u32, name: []const u8, type: []const u8, value: []const u8 };

fn guidText(a: Allocator, g: []const u8) []const u8 {
    if (g.len < 16) return "";
    return std.fmt.allocPrint(a, "{{{x:0>8}-{x:0>4}-{x:0>4}-{x}-{x}}}", .{ pst.rd32(g, 0), pst.rd16(g, 4), pst.rd16(g, 6), g[8..10], g[10..16] }) catch "";
}

/// Name of a property, resolving named properties through the PST's map.
pub fn propName(a: Allocator, id: u16, map: nm.NameMap) []const u8 {
    if (id < 0x8000) return tagName(id);
    const e = map.describe(id) orelse return "(named, not in map)";
    const set = nm.guidName(e.guid);
    const set_txt = if (set.len > 0) set else guidText(a, &e.guid);
    if (e.dispid) |d| return std.fmt.allocPrint(a, "{s} : 0x{x:0>4}", .{ set_txt, d }) catch "";
    return std.fmt.allocPrint(a, "{s} : \"{s}\"", .{ set_txt, e.name }) catch "";
}

/// Human-readable value (strings in full up to 4 KB, binary as hex up to 256 bytes).
pub fn valueText(a: Allocator, p: pst.Prop, fmt_time: TimeFmt) []const u8 {
    const d = p.data;
    switch (p.ptype) {
        pst.PT.unicode, pst.PT.string8 => {
            const s = pst.propToString(a, p.ptype, d) catch "";
            return if (s.len > 4096) std.fmt.allocPrint(a, "{s} ... ({d} characters)", .{ s[0..4096], s.len }) catch s else s;
        },
        pst.PT.systime => {
            if (d.len < 8) return "";
            const t = pst.filetimeToUnix(pst.rd64(d, 0)) orelse return "(not set)";
            const buf = a.alloc(u8, 96) catch return "";
            var ub: [32]u8 = undefined;
            return std.fmt.allocPrint(a, "{s}  ({s} UTC)", .{ fmt_time(buf, t), pst.fmtTime(&ub, t, 0) }) catch "";
        },
        pst.PT.boolean => return if (d.len > 0 and d[0] != 0) "true" else "false",
        pst.PT.int16, pst.PT.int32, pst.PT.err, pst.PT.int64, pst.PT.currency => {
            const v = pst.propToInt(p.ptype, d) orelse return "";
            return std.fmt.allocPrint(a, "{d} (0x{x})", .{ v, @as(u64, @bitCast(v)) }) catch "";
        },
        pst.PT.float64, pst.PT.apptime => {
            if (d.len < 8) return "";
            const v: f64 = @bitCast(pst.rd64(d, 0));
            return std.fmt.allocPrint(a, "{d}", .{v}) catch "";
        },
        pst.PT.float32 => {
            if (d.len < 4) return "";
            const v: f32 = @bitCast(pst.rd32(d, 0));
            return std.fmt.allocPrint(a, "{d}", .{v}) catch "";
        },
        pst.PT.guid => return guidText(a, d),
        pst.PT.object => return "(embedded object / sub-node)",
        pst.PT.mv_flag | pst.PT.unicode, pst.PT.mv_flag | pst.PT.string8 => return @import("itemview.zig").multiString(a, p),
        else => {
            var out: std.ArrayList(u8) = .empty;
            out.print(a, "{d} bytes: ", .{d.len}) catch {};
            for (d[0..@min(d.len, 256)], 0..) |b, i| {
                if (i > 0 and i % 4 == 0) out.append(a, ' ') catch {};
                out.print(a, "{x:0>2}", .{b}) catch {};
            }
            if (d.len > 256) out.appendSlice(a, " ...") catch {};
            return out.items;
        },
    }
}

pub fn rowsOf(a: Allocator, props: []const pst.Prop, map: nm.NameMap, fmt_time: TimeFmt) []Row {
    const sorted = a.dupe(pst.Prop, props) catch return &.{};
    std.mem.sort(pst.Prop, sorted, {}, struct {
        fn lt(_: void, x: pst.Prop, y: pst.Prop) bool {
            return x.id < y.id;
        }
    }.lt);
    var out: std.ArrayList(Row) = .empty;
    for (sorted) |p| out.append(a, .{
        .tag = (@as(u32, p.id) << 16) | p.ptype,
        .name = propName(a, p.id, map),
        .type = typeName(p.ptype),
        .value = valueText(a, p, fmt_time),
    }) catch break;
    return out.items;
}

fn esc(a: Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| switch (c) {
        '<' => out.appendSlice(a, "&lt;") catch {},
        '>' => out.appendSlice(a, "&gt;") catch {},
        '&' => out.appendSlice(a, "&amp;") catch {},
        '"' => out.appendSlice(a, "&quot;") catch {},
        else => out.append(a, c) catch {},
    };
}

fn table(a: Allocator, out: *std.ArrayList(u8), title: []const u8, rows: []const Row) void {
    out.print(a, "<h2>{s} ({d})</h2><table><tr><th>Tag</th><th>Name</th><th>Type</th><th>Value</th></tr>", .{ title, rows.len }) catch {};
    for (rows) |r| {
        out.print(a, "<tr><td class=\"m\">0x{x:0>8}</td><td>", .{r.tag}) catch {};
        esc(a, out, r.name);
        out.print(a, "</td><td>{s}</td><td class=\"m v\">", .{r.type}) catch {};
        esc(a, out, r.value);
        out.appendSlice(a, "</td></tr>") catch {};
    }
    out.appendSlice(a, "</table>") catch {};
}

fn mapOf(m: *const pst.Message) nm.NameMap {
    return if (m.node) |n| n.pst.nameMap() else .{};
}

/// Standalone HTML page with every property of the message, its recipients and attachments.
pub fn html(a: Allocator, m: *const pst.Message, source: []const u8, fmt_time: TimeFmt) []const u8 {
    const map = mapOf(m);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a,
        \\<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>All properties</title><style>
        \\:root{--bg:#fff;--fg:#1f2328;--mut:#656d76;--line:#d0d7de;--head:#f6f8fa}
        \\@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8d96a0;--line:#30363d;--head:#161b22}}
        \\body{background:var(--bg);color:var(--fg);font:14px/1.45 "Segoe UI",system-ui,sans-serif;margin:0 auto;max-width:1500px;padding:16px 20px 40px}
        \\h1{font-size:20px;margin:4px 0}h2{font-size:16px;margin:24px 0 6px}.sub{color:var(--mut)}
        \\table{border-collapse:collapse;width:100%}th,td{border:1px solid var(--line);padding:3px 7px;text-align:left;vertical-align:top}th{background:var(--head)}
        \\.m{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px;white-space:nowrap}.v{white-space:pre-wrap;word-break:break-all}
        \\</style></head><body><h1>All properties</h1><p class="sub">
    ) catch {};
    esc(a, &out, m.subject(a) catch "");
    out.print(a, " &middot; item 0x{x:0>8} &middot; ", .{m.nid}) catch {};
    esc(a, &out, source);
    out.appendSlice(a, " &middot; named properties resolved through the file's name-to-id map</p>") catch {};
    table(a, &out, "Message", rowsOf(a, m.pc.props, map, fmt_time));
    for (m.recipients, 0..) |r, i| table(a, &out, std.fmt.allocPrint(a, "Recipient {d}", .{i + 1}) catch "Recipient", rowsOf(a, r.props, map, fmt_time));
    for (m.attachments, 0..) |at, i| table(a, &out, std.fmt.allocPrint(a, "Attachment {d}", .{i + 1}) catch "Attachment", rowsOf(a, at.pc.props, map, fmt_time));
    out.appendSlice(a, "</body></html>") catch {};
    return out.items;
}

/// The same as text (for `pstx props`).
pub fn text(a: Allocator, m: *const pst.Message, fmt_time: TimeFmt) []const u8 {
    const map = mapOf(m);
    var out: std.ArrayList(u8) = .empty;
    const section = struct {
        fn f(al: Allocator, o: *std.ArrayList(u8), title: []const u8, rows: []const Row) void {
            o.print(al, "== {s}\n", .{title}) catch {};
            for (rows) |r| o.print(al, "  0x{x:0>8}  {s: <44} {s: <10} {s}\n", .{ r.tag, r.name, r.type, r.value }) catch {};
        }
    }.f;
    section(a, &out, "Message", rowsOf(a, m.pc.props, map, fmt_time));
    for (m.recipients, 0..) |r, i| section(a, &out, std.fmt.allocPrint(a, "Recipient {d}", .{i + 1}) catch "Recipient", rowsOf(a, r.props, map, fmt_time));
    for (m.attachments, 0..) |at, i| section(a, &out, std.fmt.allocPrint(a, "Attachment {d}", .{i + 1}) catch "Attachment", rowsOf(a, at.pc.props, map, fmt_time));
    return out.items;
}
