# pstview

A small, native Windows viewer and exporter for Outlook `.pst` and `.ost` files (including Acronis M365 mailbox backups and Outlook 2013+ cached-mode OSTs), written in Zig with no dependencies beyond Win32.

Built for evidence work: the PST/OST is opened **read-only** and never written to. Outlook, by contrast, modifies a data file as soon as it opens one. Outlook also locks its OSTs while running: close Outlook or work on a copy.

## Programs

| File | What it is |
|---|---|
| `pstview.exe` | GUI. Folder tree, sortable/searchable message list, preview pane (headers, recipients, attachments, body, internet headers), export and reports. Drag a PST or OST onto the window or pass it on the command line. |
| `pstx.exe` | Command line: `tree`, `list`, `show`, `export`, `hash`, `hidden`, `verify`, `search`, `triage`, `headers`. Takes a `.pst` or `.ost`. |

### pstx examples

```
pstx tree    backup.pst
pstx list    backup.pst "Inbox/0.1 Inbox read"
pstx list    backup.pst 0x8462                  # folder by NID (shown by `tree`)
pstx show    backup.pst 00200044                # one message by NID
pstx export  backup.pst 0x8462 C:\out msg --modified 2026-11-05
pstx export  backup.pst "Sent Items" C:\out eml --match "contract"
pstx hash    backup.pst
pstx verify  "%LOCALAPPDATA%\Microsoft\Outlook\user@example.com.ost"   # close Outlook first
```

`export` writes one `.msg` or `.eml` per item plus `pstview report.html` and `pstview report.csv` (source path, size, file format, SHA-256, every item's dates, sender, recipients, subject, attachments and exported file name). Dates for `--modified` and in reports are in this computer's local time zone, with daylight saving applied for each date.

## Formats

* **Read:** Unicode PST and OST, unencrypted or "compressible" encryption:
  * `wVer` 23 (512-byte pages): Outlook 2003+ PSTs, Outlook 2003–2010 OSTs, Acronis M365 exports.
  * `wVer` 36 (4 KiB pages, 64 KiB zlib-compressed blocks): Outlook 2013+ OSTs. This variant is not in [MS-PST]; the layout follows libpff's notes and was checked against real OSTs (every block's checksum, every message loaded).
  * Not yet supported: ANSI (97–2002) PSTs/OSTs, "high" encryption.
* **OST specifics:** an OST's folder contents tables are a cache kept by Outlook. Their sender-name cells are unreliable, so for OSTs the sender shown in lists comes from each message itself. OSTs usually store no plain-text body and many messages carry only compressed RTF; pstview decompresses it ([MS-OXRTFCP]) and shows the HTML it wraps or the text it contains. This applies to PSTs too.
* **Write .msg:** written directly as a Compound File (no Outlook needed). All message, recipient and attachment properties are copied, and embedded messages are nested. Named properties (IDs ≥ 0x8000, e.g. some calendar fields) are not yet copied.
* **Write .eml:** MIME with plain + HTML bodies and attachments. Original internet headers (Received chain etc.) are preserved when the PST has them. Adds `X-PST-*` provenance headers (NID, delivery and last-modified times).

## Build

Requires Zig 0.16.

```
zig build -Drelease      # -> zig-out\bin\pstview.exe, pstx.exe (ReleaseSafe)
zig build                # Debug build
```

## Layout

* `src/pst.zig`: PST/OST reader (NDB B-trees and blocks incl. the 4K OST variant, heap-on-node, property and table contexts, folders, messages, recipients, attachments).
* `src/rtfcp.zig`: compressed RTF bodies: decompression, HTML de-encapsulation, RTF to text.
* `src/export.zig`: EML and MSG (Compound File Binary) writers, CSV/HTML reports.
* `src/gui.zig`, `src/win.zig`: Win32 GUI and bindings.
* `src/cli.zig`: command line.

## Releases

GitHub Actions (`.github/workflows/build.yml`) builds every push and pull request on Windows and uploads the zip as a workflow artifact. Pushing a `v*` tag also publishes a GitHub release with `pstview-<tag>-windows-x64.zip` and `SHA256SUMS.txt`:

```
git tag v0.1.0
git push origin v0.1.0
```
