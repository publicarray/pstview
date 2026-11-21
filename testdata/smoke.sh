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

# a PST that pstview wrote from the demo mailbox (byte for byte the same on every platform:
# `zig build test` checks the writer against it), read back
pst="testdata/demo.pst"
run verify "$pst"
run tree "$pst"
run list "$pst" 0x80c2
run show "$pst" 0x2000a4
