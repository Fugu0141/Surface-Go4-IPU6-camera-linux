#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/initramfs-firmware"
KVER="$(uname -r)"
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"
FW_REL="intel/ipu/ipu6epadln_fw.bin"
FW_ZST=""

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"

for candidate in \
    "/usr/lib/firmware/${FW_REL}.zst" \
    "/lib/firmware/${FW_REL}.zst"; do
    if [ -f "$candidate" ]; then
        FW_ZST="$candidate"
        break
    fi
done

[ -n "$FW_ZST" ] || fail "compressed ADL-N firmware not found"
command -v zstdcat >/dev/null 2>&1 || fail "zstdcat is required"
command -v lsinitramfs >/dev/null 2>&1 || fail "lsinitramfs is required"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Add the Surface Go 4 ADL-N IPU6 firmware to initramfs for the v4 negative-control boot"
    echo "Kernel: $KVER"
    echo "Source firmware: $FW_ZST"
    echo "Initramfs firmware path: lib/firmware/$FW_REL"
    echo "Hook: $HOOK"
    echo
    echo "===== source compressed firmware ====="
    ls -lh "$FW_ZST"
    sha256sum "$FW_ZST"
    echo
    echo "===== decompressed firmware hash ====="
    zstdcat "$FW_ZST" | sha256sum
    echo
    echo "===== before initramfs matches ====="
    sudo lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -E '(^|/)intel/ipu/ipu6epadln_fw\.bin(\.zst)?$' || true
} > "$STAGE/00-before.txt"

if sudo test -e "$HOOK"; then
    if sudo grep -q '^# Surface Go 4 v4 test: include ADL-N IPU6 firmware$' "$HOOK"; then
        :
    else
        fail "refusing to overwrite pre-existing unrelated hook: $HOOK"
    fi
fi

TMP_HOOK="$(mktemp)"
trap 'rm -f "$TMP_HOOK"' EXIT
cat > "$TMP_HOOK" <<'EOF'
#!/bin/sh
set -e

# Surface Go 4 v4 test: include ADL-N IPU6 firmware
PREREQ=""

prereqs()
{
    echo "$PREREQ"
}

case "${1:-}" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

FW="/usr/lib/firmware/intel/ipu/ipu6epadln_fw.bin.zst"
if [ ! -r "$FW" ]; then
    FW="/lib/firmware/intel/ipu/ipu6epadln_fw.bin.zst"
fi

if [ ! -r "$FW" ]; then
    echo "sg4-ipu6-adln-firmware: source firmware missing" >&2
    exit 1
fi

DEST="$DESTDIR/lib/firmware/intel/ipu"
mkdir -p "$DEST"
zstdcat "$FW" > "$DEST/ipu6epadln_fw.bin"
chmod 0644 "$DEST/ipu6epadln_fw.bin"
EOF

sudo install -m 0755 "$TMP_HOOK" "$HOOK"
sudo update-initramfs -u -k "$KVER" > "$STAGE/01-update-initramfs.txt" 2>&1

{
    echo "===== installed hook ====="
    sudo cat "$HOOK"
    echo
    echo "===== after initramfs matches ====="
    sudo lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -E '(^|/)intel/ipu/ipu6epadln_fw\.bin(\.zst)?$' || true
} > "$STAGE/02-after.txt"

if ! sudo lsinitramfs "/boot/initrd.img-$KVER" 2>/dev/null | grep -qE '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$'; then
    fail "raw ADL-N firmware was not found in rebuilt initramfs; inspect 01-update-initramfs.txt and 02-after.txt"
fi

cat > "$STAGE/README.md" <<EOF
# initramfs firmware fix for v4 negative control

The experimental IPU6 module is selected early during boot. Its ADL-N firmware exists on the root filesystem as a zstd-compressed file, but was absent from the initramfs, so early probe failed with ENOENT.

This stage installs a narrowly scoped initramfs-tools hook at:

\`$HOOK\`

The hook decompresses only:

\`$FW_ZST\`

into the initramfs as:

\`/lib/firmware/$FW_REL\`

No firmware file on the root filesystem is modified or replaced. Reboot is required before repeating post-reboot verification. Do not deliberately stream the camera before verification.
EOF

echo "Initramfs firmware fix installed successfully."
echo "Verified in: /boot/initrd.img-$KVER"
echo "REBOOT REQUIRED. Do not test the camera before post-reboot verification."
