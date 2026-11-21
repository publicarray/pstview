<img src="design/icon-128.png" alt="pstview logo: an envelope under a magnifying glass" width="96" align="right">

# pstview

A small, read-only viewer and exporter for Outlook `.pst` / `.ost` files and MBOX mailboxes, with offline header analysis and recovery of deleted items. Written in Zig with no third-party dependencies; the GUI and the command-line tool run on Windows, macOS and Linux.

Sources are opened **read-only**: nothing is written to them or created next to them. (Outlook changes a data file as soon as it opens it, so close Outlook or work on a copy.)

![pstview with the demo mailbox open: folder tree, message list and a phishing example flagged by the header analysis](docs/screenshot.png)

*The fictional demo mailbox in [`testdata/demo-mailbox`](testdata/demo-mailbox).*

## Download

From [Releases](https://github.com/publicarray/pstview/releases): archives for Windows, macOS and Linux, plus an AppImage and a Flatpak. Each holds two programs:

* **`pstview`:** the app: folder tree, message list, reading pane with header analysis and attachments.
* **`pstx`:** a command-line tool for reading and reporting (`tree`, `list`, `show`, `search`, `triage`, `headers`, `props`, `hash`, `verify`, `hidden`, `recover`, `analyse`). It does not export.

Or use it **in the browser** at https://publicarray.github.io/pstview/: the mailbox is read on your computer and never uploaded, and *Help > Install* adds it as an offline app.

**Requirements:**

* **Windows:** the WebView2 runtime (built into Windows 11 and current Windows 10).
* **macOS:** 11 or later. The app is not notarised: run `xattr -dr com.apple.quarantine pstview.app pstx` after unpacking.
* **Linux:** GTK 4.12+ and WebKitGTK 6.0 (`libgtk-4-1 libwebkitgtk-6.0-4` on Debian / Ubuntu, `gtk4 webkitgtk6.0` on Fedora, `gtk4 webkitgtk-6.0` on Arch). The Flatpak brings its own.

pstview runs straight from the archive; *Help > Install pstview* installs it for the current user (no admin rights) and *Help > Uninstall* removes it.

## Safe viewing

Messages are shown with scripts, network access and remote images blocked, so nothing runs and no tracking pixel loads. Links lead nowhere, and attachments are never opened: text and images can be previewed, anything else only saved.

## Header analysis

A built-in, fully **offline** analysis of a message's headers (the *Header analysis* tab, or Ctrl+I for the full report): spoofing and lookalike domains, SPF / DKIM / DMARC results, the delivery path with delays, spam-filter verdicts, and every IP, domain and address found. *Tools > Analyse headers in this folder* (Ctrl+R) ranks a whole folder by risk; headers pasted from anywhere can be analysed too.

## Hidden and deleted items

* **Hidden items** (shown automatically, `pstx hidden`): messages no folder lists, rules and views, unreachable folders.
* **Recover deleted items** (*Tools* menu, `pstx recover`): deleted items and earlier versions that still sit in the file, recovered only when their data passes its checksums. The method follows libpff's `pffrecover`.

## Several PST files as one

Open several PST / OST parts together (multi-select, drop, or open their folder) and they are shown as one mailbox, with duplicates flagged. Each part stays a separate read-only file.

## Convert to PST

*File > Export whole mailbox as PST* turns an OST, an MBOX export or a set of PST parts into one Unicode PST that Outlook can open. Folders, messages with all their properties, recipients, attachments and embedded messages are kept; search folders, views and the *[Hidden]* / *[Recovered]* branches are left out.

The writer follows [MS-PST] and is checked with pstview's reader, but has not been tested with Outlook itself: please report any file Outlook or *scanpst.exe* complains about.

## Formats

* **PST / OST:** Unicode files, unencrypted or "compressible" encryption, including Outlook 2013+ OSTs. Not yet: ANSI (97-2002) files and "high" encryption.
* **MBOX:** any mbox file, Google Takeout exports, Thunderbird folders and Apple Mail `.mbox` bundles.
* **Items:** mail, calendar, contacts, tasks, notes and journal entries. *Message > All properties* (`pstx props`) lists every MAPI property.
* **Export:** `.pst`, `.msg` and `.eml`, each with an HTML / CSV report that records the source's SHA-256. Exports are made in pstview, which asks where to save; pstx does not export.

## pstx examples

```
pstx tree    backup.pst
pstx list    backup.pst "Inbox"
pstx show    backup.pst 00200044 --html msg.html    # the GUI's sanitised view, as a page
pstx hash    backup.pst
pstx verify  backup.ost                             # close Outlook first
pstx headers backup.pst 00200044 --html hdr.html    # header analysis of one message
pstx analyse suspicious.eml --html hdr.html         # headers of a saved message, no mailbox needed
pstx tree    "export parts"                         # a folder of PST parts, merged
pstx recover backup.ost
```

Folders are named by path or by the NID that `tree` prints; messages by the NID that `list` prints. `pstx` exits with 0 when the command did what was asked and 1 otherwise.

## Build

Requires Zig 0.17.1 or newer.

```
zig build -Drelease                               # pstview and pstx in zig-out/bin
zig build test                                    # unit tests, and each fuzz target once
zig build fuzz -Doptimize=ReleaseSafe --fuzz=10K  # coverage-guided fuzzing of untrusted content
zig build -Drelease -Dtarget=x86_64-linux-musl    # static pstx; a musl build has no GUI
zig build -Drelease -Dtarget=aarch64-macos        # any target cross-compiles from any host
```

The web view is loaded at run time on every platform, so no SDK or development package is needed. `packaging/macos/make-app.sh` wraps the macOS binaries in `pstview.app`.

CI builds every push on Windows, macOS and Linux, checks that `pstx` prints identical output everywhere and that the exporters write identical files, and runs the GUI self-test (`pstview --selftest <source>`). Pushing a `v*` tag publishes a release with the archives and `SHA256SUMS.txt`; the tag must match `release_version` in `build.zig`.

## Source layout

* `src/pst.zig`, `rtfcp.zig`, `namemap.zig`, `itemview.zig`, `propview.zig`, `recover.zig`: PST / OST reader, compressed RTF, named properties, item fields, property list, recovery.
* `src/mbox.zig`, `mime.zig`, `multi.zig`, `store.zig`: MBOX reader, MIME parsing, merged multi-file mailboxes, one interface over all sources.
* `src/headers.zig`, `headerreport.zig`, `search.zig`: header analysis, its reports, and search.
* `src/render.zig`, `export.zig`: the sanitised message view; EML / MSG writers and reports.
* `src/pstwrite.zig`: the PST writer (NDB blocks and B-trees, heaps, property and table contexts, folders and messages).
* `src/webui.html`, `webapp.zig`: the GUI shared by all platforms (the page and the model behind it).
* `src/web.zig`, `web/`: the web browser version (the model as WebAssembly in a Web Worker, with its own std.Io over the user's files; `zig build web`); `testdata/web-test.mjs` tests it in Node.
* `src/gui_win.zig`, `gui_mac.zig`, `gui_gtk.zig`, `gui_posix.zig`: windows, web views and dialogs per platform. A shell may draw the menus, status bar and dialogs natively (GTK does); the page draws whatever it leaves out, from the same menu lists.
* `src/setup.zig`, `install.zig`: per-user install and uninstall.
* `src/cli.zig`, `platform.zig`, `fuzz.zig`: command line, time zone and charset conversion, fuzz targets.

## References

[MS-PST]: Outlook Personal Folders (.pst) File Format
https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/141923d5-15ab-4ef1-a524-6dce75aae546

libpff
https://github.com/libyal/libpff
