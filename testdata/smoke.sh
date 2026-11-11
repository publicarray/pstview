#!/usr/bin/env bash
# Runs pstx over the fictional demo mailbox and prints everything to stdout. CI runs this on
# Windows, macOS and Linux and requires identical output (time zone UTC); with
# TZ=Australia/Sydney the macOS / Linux output must also match smoke-sydney.txt, which was
# produced on Windows in that zone - so local-time (DST) handling agrees across platforms.
#
#   bash testdata/smoke.sh zig-out/bin/pstx            (run from the repository root)
set -euo pipefail
pstx="$1"
demo="testdata/demo-mailbox"
run() {
  echo "== pstx $*"
  "$pstx" "$@" 2>&1
}
run tree "$demo"
for f in Inbox Sent Drafts Junk Archive; do run list "$demo" "$f"; done
for n in 3 4 5 6 7 8 9 a; do run show "$demo" "0x$n"; done
run headers "$demo" 0x4
run triage "$demo" Inbox
run search "$demo" Inbox "from:*harbourline*"

# export: MBOX items are written byte for byte, so the hashes match everywhere
out=$(mktemp -d)
"$pstx" export "$demo" Inbox "$out" eml > /dev/null
echo "== pstx export $demo Inbox <dir> eml"
if command -v sha256sum > /dev/null; then sum() { sha256sum "$1" | cut -d' ' -f1; }; else sum() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
(cd "$out" && for f in *.eml; do echo "$(sum "$f")  $f"; done | LC_ALL=C sort -k2)
rm -rf "$out"
