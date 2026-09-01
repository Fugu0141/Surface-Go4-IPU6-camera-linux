#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/initramfs-rebuild"
KVER="$(uname -r)"
INITRD="/boot/initrd.img-$KVER"
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"
EXPECTED='usr/lib/firmware/intel/ipu/ipu6epadln_fw.bin'

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
sudo test -x "$HOOK" || fail "firmware hook missing or not executable: $HOOK"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Initrd: $INITRD"
    echo "Hook: $HOOK"
    echo
    echo "===== hook recognition ====="
    sudo run-parts --test /etc/initramfs-tools/hooks | grep -F "$HOOK" || true
} > "$STAGE/00-before.txt"

sudo update-initramfs -u -k "$KVER" > "$STAGE/01-update-initramfs.txt" 2>&1

{
    echo "===== firmware entries ====="
    sudo lsinitramfs "$INITRD" | grep -Ei '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin(\.zst)?$|ipu6epadln' || true
    echo
    echo "===== lib symlink/layout ====="
    sudo lsinitramfs "$INITRD" | grep -E '^(lib|usr/lib)( ->|$)' || true
} > "$STAGE/02-after.txt"

if ! sudo lsinitramfs "$INITRD" | grep -qx "$EXPECTED"; then
    fail "ADL-N firmware not found at $EXPECTED in rebuilt initramfs"
fi

cat > "$STAGE/README.md" <<EOF
# v4 negative-control initramfs rebuild

The custom firmware hook was proven independently with \`mkinitramfs\` before this step. This script rebuilds the actual boot initramfs for \`$KVER\` and verifies that it contains:

\`$EXPECTED\`

No camera access is performed.
EOF

echo "Boot initramfs rebuilt successfully."
echo "Verified: $EXPECTED"
echo "REBOOT REQUIRED. Do not deliberately open or stream the camera before post-reboot verification."
