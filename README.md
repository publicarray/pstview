# pstview

A small, native Windows viewer and exporter for Outlook `.pst` files (including Acronis M365 mailbox backups), written in Zig with no dependencies beyond Win32.

Built for evidence work: the PST is opened **read-only** and never written to. Outlook, by contrast, modifies a PST as soon as it opens one.

## Programs

| File | What it is |
|---|---|
| `pstview.exe` | GUI. Folder tree, sortable/searchable message list, preview pane (headers, recipients, attachments, body, internet headers), export and reports. Drag a PST onto the window or pass it on the command line. |
| `pstx.exe` | Command line: `tree`, `list`, `show`, `export`, `hash`. |

### pstx examples

```
pstx tree    backup.pst
pstx list    backup.pst "Inbox/0.1 Inbox read"
pstx list    backup.pst 0x8462                  # folder by NID (shown by `tree`)
pstx show    backup.pst 00200044                # one message by NID
pstx export  backup.pst 0x8462 C:\out msg --modified 2026-11-05
pstx export  backup.pst "Sent Items" C:\out eml --match "contract"
pstx hash    backup.pst
```

`export` writes one `.msg` or `.eml` per item plus `pstview report.html` and `pstview report.csv` (source path, size, SHA-256, every item's dates, sender, recipients, subject, attachments and exported file name). Dates for `--modified` and in reports are in this computer's local time zone, with daylight saving applied for each date.

## Formats

* **Read:** Unicode PST (`wVer` 23, 512-byte pages), unencrypted or "compressible" encryption. This covers Outlook 2003+ PSTs and Acronis M365 exports. Not yet supported: ANSI (97–2002) PSTs, 4K-page OSTs, "high" encryption.
* **Write .msg:** written directly as a Compound File (no Outlook needed). All message, recipient and attachment properties are copied, and embedded messages are nested. Named properties (IDs ≥ 0x8000, e.g. some calendar fields) are not yet copied.
* **Write .eml:** MIME with plain + HTML bodies and attachments. Original internet headers (Received chain etc.) are preserved when the PST has them. Adds `X-PST-*` provenance headers (NID, delivery and last-modified times).

## Build

Requires Zig 0.16.

```
zig build                # -> zig-out\bin\pstview.exe, pstx.exe (ReleaseSafe)
```

## Layout

* `src/pst.zig`: PST reader (NDB B-trees and blocks, heap-on-node, property and table contexts, folders, messages, recipients, attachments).
* `src/export.zig`: EML and MSG (Compound File Binary) writers, CSV/HTML reports.
* `src/gui.zig`, `src/win.zig`: Win32 GUI and bindings.
* `src/cli.zig`: command line.
