#!/bin/bash
# PictureZoom (iOSClient), the picture's zoom on the device (#65, #146): a pinch keeps what is under
# the fingers under them, the magnified picture always covers the view, a near-whole pinch snaps
# back, the edges move it, and a point maps through the zoomed rect to the same place in the video
# that the picture shows there. Then random pinches and pans against those invariants.
#   Tests/checks/picture-zoom/run.sh            compile and run the check
#   Tests/checks/picture-zoom/run.sh --mutants  one-line mutants of PictureZoom.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
swiftc -O "$root/iOSClient/PictureZoom.swift" "$here/main.swift" -o "$out/check" 2>&1 | grep -E "error" || true
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
