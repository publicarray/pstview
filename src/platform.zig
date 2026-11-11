//! The two OS services the portable code needs, per platform:
//!   - the local UTC offset at a given time (DST-aware), for showing local times;
//!   - conversion of legacy MIME charsets to UTF-8 (installed as `mime.charset_hook`).
//! Windows uses the Win32 time-zone and code-page APIs; macOS and Linux use libc
//! (`localtime_r` with the system zone database, and `iconv`).

const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;
const win = if (is_windows) @import("win.zig") else struct {};

/// Seconds east of UTC in this computer's time zone at unix time `t`.
pub fn localOffset(t: i64) i64 {
    return if (is_windows) win.localOffset(t) else posix.localOffset(t);
}

/// Text in MIME `charset` -> UTF-8, or null when the charset is unknown or the bytes do not
/// decode (the caller then falls back to Windows-1252).
pub fn charsetToUtf8(a: std.mem.Allocator, charset: []const u8, bytes: []const u8) ?[]u8 {
    return if (is_windows) win.charsetToUtf8(a, charset, bytes) else posix.charsetToUtf8(a, charset, bytes);
}

const posix = struct {
    /// `struct tm` with the BSD/glibc/musl `tm_gmtoff` and `tm_zone` fields.
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
    extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
    extern "c" fn tzset() void;

    const Iconv = struct {
        open: *const fn (to: [*:0]const u8, from: [*:0]const u8) callconv(.c) isize,
        conv: *const fn (cd: isize, in: *?[*]u8, in_left: *usize, out: *?[*]u8, out_left: *usize) callconv(.c) usize,
        close: *const fn (cd: isize) callconv(.c) c_int,
    };

    /// glibc and musl have iconv in libc. macOS keeps it in libiconv, which is loaded at run time
    /// (it is in the system's shared library cache) so that macOS builds need no SDK to link.
    const darwin = builtin.os.tag.isDarwin();
    const libc_iconv = if (darwin) struct {} else struct {
        extern "c" fn iconv_open(to: [*:0]const u8, from: [*:0]const u8) isize;
        extern "c" fn iconv(cd: isize, in: *?[*]u8, in_left: *usize, out: *?[*]u8, out_left: *usize) usize;
        extern "c" fn iconv_close(cd: isize) c_int;
    };
    var iconv_fns: ?Iconv = null;
    var iconv_tried = false;

    fn iconvFns() ?Iconv {
        if (!darwin) return .{ .open = &libc_iconv.iconv_open, .conv = &libc_iconv.iconv, .close = &libc_iconv.iconv_close };
        if (iconv_tried) return iconv_fns;
        iconv_tried = true;
        const lib = std.c.dlopen("/usr/lib/libiconv.2.dylib", .{ .LAZY = true }) orelse return null;
        iconv_fns = .{
            .open = @ptrCast(@alignCast(std.c.dlsym(lib, "iconv_open") orelse return null)),
            .conv = @ptrCast(@alignCast(std.c.dlsym(lib, "iconv") orelse return null)),
            .close = @ptrCast(@alignCast(std.c.dlsym(lib, "iconv_close") orelse return null)),
        };
        return iconv_fns;
    }

    var tz_ready = false;

    fn localOffset(t: i64) i64 {
        if (!tz_ready) {
            tzset();
            tz_ready = true;
        }
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) == null) return 0;
        return tm.gmtoff;
    }

    /// MIME names that iconv spells differently.
    const aliases = [_]struct { []const u8, [:0]const u8 }{
        .{ "ks_c_5601-1987", "CP949" },    .{ "x-sjis", "SHIFT_JIS" }, .{ "sjis", "SHIFT_JIS" },
        .{ "windows-31j", "CP932" },       .{ "x-gbk", "GBK" },        .{ "x-mac-roman", "MACINTOSH" },
        .{ "iso-8859-8-i", "ISO-8859-8" }, .{ "utf-16", "UTF-16" },    .{ "x-cp1252", "CP1252" },
    };

    fn charsetToUtf8(a: std.mem.Allocator, charset: []const u8, bytes: []const u8) ?[]u8 {
        if (bytes.len == 0 or charset.len == 0 or charset.len > 60) return null;
        var nb: [64]u8 = undefined;
        const name: [:0]const u8 = for (aliases) |al| {
            if (std.ascii.eqlIgnoreCase(charset, al[0])) break al[1];
        } else std.fmt.bufPrintSentinel(&nb, "{s}", .{charset}, 0) catch return null;
        const ic = iconvFns() orelse return null;
        const cd = ic.open("UTF-8", name.ptr);
        if (cd == -1) return null;
        defer _ = ic.close(cd);
        // UTF-8 needs at most 4 bytes per input byte for every charset iconv decodes here
        const out = a.alloc(u8, bytes.len * 4 + 16) catch return null;
        var in_ptr: ?[*]u8 = @constCast(bytes.ptr);
        var in_left = bytes.len;
        var out_ptr: ?[*]u8 = out.ptr;
        var out_left = out.len;
        const r = ic.conv(cd, &in_ptr, &in_left, &out_ptr, &out_left);
        if (r == std.math.maxInt(usize) or in_left != 0) {
            a.free(out);
            return null;
        }
        return out[0 .. out.len - out_left];
    }
};
