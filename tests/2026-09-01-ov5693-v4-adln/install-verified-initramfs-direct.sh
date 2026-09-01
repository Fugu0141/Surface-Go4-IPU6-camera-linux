#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/initramfs-direct-install"
KVER="$(uname -r)"
BOOT_LINK="/boot/initrd.img-$KVER"
BOOT_TARGET="$(readlink -f "$BOOT_LINK")"
TMP_DIR=""
TMP_INIT=""
BACKUP_DIR="/var/lib/sg4-ov5693-v4-backup"
BACKUP="$BACKUP_DIR/initrd.img-$KVER.pre-direct"
EXPECTED_FW_RE='(^|/)usr/lib/firmware/intel/ipu/ipu6epadln_fw\.bin$|(^|/)lib/firmware/intel/ipu/ipu6epadln_fw\.bin$'
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

cleanup() {
    if [ -n "${TMP_DIR:-}" ]; then
        sudo rm -rf -- "$TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
[ -n "$BOOT_TARGET" ] || fail "could not resolve $BOOT_LINK"
sudo test -f "$BOOT_TARGET" || fail "boot initrd target missing: $BOOT_TARGET"
sudo test -x "$HOOK" || fail "firmware hook missing or not executable: $HOOK"
command -v mkinitramfs >/dev/null 2>&1 || fail "mkinitramfs missing"
command -v lsinitramfs >/dev/null 2>&1 || fail "lsinitramfs missing"

# Use a fresh root-owned directory each run so stale /tmp files can never block the test.
TMP_DIR="$(sudo mktemp -d "/var/tmp/sg4-v4-verified-initramfs-$KVER.XXXXXX")"
TMP_INIT="$TMP_DIR/initrd.img"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Boot link: $BOOT_LINK"
    echo "Boot target: $BOOT_TARGET"
    echo "Temporary directory: $TMP_DIR"
    echo "Temporary image: $TMP_INIT"
    echo "Backup: $BACKUP"
    echo
    echo "===== current boot image ====="
    sudo ls -lh "$BOOT_LINK" "$BOOT_TARGET" 2>/dev/null || true
    sudo sha256sum "$BOOT_TARGET"
    echo
    echo "===== current firmware entry ====="
    sudo lsinitramfs "$BOOT_TARGET" | grep -Ei 'ipu6epadln|intel/ipu' || true
} > "$STAGE/00-before.txt"

# Build a completely separate image first. Nothing under /boot is changed here.
sudo mkinitramfs -v -o "$TMP_INIT" "$KVER" > "$STAGE/01-mkinitramfs.txt" 2>&1
sudo chown root:root "$TMP_INIT"
sudo chmod 0600 "$TMP_INIT"

# Capture and verify the exact contents before installation.
sudo lsinitramfs "$TMP_INIT" > "$STAGE/02-temp-contents.txt"

if ! grep -Eq "$EXPECTED_FW_RE" "$STAGE/02-temp-contents.txt"; then
    fail "verified temporary initramfs does not contain raw ADL-N firmware"
fi

for needle in \
    'sg4-ov5693-v4-unmodified/ov5693.ko' \
    'sg4-ov5693-v4-unmodified/ipu-bridge.ko' \
    'sg4-ov5693-v4-unmodified/intel-ipu6.ko' \
    'sg4-ov5693-v4-unmodified/intel-ipu6-isys.ko'; do
    if ! grep -Fq "$needle" "$STAGE/02-temp-contents.txt"; then
        fail "verified temporary initramfs is missing experimental module: $needle"
    fi
done

{
    echo "===== firmware ====="
    grep -E "$EXPECTED_FW_RE" "$STAGE/02-temp-contents.txt"
    echo
    echo "===== experimental modules ====="
    grep -F 'sg4-ov5693-v4-unmodified/' "$STAGE/02-temp-contents.txt" | sort -u
    echo
    echo "===== temporary image ====="
    sudo ls -lh "$TMP_INIT"
    sudo sha256sum "$TMP_INIT"
} > "$STAGE/03-temp-verification.txt"

# Preserve the current working boot image on the root filesystem before replacement.
sudo install -d -m 0700 "$BACKUP_DIR"
if ! sudo test -f "$BACKUP"; then
    sudo cp --reflink=auto --preserve=mode,timestamps "$BOOT_TARGET" "$BACKUP"
fi
sudo sha256sum "$BACKUP" > "$STAGE/04-backup-sha256.txt"

# Install next to the real target, then atomically rename over it.
NEW_TARGET="${BOOT_TARGET}.sg4-new"
sudo rm -f "$NEW_TARGET"
sudo install -m 0600 -o root -g root "$TMP_INIT" "$NEW_TARGET"
sudo sync
sudo mv -f "$NEW_TARGET" "$BOOT_TARGET"
sudo sync

# Final verification of the exact boot image now on disk.
sudo lsinitramfs "$BOOT_TARGET" > "$STAGE/05-installed-contents.txt"
if ! grep -Eq "$EXPECTED_FW_RE" "$STAGE/05-installed-contents.txt"; then
    fail "installed boot initramfs lost the ADL-N firmware after replacement"
fi
for needle in \
    'sg4-ov5693-v4-unmodified/ov5693.ko' \
    'sg4-ov5693-v4-unmodified/ipu-bridge.ko' \
    'sg4-ov5693-v4-unmodified/intel-ipu6.ko' \
    'sg4-ov5693-v4-unmodified/intel-ipu6-isys.ko'; do
    grep -Fq "$needle" "$STAGE/05-installed-contents.txt" || fail "installed boot initramfs missing experimental module: $needle"
done

{
    echo "===== installed firmware ====="
    grep -E "$EXPECTED_FW_RE" "$STAGE/05-installed-contents.txt"
    echo
    echo "===== installed experimental modules ====="
    grep -F 'sg4-ov5693-v4-unmodified/' "$STAGE/05-installed-contents.txt" | sort -u
    echo
    echo "===== installed image hash ====="
    sudo sha256sum "$BOOT_TARGET"
    echo
    echo "===== backup image hash ====="
    sudo sha256sum "$BACKUP"
} > "$STAGE/06-installed-verification.txt"

echo "Verified initramfs installed directly."
echo "Firmware and all four experimental modules were confirmed before and after replacement."
echo "Backup: $BACKUP"
echo "REBOOT REQUIRED. Do not open or stream the camera before post-reboot verification."
