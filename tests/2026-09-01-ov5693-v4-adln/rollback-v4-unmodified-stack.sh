#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/rollback"
KVER="$(uname -r)"
TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"

mkdir -p "$STAGE"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Removing experimental modules only: $TARGET"
    echo "Removing experiment-owned initramfs hook only: $HOOK"
    echo
    echo "===== before ====="
    for name in ov5693 ipu_bridge intel_ipu6 intel_ipu6_isys; do
        printf '%s=' "$name"
        modinfo -n "$name" 2>/dev/null || true
    done
    echo
    echo "hook_present=$(sudo test -e "$HOOK" && echo YES || echo NO)"
} > "$STAGE/00-before.txt"

if sudo test -d "$TARGET"; then
    sudo rm -rf -- "$TARGET"
fi

if sudo test -e "$HOOK"; then
    if sudo grep -q '^# Surface Go 4 v4 test: include ADL-N IPU6 firmware$' "$HOOK"; then
        sudo rm -f -- "$HOOK"
    else
        echo "WARNING: $HOOK exists but does not contain the experiment marker; leaving it untouched." | tee "$STAGE/00-hook-warning.txt" >&2
    fi
fi

sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER" > "$STAGE/01-update-initramfs.txt" 2>&1

{
    echo "===== after ====="
    for name in ov5693 ipu_bridge intel_ipu6 intel_ipu6_isys; do
        printf '%s=' "$name"
        modinfo -n "$name" 2>/dev/null || true
    done
    echo
    echo "hook_present=$(sudo test -e "$HOOK" && echo YES || echo NO)"
    echo
    echo "===== initramfs ADL-N firmware entries ====="
    lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -E '(^|/)intel/ipu/ipu6epadln_fw\.bin(\.zst)?$' || true
} > "$STAGE/02-after.txt"

echo "Rollback complete. Ubuntu stock module and firmware files were never deleted."
echo "Reboot is required to replace any experimental modules already loaded in memory."
