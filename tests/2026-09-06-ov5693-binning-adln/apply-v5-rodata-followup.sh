#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/08-v5-rodata-followup"
KVER="$(uname -r)"
SRC="$HOME/sg4-ov5693-v5-binning-ubuntu-$KVER/source/linux-source-7.0.0"
MSGID="20260913193840.75686-1-fernandorimoli11@gmail.com"
WORK="$HOME/sg4-ov5693-v5-rodata-followup-$KVER"
PATCH_ROOT="$WORK/patches"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
[ -f "$SRC/drivers/media/pci/intel/ipu-bridge.c" ] || fail "prepared v5+binning source missing; run prepare-v5-binning.sh first"
[ -f "$SRC/include/media/ipu-bridge.h" ] || fail "prepared ipu-bridge header missing"
command -v b4 >/dev/null || fail "b4 is not installed"
command -v patch >/dev/null || fail "patch is not installed"

if [ -e "$WORK" ]; then
    fail "work directory already exists: $WORK (move/remove it deliberately before rerunning)"
fi
mkdir -p "$PATCH_ROOT"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: apply Fernando Rimoli follow-up fixing clock-noncontinuous property-name lifetime"
    echo "Kernel: $KVER"
    echo "Source: $SRC"
    echo "Message-ID: $MSGID"
    echo "No modules are built, installed, or loaded by this script."
} > "$STAGE/00-metadata.txt"

{
    echo '$ b4 am -T -Q -o '"$PATCH_ROOT"' '"$MSGID"
    b4 am -T -Q -o "$PATCH_ROOT" "$MSGID"
} > "$STAGE/01-b4-fetch.txt" 2>&1

SERIES_FILE="$(find "$PATCH_ROOT" -type f -name series -print -quit)"
[ -n "$SERIES_FILE" ] || fail "follow-up series file not found"
SERIES_DIR="$(dirname "$SERIES_FILE")"
mapfile -t PATCHES < <(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE")
[ "${#PATCHES[@]}" -eq 1 ] || fail "expected exactly 1 follow-up patch, got ${#PATCHES[@]}"
PATCH_FILE="$SERIES_DIR/${PATCHES[0]}"

{
    echo "series=$SERIES_FILE"
    echo "patch=${PATCHES[0]}"
    echo
    sed -n '1,60p' "$PATCH_FILE"
    echo
    echo "===== sha256 ====="
    sha256sum "$PATCH_FILE"
} > "$STAGE/02-patch-identity.txt"

cp "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$STAGE/ipu-bridge.before.c"
cp "$SRC/include/media/ipu-bridge.h" "$STAGE/ipu-bridge.before.h"

{
    echo "===== DRY RUN ====="
    patch -d "$SRC" -p1 --dry-run --batch --forward < "$PATCH_FILE"
    echo
    echo "===== APPLY ====="
    patch -d "$SRC" -p1 --batch --forward < "$PATCH_FILE"
} > "$STAGE/03-apply.txt" 2>&1

{
    echo "===== ipu-bridge.c delta ====="
    diff -u "$STAGE/ipu-bridge.before.c" "$SRC/drivers/media/pci/intel/ipu-bridge.c" || true
    echo
    echo "===== ipu-bridge.h delta ====="
    diff -u "$STAGE/ipu-bridge.before.h" "$SRC/include/media/ipu-bridge.h" || true
} > "$STAGE/04-source-delta.diff"

{
    echo "===== lifetime-safe property-name evidence ====="
    grep -Rns -E 'clock_noncontinuous|clock-noncontinuous' \
        "$SRC/drivers/media/pci/intel/ipu-bridge.c" \
        "$SRC/include/media/ipu-bridge.h" || true
} > "$STAGE/05-source-proof.txt"

python3 - "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$SRC/include/media/ipu-bridge.h" > "$STAGE/06-semantic-checks.txt" <<'PY'
from pathlib import Path
import re, sys
c = Path(sys.argv[1]).read_text()
h = Path(sys.argv[2]).read_text()
checks = {
    'property name stored in ipu_property_names': 'clock_noncontinuous' in h,
    'PROPERTY_ENTRY_BOOL uses sensor-owned name': bool(re.search(r'PROPERTY_ENTRY_BOOL\s*\(\s*sensor->prop_names\.clock_noncontinuous\s*\)', c)),
    'unsafe literal PROPERTY_ENTRY_BOOL removed': 'PROPERTY_ENTRY_BOOL("clock-noncontinuous")' not in c,
    'ADL-N entry still present': 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' in c,
}
for name, ok in checks.items():
    print(f'{name}: {"PASS" if ok else "FAIL"}')
if not all(checks.values()):
    raise SystemExit(1)
PY

cat > "$STAGE/README.md" <<EOF
# v5 clock-noncontinuous property-name lifetime follow-up

Applies Fernando Rimoli's follow-up patch identified by Message-ID:

\`$MSGID\`

This fixes the v5 endpoint property name so the registered software node does not retain a pointer into ipu-bridge module rodata after unload.

No module was built, installed, loaded, or replaced by this script.
EOF

echo "v5 rodata follow-up applied successfully."
echo "Nothing was built, installed, or loaded."
echo "Logs: $STAGE"
