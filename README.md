# pstview

A small, native Windows viewer and exporter for Outlook `.pst` and `.ost` files (including Acronis M365 mailbox backups and Outlook 2013+ cached-mode OSTs) and MBOX mailboxes (Google Takeout, Thunderbird, Apple Mail), written in Zig with no dependencies beyond Win32.

Built for evidence work: sources are opened **read-only** and never written to, and nothing (no index or cache file) is created next to them. Outlook, by contrast, modifies a data file as soon as it opens one. Outlook also locks its OSTs while running: close Outlook or work on a copy.

## Programs

| File | What it is |
|---|---|
| `pstview.exe` | GUI. Folder tree, sortable/searchable message list, preview pane (headers, recipients, attachments, body, internet headers), header analysis, export and reports. Drag a PST, OST, MBOX file or mail folder onto the window, use *File > Open*, or pass it on the command line. |
| `pstx.exe` | Command line: `tree`, `list`, `show`, `export`, `hash`, `hidden`, `verify`, `search`, `triage`, `headers`, `analyse`. Takes a `.pst`, `.ost`, MBOX file or folder of MBOX mailboxes (`hidden`, `verify` and `locate` are PST/OST only; `analyse` takes a `.eml` or a text file of headers). |

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
pstx headers backup.pst 00200044 --html hdr.html  # full header analysis of one message
pstx analyse suspicious.eml --html hdr.html       # headers of a saved message or pasted text, no mailbox needed
pstx tree    "D:\Case\Acronis export"             # folder of PST parts: merged into one mailbox
pstx list    "part1.pst;part2.pst" "Sent Items"   # or name the parts, separated by ';'
pstx props   backup.pst 00200044 --html props.html  # every MAPI property of one item, named properties resolved
```

`export` writes one `.msg` or `.eml` per item plus `pstview report.html` and `pstview report.csv` (source path, size, file format, SHA-256, every item's dates, sender, recipients, subject, attachments and exported file name). Dates for `--modified` and in reports are in this computer's local time zone, with daylight saving applied for each date.

## Calendar, contacts, tasks, notes and journal

Item fields are shown in the preview, the message window, the HTML view and `pstx show`. Most of them are named properties (IDs 0x8000+); pstview reads each PST's name-to-ID map (NID 0x61) to find them:

* **Appointments / meetings:** start, end, all-day, duration, location, recurrence pattern, time zone, show-as, meeting state (organised, received, cancelled), response, organiser and required / optional / resource attendees.
* **Contacts:** full name, file-as, name parts, nickname, company, title, department, office, manager, assistant, up to three e-mail addresses, all phone numbers, business / home / other addresses, web pages, IM, birthday, anniversary, partner. **Distribution lists:** members.
* **Tasks:** status, % complete, start, due, completed, owner, assigned by. **Sticky notes:** colour. **Journal:** type, start, end, duration.
* **All items:** categories, importance, sensitivity, follow-up flag, reminder.

*Message > All properties* (`pstx props`) lists every MAPI property of the item, its recipients and attachments: tag, name (named properties as property set and dispid or name), type and decoded value - the raw view for anything the summary does not show.

## Multi-file PST sets (Acronis exports in parts)

Open several PST/OST files together (multi-select in *File > Open*, drop several files on the window, open the folder that holds them, or `pstx ... "a.pst;b.pst"`) and they are shown as **one mailbox**:

* The user folders of every part (the IPM subtree: "Top of Outlook data file" in a PST, "Root - Mailbox/IPM_SUBTREE" in an OST) are merged under *Mailbox (merged)*; same-path folders such as Inbox or Sent Items are combined. Other folders (search roots, system folders) are merged by path beside it.
* Each item's *Note* names the part file it came from. Items found in more than one part (same subject, sender and times) are **flagged as duplicates**, not hidden.
* Parts are sorted naturally (`export.pst`, `export_1.pst`, ..., `export_10.pst`) and every part stays a separate read-only file: block verification, the integrity log, the hidden-item scan (`pstx hidden`) and SHA-256 hashes are reported per part.
* Message ids encode the part, so `pstx show` / `headers` ids from `pstx list` stay valid between runs.

## Header analysis

A message-header analyser in the spirit of Microsoft's Message Header Analyzer, MXToolbox and the Google Admin Toolbox, built in and **fully offline** (no DNS, reputation or geo-IP lookups; nothing leaves the machine). In the GUI: *Message > Header analysis report* (Ctrl+I) for the selected item, or *Tools > Analyse headers from clipboard / from .eml or .txt file* for headers copied from anywhere. The report opens as a self-contained HTML page and shows:

* **Verdict and findings:** spoofing, impersonation of internal users, lookalike domains, Reply-To diversion, failed authentication, Microsoft 365 phishing/spam verdicts, delays and clock skew.
* **Summary:** From, Sender, Reply-To, Return-Path, recipients, Date, Message-ID, mailer, total delivery time, earliest recorded origin IP.
* **Authentication:** SPF, DKIM, DMARC and Microsoft compauth from the first arrival in the receiving organisation (gateways such as INKY or Mimecast re-inject mail, and later re-checks fail by design); SPF and DKIM **alignment** with the From domain and pstview's own DMARC evaluation; every `Authentication-Results`, `ARC-Authentication-Results` and `Received-SPF` entry; DKIM and ARC signatures (domain, selector, algorithm, signing time, signed headers, ARC chain).
* **Delivery path:** every `Received` / `X-Received` hop with submitting and receiving host, reverse DNS/HELO, IP, protocol, TLS version and cipher, per-hop delay (with bars) and negative delays flagged as clock skew.
* **Anti-spam and filtering:** `X-Forefront-Antispam-Report` and `X-Microsoft-Antispam` fields decoded (SFV, CAT, SCL, BCL, IPV, SFTY, PTR, HELO, DIR...), `X-MS-Exchange-Organization-*` / cross-tenant headers explained, SpamAssassin score and rules, and headers of other filters (Mimecast, Proofpoint, Barracuda, Cisco, Sophos, Trend Micro, INKY, Gmail).
* **Indicators:** all IP addresses (public/private), hosts and domains, e-mail addresses and URLs found in the headers, with the header each came from, for your own block-list or reputation checks.
* **All headers** in stored order.

`Tools > Analyse headers in this folder` (Ctrl+R) runs the triage part over a whole folder and sorts by risk.

## Formats

* **Read:** Unicode PST and OST, unencrypted or "compressible" encryption:
  * `wVer` 23 (512-byte pages): Outlook 2003+ PSTs, Outlook 2003–2010 OSTs, Acronis M365 exports.
  * `wVer` 36 (4 KiB pages, 64 KiB zlib-compressed blocks): Outlook 2013+ OSTs. This variant is not in [MS-PST]; the layout follows libpff's notes and was checked against real OSTs (every block's checksum, every message loaded).
  * Not yet supported: ANSI (97–2002) PSTs/OSTs, "high" encryption.
* **OST specifics:** an OST's folder contents tables are a cache kept by Outlook. Their sender-name cells are unreliable, so for OSTs the sender shown in lists comes from each message itself. OSTs usually store no plain-text body and many messages carry only compressed RTF; pstview decompresses it ([MS-OXRTFCP]) and shows the HTML it wraps or the text it contains. This applies to PSTs too.
* **Read MBOX:** any mbox file (mboxo / mboxrd; `>From ` escaping undone, LF or CRLF), plus these layouts:
  * **Google Takeout:** the `All mail Including Spam and Trash.mbox` file; its `X-Gmail-Labels` become folders (nested labels such as `Clients/ACME` nest), with the labels also shown per message. Multi-gigabyte files are scanned in one streaming pass.
  * **Thunderbird:** open the profile's `Mail` / `ImapMail` folder (or one mailbox file): extension-less mailboxes, `Name.sbd` subfolders, `.msf` indexes ignored. Messages flagged expunged in `X-Mozilla-Status` but still in the file (deleted, not yet compacted) are marked in the list.
  * **Apple Mail:** `Name.mbox` export bundles, nested bundles as subfolders.
  * Message boundaries are `From ` lines carrying a date and followed by a header line, so unescaped `From ` lines in bodies do not split messages. Messages are decoded from MIME (any charset, encoded words, base64 / quoted-printable, nested `message/rfc822`). `.eml` export writes the **original message bytes** (only the mbox separator line is dropped); `.msg` export converts. Reports list the SHA-256 of every source file.
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
* `src/headers.zig`, `src/headerreport.zig`: header analysis (triage and detailed) and its HTML / text reports.
* `src/namemap.zig`: PST named-property map; `src/itemview.zig`: calendar / contact / task / note / journal fields; `src/propview.zig`: all-properties view.
* `src/mime.zig`: RFC 5322 / MIME parsing (encoded words, parameters, dates, addresses, multipart bodies).
* `src/mbox.zig`: MBOX reader (Takeout labels, Thunderbird, Apple Mail); `src/multi.zig`: several PST/OST parts merged into one mailbox; `src/store.zig`: one interface over all sources.
* `src/export.zig`: EML and MSG (Compound File Binary) writers, CSV/HTML reports.
* `src/gui.zig`, `src/win.zig`: Win32 GUI and bindings.
* `src/cli.zig`: command line.

## Releases

GitHub Actions (`.github/workflows/build.yml`) builds every push and pull request on Windows and uploads the zip as a workflow artifact. Pushing a `v*` tag also publishes a GitHub release with `pstview-<tag>-windows-x64.zip` and `SHA256SUMS.txt`:

```
git tag v0.1.0
git push origin v0.1.0
```
