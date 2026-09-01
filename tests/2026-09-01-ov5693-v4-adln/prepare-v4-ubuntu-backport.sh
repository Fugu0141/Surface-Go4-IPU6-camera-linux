#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/backport-prep"
MSGID="20260831181858.325109-1-fernandorimoli11@gmail.com"
KVER="$(uname -r)"
WORK="$HOME/sg4-ov5693-v4-ubuntu-$KVER"
PATCH_ROOT="$WORK/patches"
SOURCE_PARENT="$WORK/source"
SRC_ARCHIVE="/usr/src/linux-source-7.0.0.tar.bz2"

mkdir -p "$STAGE"

if [ -e "$WORK" ]; then
    echo "ERROR: work directory already exists: $WORK" | tee "$STAGE/99-error.txt"
    echo "Move or remove it deliberately before rerunning." | tee -a "$STAGE/99-error.txt"
    exit 1
fi

mkdir -p "$PATCH_ROOT" "$SOURCE_PARENT"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Apply upstream OV5693 v4 semantics to Ubuntu 7.0.0-30.30 for the Surface Go 4 negative-control test"
    echo "Message-ID: $MSGID"
    echo "Kernel: $KVER"
    echo "Work directory: $WORK"
    echo "Known backport adjustment: patch 2 context differs because Ubuntu source lacks the OVTI5675 table entry used by the posted patch context."
} > "$STAGE/00-metadata.txt"

{
    echo '$ b4 am -C -v 4 -T -Q -o '"$PATCH_ROOT"' '"$MSGID"
    b4 am -C -v 4 -T -Q -o "$PATCH_ROOT" "$MSGID"
} > "$STAGE/01-b4-fetch.txt" 2>&1

SERIES_FILE="$(find "$PATCH_ROOT" -type f -name series -print -quit)"
if [ -z "$SERIES_FILE" ]; then
    echo "ERROR: series file not found" | tee "$STAGE/99-error.txt"
    exit 1
fi
SERIES_DIR="$(dirname "$SERIES_FILE")"
PATCH_COUNT="$(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE" | wc -l)"
if [ "$PATCH_COUNT" -ne 6 ]; then
    echo "ERROR: expected 6 patches, got $PATCH_COUNT" | tee "$STAGE/99-error.txt"
    exit 1
fi

{
    echo "series=$SERIES_FILE"
    echo "patch_count=$PATCH_COUNT"
    echo
    cat "$SERIES_FILE"
    echo
    echo "===== sha256 ====="
    cd "$SERIES_DIR"
    sha256sum $(grep -Ev '^[[:space:]]*(#|$)' series)
} > "$STAGE/02-series-and-sha256.txt"

tar -xf "$SRC_ARCHIVE" -C "$SOURCE_PARENT"
SRC="$(find "$SOURCE_PARENT" -mindepth 1 -maxdepth 1 -type d -name 'linux-source-*' -print -quit)"
if [ -z "$SRC" ]; then
    echo "ERROR: source directory not found" | tee "$STAGE/99-error.txt"
    exit 1
fi

echo "$SRC" > "$STAGE/03-source-path.txt"

mapfile -t PATCHES < <(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE")

# Patch 1: applies directly to Ubuntu 7.0.0-30.30.
{
    echo "===== APPLY ${PATCHES[0]} ====="
    patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/${PATCHES[0]}"
} > "$STAGE/04-patch1.txt" 2>&1

# Patch 2: record the original dry-run failure, then perform a minimal semantic backport.
{
    echo "===== ORIGINAL PATCH 2 DRY RUN ====="
    if patch -d "$SRC" -p1 --dry-run --batch --forward < "$SERIES_DIR/${PATCHES[1]}"; then
        echo "Unexpectedly applies directly; applying original patch."
        patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/${PATCHES[1]}"
        echo "patch2_mode=original"
    else
        echo
        echo "Original patch 2 does not apply because its context contains the OVTI5675 entry, which is absent from Ubuntu 7.0.0-30.30."
        echo "Applying the same two added lines between OVTI2680 and OVTI8856."
        python3 - "$SRC/drivers/media/pci/intel/ipu-bridge.c" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
if 'IPU_SENSOR_CONFIG("OVTI5693", 1, 419200000)' in s:
    raise SystemExit('OVTI5693 entry already present; refusing duplicate insertion')
needle = '\t/* Omnivision OV2680 */\n\tIPU_SENSOR_CONFIG("OVTI2680", 1, 331200000),\n\t/* Omnivision OV8856 */'
replacement = '\t/* Omnivision OV2680 */\n\tIPU_SENSOR_CONFIG("OVTI2680", 1, 331200000),\n\t/* Omnivision OV5693 */\n\tIPU_SENSOR_CONFIG("OVTI5693", 1, 419200000),\n\t/* Omnivision OV8856 */'
if needle not in s:
    raise SystemExit('Expected Ubuntu sensor-table anchor not found')
p.write_text(s.replace(needle, replacement, 1))
PY
        echo "patch2_mode=minimal-semantic-backport"
    fi
} > "$STAGE/05-patch2-backport.txt" 2>&1

cat > "$STAGE/06-backport-adjustment.md" <<'EOF'
# Ubuntu backport adjustment

Upstream v4 patch 2 does not apply textually to Ubuntu `linux-source-7.0.0` package `7.0.0-30.30` because the posted patch uses the existing `OVTI5675` table entry as context, while the Ubuntu source does not contain that entry.

The semantic change from patch 2 is only:

```c
/* Omnivision OV5693 */
IPU_SENSOR_CONFIG("OVTI5693", 1, 419200000),
```

For this test those exact two lines are inserted in sorted order between the existing `OVTI2680` and `OVTI8856` entries. No behavior from v4 is otherwise changed by this adjustment.

This means the test tree is a minimal Ubuntu backport of the posted v4 semantics, not a byte-for-byte textual application of all six mail patches.
EOF

# Patches 3-6 must apply unchanged. Stop immediately and preserve the log if any does not.
: > "$STAGE/07-patches3-6.txt"
for i in 2 3 4 5; do
    p="${PATCHES[$i]}"
    {
        echo "===== APPLY $p ====="
        patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/$p"
        echo
    } >> "$STAGE/07-patches3-6.txt" 2>&1 || {
        echo "ERROR: $p failed. See 07-patches3-6.txt" | tee "$STAGE/99-error.txt"
        find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print >> "$STAGE/99-error.txt" || true
        exit 1
    }
done

{
    echo "===== relevant v4 code ====="
    grep -RnsE \
        'OVTI5693|INT33BE|clock-noncontinuous|CSI2_CLK_NONCONTINUOUS|MIPI_CTRL00|PCI_DEVICE_ID_INTEL_IPU6EP_ADLN|PCI_DEVICE_ID_INTEL_IPU6EP_ADLP|PCI_DEVICE_ID_INTEL_IPU6' \
        "$SRC/drivers/media/i2c/ov5693.c" \
        "$SRC/drivers/media/pci/intel/ipu-bridge.c" \
        "$SRC/include/media" 2>/dev/null || true
} > "$STAGE/08-relevant-source-snippets.txt"

{
    echo "===== reject/orig files ====="
    find "$SRC" \( -name '*.rej' -o -name '*.orig' \) -print
    echo
    echo "===== expected Surface Go 4 negative-control condition ====="
    echo "The tree must contain ADL-P/TGL non-continuous-clock matches but no INT33BE + PCI_DEVICE_ID_INTEL_IPU6EP_ADLN match."
    echo
    echo "ADL-N definitions/usages:"
    grep -Rns 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' "$SRC/drivers/media/pci/intel" "$SRC/include" 2>/dev/null || true
} > "$STAGE/09-negative-control-check.txt"

cat > "$STAGE/README.md" <<EOF
# Ubuntu v4 semantic backport preparation

The linux-media v4 series was fetched by Message-ID and applied to a fresh Ubuntu 7.0.0-30.30 source tree.

Patch 2 required a context-only backport adjustment documented in \`06-backport-adjustment.md\`; patches 1 and 3-6 are applied from the posted patch files unchanged.

No module has been built, installed, loaded, or replaced by this script.

Patched source tree: \`$SRC\`
EOF

echo "Ubuntu v4 backport preparation complete."
echo "Logs: $STAGE"
echo "Patched source tree: $SRC"
echo "Next: inspect 07-patches3-6.txt, 08-relevant-source-snippets.txt, and 09-negative-control-check.txt."
