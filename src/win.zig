//! Minimal Win32 bindings used by pstview (x64, Unicode).

const std = @import("std");
pub const WINAPI: std.builtin.CallingConvention = .winapi;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HFONT = *opaque {};
pub const HCURSOR = *opaque {};
pub const HICON = *opaque {};
pub const HBRUSH = *opaque {};
pub const HTREEITEM = *opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const BOOL = i32;

pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

pub const POINT = extern struct { x: i32, y: i32 };
pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT, lPrivate: u32 };

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const NMHDR = extern struct { hwndFrom: ?HWND, idFrom: usize, code: i32 };

pub const LVITEMW = extern struct {
    mask: u32 = 0,
    iItem: i32 = 0,
    iSubItem: i32 = 0,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    lParam: LPARAM = 0,
    iIndent: i32 = 0,
    iGroupId: i32 = 0,
    cColumns: u32 = 0,
    puColumns: ?*u32 = null,
    piColFmt: ?*i32 = null,
    iGroup: i32 = 0,
};
pub const NMLVDISPINFOW = extern struct { hdr: NMHDR, item: LVITEMW };
pub const NMLISTVIEW = extern struct { hdr: NMHDR, iItem: i32, iSubItem: i32, uNewState: u32, uOldState: u32, uChanged: u32, ptAction: POINT, lParam: LPARAM };
pub const LVCOLUMNW = extern struct {
    mask: u32 = 0,
    fmt: i32 = 0,
    cx: i32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iSubItem: i32 = 0,
    iImage: i32 = 0,
    iOrder: i32 = 0,
    cxMin: i32 = 0,
    cxDefault: i32 = 0,
    cxIdeal: i32 = 0,
};
pub const TVITEMW = extern struct {
    mask: u32 = 0,
    hItem: ?HTREEITEM = null,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    iSelectedImage: i32 = 0,
    cChildren: i32 = 0,
    lParam: LPARAM = 0,
};
pub const TVINSERTSTRUCTW = extern struct { hParent: ?HTREEITEM, hInsertAfter: ?HTREEITEM, item: TVITEMW, _pad: [16]u8 = @splat(0) };
pub const NMTREEVIEWW = extern struct { hdr: NMHDR, action: u32, itemOld: TVITEMW, itemNew: TVITEMW, ptDrag: POINT };

pub const INITCOMMONCONTROLSEX = extern struct { dwSize: u32 = 8, dwICC: u32 };

pub const OPENFILENAMEW = extern struct {
    lStructSize: u32 = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?[*]const u16 = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: u32 = 0,
    nFilterIndex: u32 = 0,
    lpstrFile: [*]u16,
    nMaxFile: u32,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: u32 = 0,
    lpstrInitialDir: ?[*:0]const u16 = null,
    lpstrTitle: ?[*:0]const u16 = null,
    Flags: u32 = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?[*:0]const u16 = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: u32 = 0,
    FlagsEx: u32 = 0,
};

pub const BROWSEINFOW = extern struct {
    hwndOwner: ?HWND = null,
    pidlRoot: ?*anyopaque = null,
    pszDisplayName: ?[*]u16 = null,
    lpszTitle: ?[*:0]const u16 = null,
    ulFlags: u32 = 0,
    lpfn: ?*anyopaque = null,
    lParam: LPARAM = 0,
    iImage: i32 = 0,
};

pub const SYSTEMTIME = extern struct { wYear: u16, wMonth: u16, wDayOfWeek: u16, wDay: u16, wHour: u16, wMinute: u16, wSecond: u16, wMilliseconds: u16 };
pub const FILETIME = extern struct { lo: u32, hi: u32 };

// ---- constants
pub const WM_CREATE = 0x0001;
pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_SETFOCUS = 0x0007;
pub const WM_CLOSE = 0x0010;
pub const WM_SETFONT = 0x0030;
pub const WM_NOTIFY = 0x004E;
pub const WM_KEYDOWN = 0x0100;
pub const WM_COMMAND = 0x0111;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_SETCURSOR = 0x0020;
pub const WM_USER = 0x0400;
pub const WM_DROPFILES = 0x0233;

pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_CHILD: u32 = 0x40000000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const WS_BORDER: u32 = 0x00800000;
pub const WS_VSCROLL: u32 = 0x00200000;
pub const WS_HSCROLL: u32 = 0x00100000;
pub const WS_CLIPCHILDREN: u32 = 0x02000000;
pub const WS_TABSTOP: u32 = 0x00010000;
pub const WS_EX_CLIENTEDGE: u32 = 0x00000200;
pub const WS_EX_ACCEPTFILES: u32 = 0x00000010;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_AUTOVSCROLL: u32 = 0x0040;
pub const ES_AUTOHSCROLL: u32 = 0x0080;
pub const ES_READONLY: u32 = 0x0800;
pub const ES_NOHIDESEL: u32 = 0x0100;
pub const EM_SETLIMITTEXT = 0x00C5;
pub const EM_SETCUEBANNER = 0x1501;
pub const EN_CHANGE = 0x0300;

pub const LVS_REPORT: u32 = 0x0001;
pub const LVS_SHOWSELALWAYS: u32 = 0x0008;
pub const LVS_OWNERDATA: u32 = 0x1000;
pub const LVS_EX_GRIDLINES: u32 = 0x0001;
pub const LVS_EX_FULLROWSELECT: u32 = 0x0020;
pub const LVS_EX_DOUBLEBUFFER: u32 = 0x00010000;
pub const LVM_FIRST = 0x1000;
pub const LVM_DELETEALLITEMS = LVM_FIRST + 9;
pub const LVM_GETNEXTITEM = LVM_FIRST + 12;
pub const LVM_ENSUREVISIBLE = LVM_FIRST + 19;
pub const LVM_REDRAWITEMS = LVM_FIRST + 21;
pub const LVM_SETITEMSTATE = LVM_FIRST + 43;
pub const LVM_SETITEMCOUNT = LVM_FIRST + 47;
pub const LVM_GETSELECTEDCOUNT = LVM_FIRST + 50;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE = LVM_FIRST + 54;
pub const LVM_INSERTCOLUMNW = LVM_FIRST + 97;
pub const LVN_ITEMCHANGED: i32 = -101;
pub const LVN_COLUMNCLICK: i32 = -108;
pub const LVN_ODSTATECHANGED: i32 = -115;
pub const LVN_GETDISPINFOW: i32 = -177;
pub const NM_DBLCLK: i32 = -3;
pub const LVIF_TEXT: u32 = 0x1;
pub const LVIS_SELECTED: u32 = 0x2;
pub const LVIS_FOCUSED: u32 = 0x1;
pub const LVNI_SELECTED: u32 = 0x2;
pub const LVNI_FOCUSED: u32 = 0x1;
pub const LVCF_FMT: u32 = 0x1;
pub const LVCF_WIDTH: u32 = 0x2;
pub const LVCF_TEXT: u32 = 0x4;
pub const LVCF_SUBITEM: u32 = 0x8;
pub const LVCFMT_RIGHT: i32 = 1;

pub const TVS_HASBUTTONS: u32 = 0x1;
pub const TVS_HASLINES: u32 = 0x2;
pub const TVS_LINESATROOT: u32 = 0x4;
pub const TVS_SHOWSELALWAYS: u32 = 0x20;
pub const TV_FIRST = 0x1100;
pub const TVM_INSERTITEMW = TV_FIRST + 50;
pub const TVM_DELETEITEM = TV_FIRST + 1;
pub const TVM_EXPAND = TV_FIRST + 2;
pub const TVM_SELECTITEM = TV_FIRST + 11;
pub const TVN_SELCHANGEDW: i32 = -451;
pub const TVIF_TEXT: u32 = 0x1;
pub const TVIF_PARAM: u32 = 0x4;
pub const TVIF_STATE: u32 = 0x8;
pub const TVIS_EXPANDED: u32 = 0x20;
pub const TVE_EXPAND: WPARAM = 2;
pub const TVGN_CARET: WPARAM = 9;
pub const TVI_ROOT: HTREEITEM = @ptrFromInt(@as(usize, 0xFFFFFFFFFFFF0000));
pub const TVI_LAST: HTREEITEM = @ptrFromInt(@as(usize, 0xFFFFFFFFFFFF0002));

pub const SB_SETTEXTW = WM_USER + 11;
pub const SB_SETPARTS = WM_USER + 4;
pub const SBARS_SIZEGRIP: u32 = 0x0100;

pub const MF_STRING: u32 = 0x0;
pub const MF_POPUP: u32 = 0x10;
pub const MF_SEPARATOR: u32 = 0x800;
pub const MF_GRAYED: u32 = 0x1;

pub const ICC_LISTVIEW_CLASSES: u32 = 0x1;
pub const ICC_TREEVIEW_CLASSES: u32 = 0x2;
pub const ICC_BAR_CLASSES: u32 = 0x4;

pub const OFN_FILEMUSTEXIST: u32 = 0x1000;
pub const OFN_PATHMUSTEXIST: u32 = 0x800;
pub const OFN_EXPLORER: u32 = 0x80000;
pub const OFN_HIDEREADONLY: u32 = 0x4;
pub const OFN_ALLOWMULTISELECT: u32 = 0x200;
pub const OFN_OVERWRITEPROMPT: u32 = 0x2;

pub const BIF_RETURNONLYFSDIRS: u32 = 0x1;
pub const BIF_EDITBOX: u32 = 0x10;
pub const BIF_NEWDIALOGSTYLE: u32 = 0x40;

pub const MB_OK: u32 = 0x0;
pub const MB_ICONERROR: u32 = 0x10;
pub const MB_TASKMODAL: u32 = 0x2000;
pub const MB_SETFOREGROUND: u32 = 0x10000;
pub const MB_ICONINFORMATION: u32 = 0x40;
pub const MB_YESNO: u32 = 0x4;
pub const IDYES: i32 = 6;

pub const SW_SHOW: i32 = 5;
pub const IDC_ARROW: usize = 32512;
pub const IDC_WAIT: usize = 32514;
pub const IDC_SIZEWE: usize = 32644;
pub const IDI_APPLICATION: usize = 32512;
pub const COLOR_WINDOW: usize = 5;
pub const COLOR_BTNFACE: usize = 15;
pub const DEFAULT_GUI_FONT: i32 = 17;

// ---- user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
pub extern "user32" fn CreateWindowExW(ex: u32, cls: [*:0]const u16, name: ?[*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?HMENU, inst: ?HINSTANCE, param: ?*anyopaque) callconv(WINAPI) ?HWND;
pub extern "user32" fn DefWindowProcW(HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, u32, u32) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(WINAPI) void;
pub extern "user32" fn ShowWindow(HWND, i32) callconv(WINAPI) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn SendMessageW(HWND, u32, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowTextW(HWND, [*]u16, i32) callconv(WINAPI) i32;
pub extern "user32" fn GetWindowTextLengthW(HWND) callconv(WINAPI) i32;
pub extern "user32" fn MessageBoxW(?HWND, [*:0]const u16, [*:0]const u16, u32) callconv(WINAPI) i32;
pub extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, usize) callconv(WINAPI) ?HICON;
pub extern "user32" fn SetCursor(?HCURSOR) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn SetCapture(HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
pub extern "user32" fn CreateMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn AppendMenuW(HMENU, u32, usize, ?[*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn SetMenu(HWND, ?HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(WINAPI) u32;
pub extern "user32" fn SetFocus(?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn GetKeyState(i32) callconv(WINAPI) i16;
pub extern "user32" fn DestroyWindow(HWND) callconv(WINAPI) BOOL;

// ---- gdi32
pub extern "gdi32" fn CreateFontW(h: i32, w: i32, esc: i32, orient: i32, weight: i32, italic: u32, underline: u32, strike: u32, charset: u32, outprec: u32, clipprec: u32, quality: u32, pitch: u32, face: [*:0]const u16) callconv(WINAPI) ?HFONT;
pub extern "gdi32" fn GetStockObject(i32) callconv(WINAPI) ?*anyopaque;

// ---- comctl32 / comdlg32 / shell32 / ole32
pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(WINAPI) BOOL;
pub extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;
pub extern "shell32" fn SHBrowseForFolderW(*BROWSEINFOW) callconv(WINAPI) ?*anyopaque;
pub extern "shell32" fn SHGetPathFromIDListW(*anyopaque, [*]u16) callconv(WINAPI) BOOL;
pub extern "shell32" fn ShellExecuteW(?HWND, ?[*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(WINAPI) ?*anyopaque;
pub extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(WINAPI) void;
pub extern "shell32" fn DragQueryFileW(*anyopaque, u32, ?[*]u16, u32) callconv(WINAPI) u32;
pub extern "shell32" fn DragFinish(*anyopaque) callconv(WINAPI) void;
pub extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(WINAPI) i32;
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(WINAPI) void;

// ---- kernel32
pub extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(WINAPI) ?HINSTANCE;
pub extern "kernel32" fn FileTimeToSystemTime(*const FILETIME, *SYSTEMTIME) callconv(WINAPI) BOOL;
pub extern "kernel32" fn SystemTimeToFileTime(*const SYSTEMTIME, *FILETIME) callconv(WINAPI) BOOL;
pub extern "kernel32" fn SystemTimeToTzSpecificLocalTime(?*const anyopaque, *const SYSTEMTIME, *SYSTEMTIME) callconv(WINAPI) BOOL;
pub extern "kernel32" fn MultiByteToWideChar(code_page: u32, flags: u32, src: [*]const u8, src_len: i32, dst: ?[*]u16, dst_len: i32) callconv(WINAPI) i32;

// ---- painting, menus, window data
pub const HDC = *opaque {};
pub const PAINTSTRUCT = extern struct { hdc: ?HDC, fErase: BOOL, rcPaint: RECT, fRestore: BOOL, fIncUpdate: BOOL, rgbReserved: [32]u8 };
pub const NMLVKEYDOWN = extern struct { hdr: NMHDR, wVKey: u16 align(1), flags: u32 align(1) };
pub const WM_PAINT = 0x000F;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_CONTEXTMENU = 0x007B;
pub const WM_NCDESTROY = 0x0082;
pub const NM_RCLICK: i32 = -5;
pub const NM_RETURN: i32 = -4;
pub const LVN_KEYDOWN: i32 = -155;
pub const TPM_RIGHTBUTTON: u32 = 0x2;
pub const TPM_RETURNCMD: u32 = 0x100;
pub const GWLP_USERDATA: i32 = -21;
pub const VK_RETURN: u16 = 0x0D;
pub const CS_HREDRAW: u32 = 0x2;
pub const CS_VREDRAW: u32 = 0x1;
pub const SW_HIDE: i32 = 0;

pub extern "user32" fn TrackPopupMenu(HMENU, u32, i32, i32, i32, HWND, ?*const RECT) callconv(WINAPI) i32;
pub extern "user32" fn DestroyMenu(HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(WINAPI) BOOL;
pub const CF_UNICODETEXT: u32 = 13;
pub extern "user32" fn OpenClipboard(?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn GetClipboardData(u32) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalLock(*anyopaque) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(*anyopaque) callconv(WINAPI) BOOL;
pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(WINAPI) ?HDC;
pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn InvalidateRect(?HWND, ?*const RECT, BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn FillRect(HDC, *const RECT, ?HBRUSH) callconv(WINAPI) i32;
pub extern "user32" fn GetSysColorBrush(i32) callconv(WINAPI) ?HBRUSH;
pub extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(WINAPI) isize;
pub extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(WINAPI) isize;
pub extern "user32" fn GetParent(HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn DrawTextW(HDC, [*]const u16, i32, *RECT, u32) callconv(WINAPI) i32;
pub extern "gdi32" fn SetBkMode(HDC, i32) callconv(WINAPI) i32;
pub extern "gdi32" fn SelectObject(HDC, ?*anyopaque) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GetTempPathW(u32, [*]u16) callconv(WINAPI) u32;
pub extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(WINAPI) ?*anyopaque;

// ---- Rich Edit (Msftedit.dll) for coloured preview text
pub const SETTEXTEX = extern struct { flags: u32 = 0, codepage: u32 = 0 };
pub const EM_EXLIMITTEXT = WM_USER + 53;
pub const EM_SETTEXTEX = WM_USER + 97;
pub const EM_SETBKGNDCOLOR = WM_USER + 67;
pub const RICHEDIT_CLASS = "RICHEDIT50W";
pub extern "user32" fn GetAncestor(HWND, u32) callconv(WINAPI) ?HWND;
pub extern "user32" fn IsWindow(?HWND) callconv(WINAPI) BOOL;
pub const GA_ROOT: u32 = 2;
pub const VK_ESCAPE: usize = 0x1B;
pub const LVM_INSERTITEMW = LVM_FIRST + 77;
pub const LVM_SETITEMTEXTW = LVM_FIRST + 116;
pub const LVM_GETITEMCOUNT = LVM_FIRST + 4;
pub const LVS_SINGLESEL: u32 = 0x0004;

// ---- GDI+ (flat API) and in-memory streams for image preview
pub const GdiplusStartupInput = extern struct { GdiplusVersion: u32 = 1, DebugEventCallback: ?*anyopaque = null, SuppressBackgroundThread: BOOL = 0, SuppressExternalCodecs: BOOL = 0 };
pub const GpImage = opaque {};
pub const GpGraphics = opaque {};
pub extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipCreateBitmapFromStream(stream: *anyopaque, bitmap: *?*GpImage) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipGetImageWidth(img: *GpImage, w: *u32) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipGetImageHeight(img: *GpImage, h: *u32) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipCreateFromHDC(hdc: HDC, g: *?*GpGraphics) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipDrawImageRectI(g: *GpGraphics, img: *GpImage, x: i32, y: i32, w: i32, h: i32) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipSetInterpolationMode(g: *GpGraphics, mode: i32) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipDeleteGraphics(g: *GpGraphics) callconv(WINAPI) i32;
pub extern "gdiplus" fn GdipDisposeImage(img: *GpImage) callconv(WINAPI) i32;
pub extern "shlwapi" fn SHCreateMemStream(p: [*]const u8, cb: u32) callconv(WINAPI) ?*anyopaque;

/// IUnknown::Release on a COM object (vtable slot 2).
pub fn comRelease(obj: *anyopaque) void {
    const vtbl: *const [3]*const fn (*anyopaque) callconv(WINAPI) u32 = @as(*const *const [3]*const fn (*anyopaque) callconv(WINAPI) u32, @ptrCast(@alignCast(obj))).*;
    _ = vtbl[2](obj);
}

/// Decode an image (PNG/JPEG/GIF/BMP/TIFF/ICO) from memory with GDI+.
pub fn decodeImage(data: []const u8) ?*GpImage {
    if (data.len == 0 or data.len > 0xFFFFFFFF) return null;
    const stream = SHCreateMemStream(data.ptr, @intCast(data.len)) orelse return null;
    defer comRelease(stream);
    var img: ?*GpImage = null;
    if (GdipCreateBitmapFromStream(stream, &img) != 0) return null;
    return img;
}

// ---- helpers

pub fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Offset (seconds) of the machine's local time zone from UTC at unix time `t` (DST-aware).
pub fn localOffset(t: i64) i64 {
    const ft_val: u64 = @intCast((t + 11_644_473_600) * 10_000_000);
    const ft: FILETIME = .{ .lo = @truncate(ft_val), .hi = @truncate(ft_val >> 32) };
    var st: SYSTEMTIME = undefined;
    var lt: SYSTEMTIME = undefined;
    if (FileTimeToSystemTime(&ft, &st) == 0) return 0;
    if (SystemTimeToTzSpecificLocalTime(null, &st, &lt) == 0) return 0;
    var lft: FILETIME = undefined;
    if (SystemTimeToFileTime(&lt, &lft) == 0) return 0;
    const lv: u64 = (@as(u64, lft.hi) << 32) | lft.lo;
    return @divTrunc(@as(i64, @intCast(lv)) - @as(i64, @intCast(ft_val)), 10_000_000);
}

/// Windows code page for a MIME charset name (0 if unknown).
pub fn codePageFor(charset: []const u8) u32 {
    const eq = std.ascii.eqlIgnoreCase;
    const map = [_]struct { []const u8, u32 }{
        .{ "gb2312", 936 },         .{ "gbk", 936 },           .{ "x-gbk", 936 },         .{ "cp936", 936 },
        .{ "gb18030", 54936 },      .{ "big5", 950 },          .{ "big5-hkscs", 950 },    .{ "shift_jis", 932 },
        .{ "shift-jis", 932 },      .{ "sjis", 932 },          .{ "x-sjis", 932 },        .{ "cp932", 932 },
        .{ "windows-31j", 932 },    .{ "euc-jp", 20932 },      .{ "iso-2022-jp", 50220 }, .{ "euc-kr", 51949 },
        .{ "ks_c_5601-1987", 949 }, .{ "iso-2022-kr", 50225 }, .{ "koi8-r", 20866 },      .{ "koi8-u", 21866 },
        .{ "utf-7", 65000 },        .{ "tis-620", 874 },       .{ "windows-874", 874 },   .{ "ibm866", 866 },
        .{ "cp866", 866 },          .{ "macintosh", 10000 },   .{ "x-mac-roman", 10000 }, .{ "iso-8859-8-i", 28598 },
        .{ "utf-16", 1200 },        .{ "utf-16le", 1200 },     .{ "utf-16be", 1201 },     .{ "us-ascii", 20127 },
    };
    for (map) |e| if (eq(charset, e[0])) return e[1];
    // iso-8859-N, windows-NNNN, cpNNNN, ibmNNN
    const prefixes = [_]struct { []const u8, u32 }{ .{ "iso-8859-", 28590 }, .{ "iso8859-", 28590 }, .{ "windows-", 0 }, .{ "cp", 0 }, .{ "ibm", 0 } };
    for (prefixes) |p| {
        if (charset.len > p[0].len and eq(charset[0..p[0].len], p[0])) {
            const n = std.fmt.parseInt(u32, charset[p[0].len..], 10) catch return 0;
            return p[1] + n;
        }
    }
    return 0;
}

/// Convert text in a MIME charset to UTF-8 with the Windows code-page tables (null if unknown).
/// Installed as `mime.charset_hook` by the front ends.
pub fn charsetToUtf8(a: std.mem.Allocator, charset: []const u8, bytes: []const u8) ?[]u8 {
    const cp = codePageFor(charset);
    if (cp == 0 or bytes.len == 0 or bytes.len > std.math.maxInt(i32)) return null;
    const n = MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), null, 0);
    if (n <= 0) return null;
    const wbuf = a.alloc(u16, @intCast(n)) catch return null;
    const got = MultiByteToWideChar(cp, 0, bytes.ptr, @intCast(bytes.len), wbuf.ptr, n);
    if (got <= 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(a, wbuf[0..@intCast(got)]) catch null;
}

// ================================================================ registry, shell and files (installer)

pub const HKEY = *opaque {};
// Predefined keys are sign-extended 32-bit values on x64.
pub const HKEY_CLASSES_ROOT: HKEY = @ptrFromInt(0xFFFFFFFF80000000);
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0xFFFFFFFF80000001);
pub const KEY_READ: u32 = 0x20019;
pub const KEY_WRITE: u32 = 0x20006;
pub const KEY_ALL_ACCESS: u32 = 0xF003F;
pub const REG_NONE: u32 = 0;
pub const REG_SZ: u32 = 1;
pub const REG_DWORD: u32 = 4;
pub const ERROR_SUCCESS: i32 = 0;
pub extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, options: u32, sam: u32, sa: ?*anyopaque, result: *?HKEY, disposition: ?*u32) callconv(WINAPI) i32;
pub extern "advapi32" fn RegOpenKeyExW(key: HKEY, sub: ?[*:0]const u16, options: u32, sam: u32, result: *?HKEY) callconv(WINAPI) i32;
pub extern "advapi32" fn RegSetValueExW(key: HKEY, name: ?[*:0]const u16, reserved: u32, typ: u32, data: ?[*]const u8, cb: u32) callconv(WINAPI) i32;
pub extern "advapi32" fn RegQueryValueExW(key: HKEY, name: ?[*:0]const u16, reserved: ?*u32, typ: ?*u32, data: ?[*]u8, cb: ?*u32) callconv(WINAPI) i32;
pub extern "advapi32" fn RegQueryInfoKeyW(key: HKEY, class: ?[*]u16, class_len: ?*u32, reserved: ?*u32, subkeys: ?*u32, max_subkey: ?*u32, max_class: ?*u32, values: ?*u32, max_value_name: ?*u32, max_value: ?*u32, security: ?*u32, last_write: ?*FILETIME) callconv(WINAPI) i32;
pub extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub: ?[*:0]const u16) callconv(WINAPI) i32;
pub extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub: [*:0]const u16) callconv(WINAPI) i32;
pub extern "advapi32" fn RegDeleteValueW(key: HKEY, name: ?[*:0]const u16) callconv(WINAPI) i32;
pub extern "advapi32" fn RegCloseKey(key: HKEY) callconv(WINAPI) i32;

pub const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const KF_FLAG_CREATE: u32 = 0x8000;
/// %LOCALAPPDATA%\Programs
pub const FOLDERID_UserProgramFiles: GUID = .{ .a = 0x5CD7AEE2, .b = 0x2219, .c = 0x4A67, .d = .{ 0xB8, 0x5D, 0x6C, 0x9C, 0xE1, 0x56, 0x60, 0xCB } };
/// Start Menu\Programs of the current user
pub const FOLDERID_Programs: GUID = .{ .a = 0xA77F5D77, .b = 0x2E2B, .c = 0x44C3, .d = .{ 0xA6, 0xA2, 0xAB, 0xA6, 0x01, 0x05, 0x4A, 0x51 } };
pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(WINAPI) i32;
pub const SHCNE_ASSOCCHANGED: i32 = 0x08000000;
pub extern "shell32" fn SHChangeNotify(event: i32, flags: u32, a: ?*const anyopaque, b: ?*const anyopaque) callconv(WINAPI) void;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HINSTANCE, buf: [*]u16, n: u32) callconv(WINAPI) u32;
pub extern "kernel32" fn CopyFileW(src: [*:0]const u16, dst: [*:0]const u16, fail_if_exists: BOOL) callconv(WINAPI) BOOL;
pub extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(WINAPI) BOOL;
pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};
pub extern "kernel32" fn FindFirstFileW(pattern: [*:0]const u16, data: *WIN32_FIND_DATAW) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn FindNextFileW(h: ?*anyopaque, data: *WIN32_FIND_DATAW) callconv(WINAPI) BOOL;
pub extern "kernel32" fn FindClose(h: ?*anyopaque) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetCurrentProcessId() callconv(WINAPI) u32;
pub const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
pub extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(WINAPI) u32;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) u32;
pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
pub const ERROR_ALREADY_EXISTS: u32 = 183;

pub const CLSCTX_INPROC_SERVER: u32 = 0x1;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(WINAPI) i32;
pub const CLSID_ShellLink: GUID = .{ .a = 0x00021401, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IShellLinkW: GUID = .{ .a = 0x000214F9, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IPersistFile: GUID = .{ .a = 0x0000010B, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

/// Vtable of IShellLinkW (only the slots pstview calls are typed).
pub const IShellLinkWVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) i32,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    GetPath: *const anyopaque,
    GetIDList: *const anyopaque,
    SetIDList: *const anyopaque,
    GetDescription: *const anyopaque,
    SetDescription: *const fn (*anyopaque, [*:0]const u16) callconv(WINAPI) i32,
    GetWorkingDirectory: *const anyopaque,
    SetWorkingDirectory: *const fn (*anyopaque, [*:0]const u16) callconv(WINAPI) i32,
    GetArguments: *const anyopaque,
    SetArguments: *const anyopaque,
    GetHotkey: *const anyopaque,
    SetHotkey: *const anyopaque,
    GetShowCmd: *const anyopaque,
    SetShowCmd: *const anyopaque,
    GetIconLocation: *const anyopaque,
    SetIconLocation: *const fn (*anyopaque, [*:0]const u16, i32) callconv(WINAPI) i32,
    SetRelativePath: *const anyopaque,
    Resolve: *const anyopaque,
    SetPath: *const fn (*anyopaque, [*:0]const u16) callconv(WINAPI) i32,
};
/// Vtable of IPersistFile (only Save is typed).
pub const IPersistFileVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    GetClassID: *const anyopaque,
    IsDirty: *const anyopaque,
    Load: *const anyopaque,
    Save: *const fn (*anyopaque, [*:0]const u16, BOOL) callconv(WINAPI) i32,
    SaveCompleted: *const anyopaque,
    GetCurFile: *const anyopaque,
};

// ---- task dialog (comctl32 v6; the structures are byte-packed in commctrl.h)
pub const TASKDIALOG_BUTTON = extern struct { nButtonID: i32 align(1), pszButtonText: [*:0]const u16 align(1) };
pub const TASKDIALOGCONFIG = extern struct {
    cbSize: u32 align(1) = @sizeOf(TASKDIALOGCONFIG),
    hwndParent: ?HWND align(1) = null,
    hInstance: ?HINSTANCE align(1) = null,
    dwFlags: u32 align(1) = 0,
    dwCommonButtons: u32 align(1) = 0,
    pszWindowTitle: ?[*:0]const u16 align(1) = null,
    hMainIcon: ?*anyopaque align(1) = null,
    pszMainInstruction: ?[*:0]const u16 align(1) = null,
    pszContent: ?[*:0]const u16 align(1) = null,
    cButtons: u32 align(1) = 0,
    pButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultButton: i32 align(1) = 0,
    cRadioButtons: u32 align(1) = 0,
    pRadioButtons: ?[*]const TASKDIALOG_BUTTON align(1) = null,
    nDefaultRadioButton: i32 align(1) = 0,
    pszVerificationText: ?[*:0]const u16 align(1) = null,
    pszExpandedInformation: ?[*:0]const u16 align(1) = null,
    pszExpandedControlText: ?[*:0]const u16 align(1) = null,
    pszCollapsedControlText: ?[*:0]const u16 align(1) = null,
    hFooterIcon: ?*anyopaque align(1) = null,
    pszFooter: ?[*:0]const u16 align(1) = null,
    pfCallback: ?*const anyopaque align(1) = null,
    lpCallbackData: isize align(1) = 0,
    cxWidth: u32 align(1) = 0,
};
comptime {
    std.debug.assert(@sizeOf(TASKDIALOGCONFIG) == 160);
    std.debug.assert(@sizeOf(TASKDIALOG_BUTTON) == 12);
}
pub const TDF_USE_HICON_MAIN: u32 = 0x0002;
pub const TDF_ALLOW_DIALOG_CANCELLATION: u32 = 0x0008;
pub const TDF_USE_COMMAND_LINKS: u32 = 0x0010;
pub const TDF_POSITION_RELATIVE_TO_WINDOW: u32 = 0x1000;
pub const TDCBF_CANCEL_BUTTON: u32 = 0x8;
pub const TDCBF_CLOSE_BUTTON: u32 = 0x20;
pub const IDCANCEL: i32 = 2;
pub extern "comctl32" fn TaskDialogIndirect(cfg: *const TASKDIALOGCONFIG, button: ?*i32, radio: ?*i32, verified: ?*BOOL) callconv(WINAPI) i32;

// ================================================================ theming and drawing

pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, attr: u32, value: *const anyopaque, size: u32) callconv(WINAPI) i32;
pub const DWMWA_BORDER_COLOR: u32 = 34;
pub const DWMWA_CAPTION_COLOR: u32 = 35;
pub const DWMWA_TEXT_COLOR: u32 = 36;
pub extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(WINAPI) ?*const anyopaque;
pub extern "user32" fn GetMenuBarInfo(hwnd: HWND, object: i32, item: i32, info: *MENUBARINFO) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMenuItemInfoW(menu: HMENU, item: u32, by_position: BOOL, info: *MENUITEMINFOW) callconv(WINAPI) BOOL;
pub extern "user32" fn CheckMenuRadioItem(menu: HMENU, first: u32, last: u32, check: u32, flags: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn DrawMenuBar(hwnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn RedrawWindow(hwnd: HWND, rc: ?*const RECT, rgn: ?*anyopaque, flags: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowDC(hwnd: ?HWND) callconv(WINAPI) ?HDC;
pub extern "user32" fn MapWindowPoints(from: ?HWND, to: ?HWND, points: *RECT, count: u32) callconv(WINAPI) i32;
pub extern "comctl32" fn SetWindowSubclass(hwnd: HWND, proc: *const fn (HWND, u32, WPARAM, LPARAM, usize, usize) callconv(WINAPI) LRESULT, id: usize, ref: usize) callconv(WINAPI) BOOL;
pub extern "comctl32" fn DefSubclassProc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT;
pub const MENUBARINFO = extern struct { cbSize: u32 = @sizeOf(MENUBARINFO), rcBar: RECT = undefined, hMenu: ?HMENU = null, hwndMenu: ?HWND = null, flags: i32 = 0 };
pub const MENUITEMINFOW = extern struct {
    cbSize: u32 = @sizeOf(MENUITEMINFOW),
    fMask: u32 = 0,
    fType: u32 = 0,
    fState: u32 = 0,
    wID: u32 = 0,
    hSubMenu: ?HMENU = null,
    hbmpChecked: ?*anyopaque = null,
    hbmpUnchecked: ?*anyopaque = null,
    dwItemData: usize = 0,
    dwTypeData: ?[*]u16 = null,
    cch: u32 = 0,
    hbmpItem: ?*anyopaque = null,
};
/// NMCUSTOMDRAW up to the device context (the rest is not used).
pub const NMCUSTOMDRAW = extern struct { hdr: NMHDR, dwDrawStage: u32, hdc: ?HDC };
pub const NM_CUSTOMDRAW: i32 = -12;
pub const WM_SETTINGCHANGE: u32 = 0x001A;
pub const WM_NCPAINT: u32 = 0x0085;
pub const WM_NCACTIVATE: u32 = 0x0086;
pub const SB_SETBKCOLOR: u32 = 0x2001;
pub const SBT_NOBORDERS: usize = 0x100;
pub const LVM_GETHEADER = LVM_FIRST + 31;
pub extern "uxtheme" fn SetWindowTheme(hwnd: HWND, app_name: ?[*:0]const u16, id_list: ?[*:0]const u16) callconv(WINAPI) i32;

pub const HBITMAP = *opaque {};
pub const HPEN = *opaque {};
pub const HIMAGELIST = *opaque {};
pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(WINAPI) ?HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(WINAPI) BOOL;
pub extern "gdi32" fn CreateDIBSection(hdc: ?HDC, bmi: *const BITMAPINFOHEADER, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(WINAPI) ?HBITMAP;
pub extern "gdi32" fn DeleteObject(obj: *anyopaque) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(WINAPI) u32;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) callconv(WINAPI) u32;
pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(WINAPI) ?HBRUSH;
pub extern "gdi32" fn CreatePen(style: i32, width: i32, color: u32) callconv(WINAPI) ?HPEN;
pub extern "gdi32" fn RoundRect(hdc: HDC, l: i32, t: i32, r: i32, b: i32, w: i32, h: i32) callconv(WINAPI) BOOL;
pub extern "gdi32" fn Ellipse(hdc: HDC, l: i32, t: i32, r: i32, b: i32) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(WINAPI) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(WINAPI) i32;
pub extern "user32" fn LoadImageW(inst: ?HINSTANCE, name: usize, typ: u32, cx: i32, cy: i32, flags: u32) callconv(WINAPI) ?*anyopaque;
pub extern "user32" fn DrawIconEx(hdc: HDC, x: i32, y: i32, icon: HICON, cx: i32, cy: i32, step: u32, brush: ?HBRUSH, flags: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn PostMessageW(hwnd: ?HWND, msg: u32, wp: WPARAM, lp: LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn EnableMenuItem(menu: HMENU, id: u32, flags: u32) callconv(WINAPI) BOOL;
pub extern "comctl32" fn ImageList_Create(cx: i32, cy: i32, flags: u32, initial: i32, grow: i32) callconv(WINAPI) ?HIMAGELIST;
pub extern "comctl32" fn ImageList_Add(himl: HIMAGELIST, image: HBITMAP, mask: ?HBITMAP) callconv(WINAPI) i32;
pub const IMAGE_ICON: u32 = 1;
pub const DI_NORMAL: u32 = 3;
pub const ILC_COLOR32: u32 = 0x20;
pub const NULL_PEN: i32 = 8;
pub const NULL_BRUSH: i32 = 5;
pub const PS_SOLID: i32 = 0;
pub const DT_CENTER: u32 = 0x1;
pub const DT_VCENTER: u32 = 0x4;
pub const DT_WORDBREAK: u32 = 0x10;
pub const DT_SINGLELINE: u32 = 0x20;
pub const DT_NOPREFIX: u32 = 0x800;
pub const DT_END_ELLIPSIS: u32 = 0x8000;
pub const TRANSPARENT: i32 = 1;
pub const WM_APP: u32 = 0x8000;
pub const WM_DRAWITEM: u32 = 0x002B;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
pub const WM_INITMENUPOPUP: u32 = 0x0117;
pub const MF_BYCOMMAND: u32 = 0x0;
pub const MF_ENABLED: u32 = 0x0;
pub const SW_SHOWNORMAL: i32 = 1;
pub const WS_CLIPSIBLINGS: u32 = 0x04000000;
pub const BS_COMMANDLINK: u32 = 0x0E;
pub const BCM_SETNOTE: u32 = 0x1609;
pub const BN_CLICKED: u16 = 0;
pub const EM_SETRECT: u32 = 0x00B3;
pub const SBT_OWNERDRAW: usize = 0x1000;
pub const DRAWITEMSTRUCT = extern struct { CtlType: u32, CtlID: u32, itemID: u32, itemAction: u32, itemState: u32, hwndItem: ?HWND, hDC: ?HDC, rcItem: RECT, itemData: usize };
pub const TVIF_IMAGE: u32 = 0x2;
pub const TVIF_SELECTEDIMAGE: u32 = 0x20;
pub const TVS_TRACKSELECT: u32 = 0x200;
pub const TVS_FULLROWSELECT: u32 = 0x1000;
pub const TVS_EX_DOUBLEBUFFER: usize = 0x4;
pub const TVS_EX_FADEINOUTEXPANDOS: usize = 0x40;
pub const TVM_GETNEXTITEM = TV_FIRST + 10;
pub const TVM_SETIMAGELIST = TV_FIRST + 9;
pub const TVM_SETITEMHEIGHT = TV_FIRST + 27;
pub const TVM_SETBKCOLOR = TV_FIRST + 29;
pub const TVM_SETTEXTCOLOR = TV_FIRST + 30;
pub const TVM_SETEXTENDEDSTYLE = TV_FIRST + 44;
pub const TVGN_ROOT: WPARAM = 0;
pub const TVGN_NEXT: WPARAM = 1;
pub const TVGN_CHILD: WPARAM = 4;
pub const LVM_SETBKCOLOR = LVM_FIRST + 1;
pub const LVM_SETIMAGELIST = LVM_FIRST + 3;
pub const LVM_SETTEXTCOLOR = LVM_FIRST + 36;
pub const LVM_SETTEXTBKCOLOR = LVM_FIRST + 38;
pub const LVSIL_SMALL: WPARAM = 1;

/// COLORREF (0x00BBGGRR) from 0xRRGGBB.
pub fn rgb(hex: u32) u32 {
    return ((hex & 0xFF) << 16) | (hex & 0xFF00) | ((hex >> 16) & 0xFF);
}
pub extern "gdi32" fn GdiFlush() callconv(WINAPI) BOOL;
pub extern "gdi32" fn GetTextFaceW(hdc: HDC, n: i32, buf: [*]u16) callconv(WINAPI) i32;
pub extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(WINAPI) BOOL;
pub const WM_PRINTCLIENT: u32 = 0x0318;
pub const WM_CTLCOLORBTN: u32 = 0x0135;
pub const IDC_SIZENS: usize = 32645;
pub const EM_SETMARGINS: u32 = 0x00D3;
pub const EC_LEFTMARGIN: usize = 0x1;
pub const EC_RIGHTMARGIN: usize = 0x2;
pub const LVN_GETEMPTYMARKUP: i32 = -187;
pub const EMF_CENTERED: u32 = 0x1;
pub const NMLVEMPTYMARKUP = extern struct { hdr: NMHDR, dwFlags: u32, szMarkup: [2084]u16 };

// ---- custom dialogs (ui.dialog)
pub extern "user32" fn EnableWindow(hwnd: HWND, enable: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn IsDialogMessageW(hwnd: HWND, msg: *MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn GetActiveWindow() callconv(WINAPI) ?HWND;
pub extern "user32" fn AdjustWindowRectExForDpi(rc: *RECT, style: u32, menu: BOOL, ex_style: u32, dpi: u32) callconv(WINAPI) BOOL;
pub extern "user32" fn GetDpiForSystem() callconv(WINAPI) u32;
pub extern "user32" fn GetSystemMetrics(index: i32) callconv(WINAPI) i32;
pub const WS_POPUP: u32 = 0x80000000;
pub const WS_CAPTION: u32 = 0x00C00000;
pub const WS_SYSMENU: u32 = 0x00080000;
pub const WS_EX_DLGMODALFRAME: u32 = 0x00000001;
pub const ICC_LINK_CLASS: u32 = 0x8000;
pub const NM_CLICK: i32 = -2;
pub const DT_CALCRECT: u32 = 0x400;
pub const DT_EDITCONTROL: u32 = 0x2000;
pub const BS_DEFPUSHBUTTON: u32 = 0x1;
pub const IDOK: i32 = 1;
pub const SM_CXSCREEN: i32 = 0;
pub const SM_CYSCREEN: i32 = 1;

// ================================================================ native menus, status strip, task dialog callbacks

pub extern "user32" fn GetMenu(hwnd: HWND) callconv(WINAPI) ?HMENU;
pub extern "user32" fn CheckMenuItem(menu: HMENU, id: u32, flags: u32) callconv(WINAPI) u32;
pub extern "user32" fn EndMenu() callconv(WINAPI) BOOL;
pub extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, func: ?*const anyopaque) callconv(WINAPI) usize;
pub extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(WINAPI) u32;
pub const MF_CHECKED: u32 = 0x8;
pub const MF_UNCHECKED: u32 = 0x0;
pub const WM_TIMER: u32 = 0x0113;
pub const DT_LEFT: u32 = 0x0;
pub const TDF_ENABLE_HYPERLINKS: u32 = 0x0001;
pub const TDF_CALLBACK_TIMER: u32 = 0x0800;
pub const TDCBF_OK_BUTTON: u32 = 0x1;
pub const TDN_HYPERLINK_CLICKED: u32 = 3;
pub const TDN_TIMER: u32 = 4;
pub const TDM_CLICK_BUTTON: u32 = WM_USER + 102;
/// PFTASKDIALOGCALLBACK
pub const TaskDialogCallback = *const fn (hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM, data: isize) callconv(WINAPI) i32;
