#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/initramfs-stack-hook"
KVER="$(uname -r)"
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"
TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
TMP_INIT="/tmp/sg4-v4-stack-hook-proof-$KVER"
FW_ZST=""

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
command -v mkinitramfs >/dev/null 2>&1 || fail "mkinitramfs missing"
command -v lsinitramfs >/dev/null 2>&1 || fail "lsinitramfs missing"
command -v zstdcat >/dev/null 2>&1 || fail "zstdcat missing"
[ -r /usr/share/initramfs-tools/hook-functions ] || fail "initramfs-tools hook-functions missing"

for candidate in \
    /usr/lib/firmware/intel/ipu/ipu6epadln_fw.bin.zst \
    /lib/firmware/intel/ipu/ipu6epadln_fw.bin.zst; do
    if [ -r "$candidate" ]; then
        FW_ZST="$candidate"
        break
    fi
done
[ -n "$FW_ZST" ] || fail "compressed ADL-N firmware not found"

modules=(
  "ov5693:ov5693.ko"
  "ipu_bridge:ipu-bridge.ko"
  "intel_ipu6:intel-ipu6.ko"
  "intel_ipu6_isys:intel-ipu6-isys.ko"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Hook: $HOOK"
    echo "Expected experimental directory: $TARGET"
    echo "Firmware source: $FW_ZST"
    echo
    echo "===== current module resolution ====="
    for item in "${modules[@]}"; do
        name="${item%%:*}"
        file="${item#*:}"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        echo "$name=$resolved"
        [ "$resolved" = "$TARGET/$file" ] || fail "$name does not resolve to experimental module: $resolved"
    done
} > "$STAGE/00-before.txt"

if sudo test -e "$HOOK"; then
    if sudo grep -q '^# Surface Go 4 v4 test: include ADL-N IPU6 firmware and experimental camera stack$' "$HOOK"; then
        :
    elif sudo grep -q '^# Surface Go 4 v4 test: include ADL-N IPU6 firmware$' "$HOOK"; then
        :
    else
        fail "refusing to overwrite unrelated hook: $HOOK"
    fi
fi

TMP_HOOK="$(mktemp)"
cleanup() {
    rm -f "$TMP_HOOK" 2>/dev/null || true
    sudo rm -f "$TMP_INIT" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$TMP_HOOK" <<'EOF'
#!/bin/sh
set -e

# Surface Go 4 v4 test: include ADL-N IPU6 firmware and experimental camera stack
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

. /usr/share/initramfs-tools/hook-functions

# Force the exact module names into the image. depmod on the host already
# resolves these names to the experimental updates/ directory.
manual_add_modules ov5693
manual_add_modules ipu_bridge
manual_add_modules intel_ipu6
manual_add_modules intel_ipu6_isys

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

{
    echo "===== installed hook ====="
    sudo cat "$HOOK"
} > "$STAGE/01-installed-hook.txt"

sudo rm -f "$TMP_INIT"
sudo mkinitramfs -v -o "$TMP_INIT" "$KVER" > "$STAGE/02-mkinitramfs.txt" 2>&1
sudo lsinitramfs "$TMP_INIT" > "$STAGE/03-temp-contents.txt"

if ! grep -Eq '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$' "$STAGE/03-temp-contents.txt"; then
    fail "temporary initramfs is missing raw ADL-N firmware"
fi

for item in "${modules[@]}"; do
    file="${item#*:}"
    if ! grep -Fq "sg4-ov5693-v4-unmodified/$file" "$STAGE/03-temp-contents.txt"; then
        fail "temporary initramfs is missing experimental module: $file"
    fi
done

{
    echo "===== firmware ====="
    grep -E '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$' "$STAGE/03-temp-contents.txt"
    echo
    echo "===== experimental modules ====="
    grep -F 'sg4-ov5693-v4-unmodified/' "$STAGE/03-temp-contents.txt" | sort -u
    echo
    echo "===== copy evidence from mkinitramfs ====="
    grep -F 'sg4-ov5693-v4-unmodified/' "$STAGE/02-mkinitramfs.txt" | sort -u || true
} > "$STAGE/04-proof.txt"

cat > "$STAGE/README.md" <<EOF
# initramfs stack hook proof

The initramfs hook now explicitly adds both the ADL-N IPU6 firmware and the four experimental modules by module name. A temporary initramfs was generated and verified before any boot image replacement.

No file under /boot was changed by this script.
EOF

echo "Enhanced initramfs hook installed and proven in a temporary image."
echo "Firmware and all four experimental modules are present."
echo "No /boot file was changed."
echo "Next: rerun install-verified-initramfs-direct.sh"
