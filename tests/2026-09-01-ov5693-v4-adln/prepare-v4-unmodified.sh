#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified"
MSGID="20260831181858.325109-1-fernandorimoli11@gmail.com"
KVER="$(uname -r)"
WORK="$HOME/sg4-ov5693-v4-unmodified-$KVER"
PATCH_ROOT="$WORK/patches"
SOURCE_PARENT="$WORK/source"
SRC_ARCHIVE="/usr/src/linux-source-7.0.0.tar.bz2"

mkdir -p "$STAGE"

log_cmd() {
    local file="$1"
    shift
    {
        echo '$' "$@"
        "$@"
    } >"$STAGE/$file" 2>&1
}

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Prepare the upstream OV5693 v4 series exactly as posted for the Surface Go 4 ADL-N negative-control test"
    echo "Message-ID: $MSGID"
    echo "Kernel: $KVER"
    echo "Work directory: $WORK"
} > "$STAGE/00-metadata.txt"

# Refuse to overwrite an earlier experimental tree.
if [ -e "$WORK" ]; then
    echo "ERROR: work directory already exists: $WORK" | tee "$STAGE/99-error.txt"
    echo "Move or remove it deliberately before rerunning this script." | tee -a "$STAGE/99-error.txt"
    exit 1
fi

mkdir -p "$PATCH_ROOT" "$SOURCE_PARENT"

log_cmd "01-kernel-and-packages.txt" bash -lc '
    uname -a
    echo
    dpkg-query -W linux-image-"$(uname -r)" linux-headers-"$(uname -r)" linux-source-7.0.0
    echo
    readlink -f /usr/src/linux-source-7.0.0.tar.bz2
'

log_cmd "02-b4-version.txt" b4 --version

# Retrieve v4 specifically, without carrying later review trailers into the saved patches.
{
    echo '$ b4 am -C -v 4 -T -Q -o '"$PATCH_ROOT"' '"$MSGID"
    b4 am -C -v 4 -T -Q -o "$PATCH_ROOT" "$MSGID"
} >"$STAGE/03-b4-fetch.txt" 2>&1

SERIES_FILE="$(find "$PATCH_ROOT" -type f -name series -print -quit)"
if [ -z "$SERIES_FILE" ]; then
    echo "ERROR: b4 did not create a quilt-ready series file." | tee "$STAGE/99-error.txt"
    find "$PATCH_ROOT" -maxdepth 3 -type f -printf '%P\n' | sort >> "$STAGE/99-error.txt"
    exit 1
fi
SERIES_DIR="$(dirname "$SERIES_FILE")"

PATCH_COUNT="$(grep -Ev '^[[:space:]]*(#|$)' "$SERIES_FILE" | wc -l)"
{
    echo "series_file=$SERIES_FILE"
    echo "series_dir=$SERIES_DIR"
    echo "patch_count=$PATCH_COUNT"
    echo
    echo "===== series ====="
    cat "$SERIES_FILE"
    echo
    echo "===== files ====="
    find "$SERIES_DIR" -maxdepth 1 -type f -printf '%f\n' | sort
} > "$STAGE/04-series.txt"

if [ "$PATCH_COUNT" -ne 6 ]; then
    echo "ERROR: expected 6 patches, got $PATCH_COUNT" | tee "$STAGE/99-error.txt"
    exit 1
fi

mkdir -p "$STAGE/patches"
cp -a "$SERIES_DIR"/. "$STAGE/patches/"
(
    cd "$STAGE/patches"
    sha256sum $(grep -Ev '^[[:space:]]*(#|$)' series)
) > "$STAGE/05-patch-sha256.txt"

# Extract a fresh copy of the Ubuntu source matching the running kernel package.
tar -xf "$SRC_ARCHIVE" -C "$SOURCE_PARENT"
SRC="$(find "$SOURCE_PARENT" -mindepth 1 -maxdepth 1 -type d -name 'linux-source-*' -print -quit)"
if [ -z "$SRC" ]; then
    echo "ERROR: extracted kernel source directory not found." | tee "$STAGE/99-error.txt"
    exit 1
fi

echo "$SRC" > "$STAGE/06-source-path.txt"

# Apply the six quilt-ready patches in exactly the order b4 produced.
{
    echo "source=$SRC"
    echo "series=$SERIES_FILE"
    echo
    while IFS= read -r patch_name; do
        case "$patch_name" in
            ''|'#'*) continue ;;
        esac
        echo "===== APPLY $patch_name ====="
        patch -d "$SRC" -p1 --batch --forward < "$SERIES_DIR/$patch_name"
        echo
    done < "$SERIES_FILE"
} > "$STAGE/07-apply-patches.txt" 2>&1

# Record subjects and all files touched by the posted v4 series.
{
    echo "===== patch subjects ====="
    while IFS= read -r patch_name; do
        case "$patch_name" in
            ''|'#'*) continue ;;
        esac
        printf '%s: ' "$patch_name"
        grep -m1 '^Subject:' "$SERIES_DIR/$patch_name" || true
    done < "$SERIES_FILE"
    echo
    echo "===== touched files ====="
    while IFS= read -r patch_name; do
        case "$patch_name" in
            ''|'#'*) continue ;;
        esac
        grep '^+++ b/' "$SERIES_DIR/$patch_name" | sed 's#^+++ b/##'
    done < "$SERIES_FILE" | sort -u
} > "$STAGE/08-series-summary.txt"

# Capture the exact relevant code after applying unmodified v4.
{
    echo "===== clock-noncontinuous / MIPI_CTRL00 / IPU match snippets ====="
    grep -RnsE \
        'clock-noncontinuous|CSI2_CLK_NONCONTINUOUS|MIPI_CTRL00|PCI_DEVICE_ID_INTEL_IPU6EP_ADLN|PCI_DEVICE_ID_INTEL_IPU6EP_ADLP|PCI_DEVICE_ID_INTEL_IPU6' \
        "$SRC/drivers/media/i2c/ov5693.c" \
        "$SRC/drivers/media/pci/intel/ipu-bridge.c" \
        "$SRC/include/media" 2>/dev/null || true
} > "$STAGE/09-relevant-source-snippets.txt"

cat > "$STAGE/README.md" <<EOF
# v4 unmodified preparation

This stage contains the exact upstream v4 series retrieved from linux-media with b4 and applied, unmodified, to a fresh Ubuntu linux-source-7.0.0 tree matching the running kernel package.

- Message-ID: \`$MSGID\`
- Kernel: \`$KVER\`
- Work tree: \`$SRC\`
- Patch count: \`$PATCH_COUNT\`

No kernel modules were built, installed, loaded, or replaced by this script. The next step is to inspect the changed files and then build only the modules required for the negative-control test.
EOF

echo "Preparation complete."
echo "Logs: $STAGE"
echo "Patched source tree: $SRC"
echo "Next: inspect 08-series-summary.txt and 09-relevant-source-snippets.txt before building anything."
