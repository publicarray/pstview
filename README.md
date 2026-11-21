<img src="design/icon-128.png" alt="pstview logo: an envelope under a magnifying glass" width="96" align="right">

# pstview

A small, read-only viewer and exporter for Outlook `.pst` / `.ost` files and MBOX mailboxes, with offline header analysis and recovery of deleted items. Written in Zig with no third-party dependencies; the GUI and the command-line tool run on Windows, macOS and Linux.

Built for evidence work: sources are opened **read-only** and never written to, and nothing (no index or cache file) is created next to them. Outlook, by contrast, modifies a data file as soon as it opens one, and locks its OSTs while running: close Outlook or work on a copy.

![pstview with the demo mailbox open: folder tree, message list and a phishing example flagged by the header analysis](docs/screenshot.png)

*The fictional demo mailbox in [`testdata/demo-mailbox`](testdata/demo-mailbox); all names, domains and addresses are made up.*

## Programs

| Program | What it is |
|---|---|
| `pstview` (`pstview.exe`, `pstview.app`) | GUI, the same on every platform: folder tree, sortable / searchable message list, and a reading pane with tabs (*Message*, *Header analysis*, *Internet headers*, *Attachments*). Double-click or Enter opens a message in its own window. Open a source with *File > Open*, by dropping it on the window, from the command line, or with *Open with*. |
| `pstx` (`pstx.exe`) | Command line, for reading and reporting: `tree`, `list`, `show`, `hash`, `hidden`, `verify`, `search`, `triage`, `headers`, `props`, `recover`, `analyse`. It does not export. |

Release archives hold both programs: `windows-x64`, `linux-x64`, `linux-arm64`, `macos-arm64`, `macos-x64`. Linux also gets:

* **AppImage** (`x86_64`, `aarch64`): one file, `chmod +x` and run; `pstview-….AppImage pstx tree a.pst` runs the command-line tool. It uses the system's GTK 4 and WebKitGTK 6.0, like the archive.
* **Flatpak** (`x86_64`): `flatpak install --user pstview-…-x86_64.flatpak` (fetches the GNOME runtime from Flathub, so GTK and WebKitGTK need not be installed). It has no network and no file access of its own: mailboxes are opened and exports saved through the file chooser, by dropping files, or with *Open with*; Help > Install does not apply. For pstx on files outside that: `flatpak run --filesystem=home:ro --command=pstx io.github.publicarray.pstview tree ~/a.pst`.

**In the web browser.** The same program also runs as a web page, built to WebAssembly: at https://publicarray.github.io/pstview/ (published with each release), or self-hosted from the release's `web.zip` (any static web server; files must be served over HTTPS or from localhost). The mailbox is read on your computer, in place and never uploaded; exports become downloads (several files: one .zip). *Help > Install pstview as an app* installs it like a desktop program where the browser can (Chrome, Edge, Safari) and it then works offline and opens mailbox files from the file manager. Message windows are not available there (*Enlarge* instead).

**Requirements.** `pstx` needs nothing. The GUI shows its content in the web view that is part of the operating system, so there is no bundled browser engine:

* **Windows:** the WebView2 runtime (part of Windows 11 and of up-to-date Windows 10).
* **macOS:** 11 or later. The app is ad-hoc signed, not notarised: after unpacking run `xattr -dr com.apple.quarantine pstview.app pstx`, or allow it in *System Settings > Privacy & Security*.
* **Linux:** GTK 4.12 or later and WebKitGTK 6.0, which current desktops have (`libgtk-4-1 libwebkitgtk-6.0-4` on Debian 13 / Ubuntu 24.04, `gtk4 webkitgtk6.0` on Fedora, `gtk4 webkitgtk-6.0` on Arch). Menus, status bar and dialogs are native GTK; the web view shows the mailbox and the messages.

pstview warns when its web view is missing.

## Portable or installed

pstview runs from the release archive. *Help > Install pstview for this user* installs it, *Help > Uninstall pstview* removes itself. No administrator or root rights are needed.

* **Windows:** `%LOCALAPPDATA%\Programs\pstview`, a Start menu shortcut, *Open with* handlers for `.pst`, `.ost`, `.mbox`, `.mbx`, and an entry in *Settings > Apps*; everything per user under `HKCU`. A portable copy offers to install when it starts; *Don't offer this again* stores only that choice.
* **Linux:** `~/.local/bin`, plus a menu entry, the icon and a file type for `.pst` / `.ost` under `~/.local/share`. Also `pstview --install` and `pstview --uninstall`.
* **macOS:** a copy of `pstview.app` in `~/Applications`. The default app is chosen in Finder (*Get Info > Open with > Change All*).

## Safe viewing

* The HTML is sanitised: scripts, frames, forms, event handlers and `javascript:` URLs are removed.
* Remote images and CSS are replaced and counted, so no tracking pixel is fetched; `cid:` images are embedded from the attachments.
* A Content-Security-Policy forbids scripts and network access, and the message sits in a sandboxed frame where no script runs.
* The mail's own CSS is confined to the mail, so a message can neither restyle nor cover the header block above it.
* Every navigation and new window is refused (a link in a message leads nowhere), and the web view keeps no profile.
* Attachments are never opened. Text and PNG / JPEG / GIF / BMP / WebP images can be viewed in place; anything else can only be saved.

pstview follows the system's light or dark setting, and *View > Theme* switches it for the session. HTML mail is always laid out on white, as emails are not usually desiged for dark backgrounds.

## Header analysis

A message-header analyser, built in and **fully offline**: no DNS, reputation or geo-IP lookups. Use the *Header analysis* tab, *Message > Header analysis report* (Ctrl+I) for the full report, or *Tools > Analyse pasted headers / headers from .eml or .txt file* for headers copied from anywhere. The report shows:

* **Verdict and findings:** spoofing, impersonation of internal users, lookalike domains, Reply-To diversion, failed authentication, phishing / spam verdicts of the receiving service, delays and clock skew.
* **Authentication:** SPF, DKIM and DMARC as recorded on first arrival in the receiving organisation (mail gateways re-inject mail, and later re-checks fail by design), SPF and DKIM alignment with the From domain, pstview's own DMARC evaluation, and every authentication result, DKIM signature and ARC chain.
* **Delivery path:** every hop with host, IP, protocol, TLS version, per-hop delay, and negative delays flagged as clock skew.
* **Filtering:** anti-spam and filtering headers of the common mail services and gateways, decoded and explained.
* **Indicators:** all IP addresses, hosts, domains, e-mail addresses and URLs in the headers, with the header each came from.

*Tools > Analyse headers in this folder* (Ctrl+R) runs the triage part over a whole folder and sorts by risk.

## Hidden, deleted and recovered items

* **Hidden-item scan** (automatic, *[Hidden items]* branch, `pstx hidden`): messages that no folder lists, folder-associated items such as rules and views, and folders not reachable from the tree.
* **Recover deleted items** (*Tools > Recover deleted items*, `pstx recover`): Outlook writes changed index pages elsewhere and frees the old ones, which usually stay in the file. pstview finds the valid stale pages and recovers what they list: items **no longer indexed** (deleted or moved) and **earlier versions** of existing items. An item is recovered only when its data blocks still pass their checksums. Each item's *Note* names the stale page and the folder it was in. The approach follows libpff's `pffrecover` (*Personal Folder File forensics*, J. Metz).
* **Server-side deletions:** a *Recoverable Items* folder (present in eDiscovery and server exports) is labelled in the tree.
* **Thunderbird:** messages flagged as deleted but not yet compacted are listed and marked.

## Multi-file PST sets

Open several PST / OST files together (multi-select in *File > Open*, drop them on the window, open their folder, or `pstx ... "a.pst;b.pst"`) and they are shown as **one mailbox**. Same-path folders are combined, each item's *Note* names its part, and items found in more than one part are flagged as duplicates, not hidden. Every part stays a separate read-only file: verification, the integrity log and SHA-256 hashes are reported per part.

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
