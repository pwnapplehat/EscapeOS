#!/bin/bash
# Compile and run the pure-Foundation logic tests on a Linux host (WSL) with the Theos Swift
# toolchain. Only files that import nothing but Foundation can be built here; UI code is
# covered by the on-device checklist instead.
#
#   tools/run-host-tests.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SW="${THEOS:-$HOME/theos}/toolchain/linux/host/bin"
[ -x "$SW/swiftc" ] || { echo "host swiftc not found under $SW (set THEOS)"; exit 2; }
# Some distros ship a newer libxml2/ICU than this toolchain links; a private dir can hold them.
[ -d "$HOME/swift-compat/root/usr/lib/x86_64-linux-gnu" ] &&
  export LD_LIBRARY_PATH="$HOME/swift-compat/root/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=("$ROOT"/Tests/HostTests/*.swift "$ROOT/EscapeOS/Engine/FileKind.swift" "$ROOT/EscapeOS/Engine/FileService.swift"
         "$ROOT/EscapeOS/Engine/DeleteConfirmation.swift"
         "$ROOT/EscapeOS/Engine/SpaceCheck.swift"
         "$ROOT/EscapeOS/Engine/PasteConflicts.swift")
SOURCES+=("$@")
"$SW/swiftc" -O -o "$OUT/host-tests" "${SOURCES[@]}" 2>&1 | grep -v "protected function" || true
[ -x "$OUT/host-tests" ] || { echo "COMPILE FAILED"; exit 1; }
"$OUT/host-tests"
