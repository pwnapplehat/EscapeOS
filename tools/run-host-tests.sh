#!/bin/bash
# Compile and run the pure-Foundation logic tests on a Linux host (WSL) with the Theos Swift
# toolchain. Only files that import nothing but Foundation (and the zlib / SQLite3 system modules,
# which tools/host/modules provides for the host) can be built here; SwiftUI code is covered by the
# on-device checklist instead.
#
#   tools/run-host-tests.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SW="${THEOS:-$HOME/theos}/toolchain/linux/host/bin"
[ -x "$SW/swiftc" ] || { echo "host swiftc not found under $SW (set THEOS)"; exit 2; }
# Some distros ship a newer libxml2/ICU than this toolchain links; a private dir can hold them. The
# same dir can hold zlib and SQLite headers and libraries unpacked from the distro's -dev packages
# (apt-get download zlib1g-dev libsqlite3-dev, then dpkg-deb -x ... ~/swift-compat/root).
COMPAT="$HOME/swift-compat/root"
[ -d "$COMPAT/usr/lib/x86_64-linux-gnu" ] &&
  export LD_LIBRARY_PATH="$COMPAT/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Engine files under test. Each must import nothing the host lacks.
ENGINE=(FileKind FileService DeleteConfirmation SpaceCheck PasteConflicts ContainerSearch AppGroupListing FavoritesStore
        ProgressMeter JobQueue FileTransfer ZipWriter ShareStaging TrashStore
        BackupSelection ImportStaging SQLiteDatabase SQLiteWorkingCopy
        StreamingSHA256 ZipReader BackupPaths BackupArchiver BackupRestorer)

SOURCES=("$ROOT"/Tests/HostTests/*.swift)
for name in "${ENGINE[@]}"; do SOURCES+=("$ROOT/EscapeOS/Engine/$name.swift"); done
SOURCES+=("$@")

# HOST_OPT=-Onone makes a runtime trap print its message instead of just stopping.
FLAGS=(${HOST_OPT:--O} -I "$ROOT/tools/host/modules/zlib" -I "$ROOT/tools/host/modules/SQLite3" -I "$ROOT/tools/host/modules/CXattr")
if [ -d "$COMPAT/usr/include" ]; then
  FLAGS+=(-Xcc -I"$COMPAT/usr/include" -L"$COMPAT/usr/lib/x86_64-linux-gnu")
fi

"$SW/swiftc" "${FLAGS[@]}" -o "$OUT/host-tests" "${SOURCES[@]}" 2>&1 | grep -v "protected function" || true
[ -x "$OUT/host-tests" ] || { echo "COMPILE FAILED"; exit 1; }
"$OUT/host-tests"
