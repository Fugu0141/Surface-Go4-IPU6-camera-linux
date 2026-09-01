#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/rollback"
KVER="$(uname -r)"
TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"

mkdir -p "$STAGE"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Removing only: $TARGET"
    echo
    echo "===== before ====="
    for name in ov5693 ipu_bridge intel_ipu6 intel_ipu6_isys; do
        printf '%s=' "$name"
        modinfo -n "$name" 2>/dev/null || true
    done
} > "$STAGE/00-before.txt"

if sudo test -d "$TARGET"; then
    sudo rm -rf -- "$TARGET"
fi

sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER" > "$STAGE/01-update-initramfs.txt" 2>&1

{
    echo "===== after ====="
    for name in ov5693 ipu_bridge intel_ipu6 intel_ipu6_isys; do
        printf '%s=' "$name"
        modinfo -n "$name" 2>/dev/null || true
    done
} > "$STAGE/02-after.txt"

echo "Rollback complete. Ubuntu stock module files were never deleted."
echo "Reboot is required to replace any experimental modules already loaded in memory."
