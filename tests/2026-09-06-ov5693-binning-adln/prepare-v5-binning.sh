#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/06-v5-binning-prep"
MSGID="20260902142322.73523-1-fernandorimoli11@gmail.com"
KVER="$(uname -r)"
WORK="$HOME/sg4-ov5693-v5-binning-ubuntu-$KVER"
PATCH_ROOT="$WORK/v5-patches"
SOURCE_PARENT="$WORK/source"
SRC_ARCHIVE="/usr/src/linux-source-7.0.0.tar.bz2"
BIN_PATCH="$WORK/ov5693-binned-no-mipictrl.patch"
BIN_PATCH_URL="https://raw.githubusercontent.com/dmanresa-saes/surface-ipu6-cameras/master/patches/ov5693-binned-no-mipictrl.patch"
BIN_PATCH_COMMIT="548281df0983aa0b4e15c923e97d122419787078"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
[ -f "$SRC_ARCHIVE" ] || fail "Ubuntu kernel source archive missing: $SRC_ARCHIVE"
command -v b4 >/dev/null || fail "b4 is not installed"
command -v patch >/dev/null || fail "patch is not installed"
command -v python3 >/dev/null || fail "python3 is not installed"

if [ -e "$WORK" ]; then
    fail "work directory already exists: $WORK (move/remove it deliberately before rerunning)"
fi

mkdir -p "$PATCH_ROOT" "$SOURCE_PARENT"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: prepare Fernando Rimoli OV5693 v5 plus D. Manresa 2x2-binning patch"
    echo "Kernel: $KVER"
    echo "v5 Message-ID: $MSGID"
    echo "Binning patch URL: $BIN_PATCH_URL"
    echo "Expected binning patch header commit: $BIN_PATCH_COMMIT"
    echo "No modules are built, installed, or loaded by this script."
} > "$STAGE/00-metadata.txt"

{
    echo '$ b4 am -C -v 5 -T -Q -o '"$PATCH_ROOT"' '"$MSGID"
    b4 am -C -v 5 -T -Q -o "$PATCH_ROOT" "$MSGID"
} > "$STAGE/01-b4-fetch.txt" 2>&1

SERIES_FILE="$(find "$PATCH_ROOT" -type f -name series -print -quit)"
[ -n "$SERIES_FILE" ] || fail "v5 series file not found"
SERIES_DIR="$(dirname "$SERIES_FILE")"
PATCH_COUNT="$(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE" | wc -l)"
[ "$PATCH_COUNT" -eq 7 ] || fail "expected 7 v5 patches, got $PATCH_COUNT"

{
    echo "series=$SERIES_FILE"
    echo "patch_count=$PATCH_COUNT"
    echo
    cat "$SERIES_FILE"
    echo
    echo "===== sha256 ====="
    cd "$SERIES_DIR"
    sha256sum $(grep -Ev '^[[:space:]]*(#|$)' series)
} > "$STAGE/02-v5-series-and-sha256.txt"

tar -xf "$SRC_ARCHIVE" -C "$SOURCE_PARENT"
SRC="$(find "$SOURCE_PARENT" -mindepth 1 -maxdepth 1 -type d -name 'linux-source-*' -print -quit)"
[ -n "$SRC" ] || fail "source directory not found after extracting $SRC_ARCHIVE"
echo "$SRC" > "$STAGE/03-source-path.txt"

mapfile -t PATCHES < <(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE")

# v5 patch 1 applies directly to Ubuntu 7.0.0-30.30.
{
    echo "===== APPLY ${PATCHES[0]} ====="
    patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/${PATCHES[0]}"
} > "$STAGE/04-v5-patch1.txt" 2>&1

# v5 patch 2 may fail textually because Ubuntu 7.0 lacks the OVTI5675 line
# used as surrounding context. If so, perform the same minimal semantic
# backport that was used and documented for the earlier v4 validation.
{
    echo "===== ORIGINAL V5 PATCH 2 DRY RUN ====="
    if patch -d "$SRC" -p1 --dry-run --batch --forward < "$SERIES_DIR/${PATCHES[1]}"; then
        echo "Patch 2 applies directly; applying original patch."
        patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/${PATCHES[1]}"
        echo "patch2_mode=original"
    else
        echo
        echo "Patch 2 does not apply textually; inserting the exact OVTI5693 sensor-table entry."
        python3 - "$SRC/drivers/media/pci/intel/ipu-bridge.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
entry = 'IPU_SENSOR_CONFIG("OVTI5693", 1, 419200000)'
if entry in s:
    raise SystemExit('OVTI5693 entry already present; refusing duplicate insertion')
needle = '\t/* Omnivision OV2680 */\n\tIPU_SENSOR_CONFIG("OVTI2680", 1, 331200000),\n\t/* Omnivision OV8856 */'
replacement = '\t/* Omnivision OV2680 */\n\tIPU_SENSOR_CONFIG("OVTI2680", 1, 331200000),\n\t/* Omnivision OV5693 */\n\tIPU_SENSOR_CONFIG("OVTI5693", 1, 419200000),\n\t/* Omnivision OV8856 */'
if needle not in s:
    raise SystemExit('Expected Ubuntu sensor-table anchor not found')
p.write_text(s.replace(needle, replacement, 1))
PY
        echo "patch2_mode=minimal-semantic-backport"
    fi
} > "$STAGE/05-v5-patch2-backport.txt" 2>&1

# v5 patches 3-7 should apply unchanged. Stop and preserve rejects if not.
: > "$STAGE/06-v5-patches3-7.txt"
for i in 2 3 4 5 6; do
    p="${PATCHES[$i]}"
    {
        echo "===== APPLY $p ====="
        patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/$p"
        echo
    } >> "$STAGE/06-v5-patches3-7.txt" 2>&1 || {
        echo "ERROR: $p failed. See 06-v5-patches3-7.txt" | tee "$STAGE/99-error.txt"
        find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print >> "$STAGE/99-error.txt" || true
        exit 1
    }
done

# Fetch the exact no-MIPI_CTRL binning patch provided for this test.
python3 - "$BIN_PATCH_URL" "$BIN_PATCH" <<'PY'
from pathlib import Path
from urllib.request import urlopen
import sys
url, out = sys.argv[1], Path(sys.argv[2])
with urlopen(url, timeout=30) as r:
    data = r.read()
out.write_bytes(data)
PY

{
    echo "===== binning patch identity ====="
    head -n 8 "$BIN_PATCH"
    echo
    sha256sum "$BIN_PATCH"
} > "$STAGE/07-binning-patch-identity.txt"

grep -q "^From $BIN_PATCH_COMMIT " "$BIN_PATCH" || fail "unexpected binning patch header commit"

{
    echo "===== BINNING PATCH DRY RUN ====="
    patch -d "$SRC" -p1 --dry-run --batch --forward < "$BIN_PATCH"
    echo
    echo "===== APPLY BINNING PATCH ====="
    patch -d "$SRC" -p1 --batch --forward < "$BIN_PATCH"
} > "$STAGE/08-binning-patch-apply.txt" 2>&1 || {
    echo "ERROR: binning patch did not apply cleanly; see 08-binning-patch-apply.txt" | tee "$STAGE/99-error.txt"
    find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print >> "$STAGE/99-error.txt" || true
    exit 1
}

{
    echo "===== reject/orig files ====="
    find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print
    echo
    echo "===== required source markers ====="
    grep -RnsE \
        'binned_y_offset|ov5693_mode_binned_regs|CSI2_CLK_NONCONTINUOUS|IPU6EP_ADLN|clock-noncontinuous|MIPI_CTRL00' \
        "$SRC/drivers/media/i2c/ov5693.c" \
        "$SRC/drivers/media/pci/intel/ipu-bridge.c" \
        "$SRC/include/media/ipu-bridge.h" 2>/dev/null || true
} > "$STAGE/09-source-proof.txt"

python3 - "$SRC/drivers/media/i2c/ov5693.c" "$SRC/drivers/media/pci/intel/ipu-bridge.c" <<'PY' > "$STAGE/10-semantic-checks.txt"
from pathlib import Path
import re
import sys
ov = Path(sys.argv[1]).read_text()
br = Path(sys.argv[2]).read_text()
checks = {
    'binning module parameter present': 'binned_y_offset' in ov,
    'binned per-mode register table present': 'ov5693_mode_binned_regs' in ov,
    'non-continuous clock gate logic present': 'NONCONTINUOUS_CLOCK' in ov and 'MIPI_CTRL00' in ov,
    'ADL-N IPU ID present in bridge': 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' in br,
    'clock-noncontinuous property present': 'clock-noncontinuous' in br,
}
for name, ok in checks.items():
    print(f'{name}: {"PASS" if ok else "FAIL"}')
if not all(checks.values()):
    raise SystemExit(1)

# The test patch must not add the old unconditional full-register 0x2d write.
# A textual 0x2d elsewhere would be suspicious and should be reviewed manually.
for m in re.finditer(r'0x2d', ov, re.IGNORECASE):
    line = ov.count('\n', 0, m.start()) + 1
    print(f'NOTE: textual 0x2d found in ov5693.c at line {line}; inspect before testing')
PY

cat > "$STAGE/README.md" <<EOF
# v5 + OV5693 2x2-binning source preparation

This directory records preparation of Fernando Rimoli's v5 series
(\`$MSGID\`) on Ubuntu \`7.0.0-30-generic\`, followed by D. Manresa's
\`ov5693-binned-no-mipictrl.patch\` (\`$BIN_PATCH_COMMIT\`).

The script deliberately does **not** build, install, or load modules.

Prepared source tree:

\`$SRC\`

Review \`06-v5-patches3-7.txt\`, \`08-binning-patch-apply.txt\`,
\`09-source-proof.txt\`, and \`10-semantic-checks.txt\` before building.
EOF

echo "v5 + binning source preparation complete."
echo "Logs: $STAGE"
echo "Prepared source: $SRC"
echo "Nothing was built, installed, or loaded."
