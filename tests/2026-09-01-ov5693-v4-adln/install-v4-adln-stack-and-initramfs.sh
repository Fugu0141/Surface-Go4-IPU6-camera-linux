#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/02-v4-adln/install"
KVER="$(uname -r)"
STACK="$HOME/sg4-ov5693-v4-adln-stack-r2-$KVER/stack"
OLD_TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
NEW_TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-adln"
BACKUP_ROOT="/var/lib/sg4-ov5693-v4-backup"
OLD_BACKUP="$BACKUP_ROOT/modules-v4-unmodified-$KVER"
BOOT_LINK="/boot/initrd.img-$KVER"
BOOT_TARGET="$(readlink -f "$BOOT_LINK")"
BOOT_BACKUP="$BACKUP_ROOT/initrd.img-$KVER.pre-adln"
HOOK="/etc/initramfs-tools/hooks/sg4-ipu6-adln-firmware"
EXPECTED_SIGNER="Surface Go 4 ov5693 local test"
TMPDIR_ROOT=""
TMP_INIT=""
COMMITTED=0
MODULES_SWITCHED=0
BOOT_SWITCHED=0

mkdir -p "$STAGE"

log() { printf '%s\n' "$*"; }

rollback() {
    set +e
    if [ "$BOOT_SWITCHED" -eq 1 ] && sudo test -f "$BOOT_BACKUP"; then
        sudo install -m 0600 -o root -g root "$BOOT_BACKUP" "$BOOT_TARGET"
        sudo sync
    fi
    if [ "$MODULES_SWITCHED" -eq 1 ]; then
        sudo rm -rf "$NEW_TARGET"
        if sudo test -d "$OLD_BACKUP"; then
            sudo rm -rf "$OLD_TARGET"
            sudo cp -a "$OLD_BACKUP" "$OLD_TARGET"
        fi
        sudo depmod -a "$KVER" || true
    fi
    if [ -n "$TMPDIR_ROOT" ]; then
        sudo rm -rf "$TMPDIR_ROOT" || true
    fi
}

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    rollback
    exit 1
}

on_err() {
    rc=$?
    echo "ERROR: command failed with exit code $rc" | tee "$STAGE/99-error.txt" >&2
    rollback
    exit "$rc"
}
trap on_err ERR
trap 'if [ "$COMMITTED" -eq 1 ] && [ -n "$TMPDIR_ROOT" ]; then sudo rm -rf "$TMPDIR_ROOT" 2>/dev/null || true; fi' EXIT

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
[ -n "$BOOT_TARGET" ] || fail "could not resolve $BOOT_LINK"
sudo test -f "$BOOT_TARGET" || fail "boot initrd target missing: $BOOT_TARGET"
sudo test -x "$HOOK" || fail "enhanced initramfs hook missing or not executable: $HOOK"
command -v mkinitramfs >/dev/null 2>&1 || fail "mkinitramfs missing"
command -v lsinitramfs >/dev/null 2>&1 || fail "lsinitramfs missing"

modules=(
  "ov5693.ko:ov5693"
  "ipu-bridge.ko:ipu_bridge"
  "intel-ipu6.ko:intel_ipu6"
  "intel-ipu6-isys.ko:intel_ipu6_isys"
)

# Prove the recorded first-stream negative control before changing on-disk modules.
NEG_RESULT="$ROOT/01-v4-unmodified/negative-control/05-result-summary.txt"
if [ -f "$NEG_RESULT" ]; then
    grep -Fx 'exit_code=124' "$NEG_RESULT" >/dev/null || fail "negative-control exit code is not 124"
    grep -Fx 'frame_count=0' "$NEG_RESULT" >/dev/null || fail "negative-control frame count is not 0"
else
    fail "negative-control result file missing: $NEG_RESULT"
fi

# Verify the new artifacts before touching /lib/modules.
for item in "${modules[@]}"; do
    file="${item%%:*}"
    src="$STACK/$file"
    [ -f "$src" ] || fail "missing ADL-N build artifact: $src"
    [ "$(modinfo -F signer "$src" 2>/dev/null || true)" = "$EXPECTED_SIGNER" ] || fail "$file signer mismatch"
    vermagic="$(modinfo -F vermagic "$src" 2>/dev/null || true)"
    case "$vermagic" in
        "$KVER "*) ;;
        *) fail "$file vermagic mismatch: $vermagic" ;;
    esac
done

# Confirm current resolution is exactly the negative-control stack.
for item in "${modules[@]}"; do
    file="${item%%:*}"
    name="${item#*:}"
    resolved="$(modinfo -n "$name" 2>/dev/null || true)"
    [ "$resolved" = "$OLD_TARGET/$file" ] || fail "$name is not currently selected from the negative-control stack: $resolved"
done

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "ADL-N build stack: $STACK"
    echo "Old target: $OLD_TARGET"
    echo "New target: $NEW_TARGET"
    echo "Old module backup: $OLD_BACKUP"
    echo "Boot target: $BOOT_TARGET"
    echo "Boot backup: $BOOT_BACKUP"
    echo
    echo "===== negative control ====="
    cat "$NEG_RESULT"
    echo
    echo "===== currently selected modules ====="
    for item in "${modules[@]}"; do
        name="${item#*:}"
        echo "$name=$(modinfo -n "$name")"
        echo "loaded_srcversion=$(cat "/sys/module/$name/srcversion" 2>/dev/null || true)"
    done
} > "$STAGE/00-before.txt"

sudo install -d -m 0700 "$BACKUP_ROOT"
if ! sudo test -d "$OLD_BACKUP"; then
    sudo cp -a "$OLD_TARGET" "$OLD_BACKUP"
fi

# Stage new modules before removing the duplicate old override.
sudo rm -rf "$NEW_TARGET"
sudo install -d -m 0755 "$NEW_TARGET"
for item in "${modules[@]}"; do
    file="${item%%:*}"
    sudo install -m 0644 "$STACK/$file" "$NEW_TARGET/$file"
done

sudo rm -rf "$OLD_TARGET"
MODULES_SWITCHED=1
sudo depmod -a "$KVER"

{
    echo "===== module resolution after ADL-N switch ====="
    for item in "${modules[@]}"; do
        file="${item%%:*}"
        name="${item#*:}"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        echo "$name=$resolved"
        [ "$resolved" = "$NEW_TARGET/$file" ] || exit 42
        echo "srcversion=$(modinfo -F srcversion "$name" 2>/dev/null || true)"
        echo "signer=$(modinfo -F signer "$name" 2>/dev/null || true)"
        echo
    done
} > "$STAGE/01-after-depmod.txt" || fail "depmod did not select all four ADL-N modules; inspect 01-after-depmod.txt"

# Build and verify a separate initramfs before changing /boot.
TMPDIR_ROOT="$(sudo mktemp -d "/var/tmp/sg4-v4-adln-initramfs-$KVER.XXXXXX")"
TMP_INIT="$TMPDIR_ROOT/initrd.img-$KVER"
sudo mkinitramfs -v -o "$TMP_INIT" "$KVER" > "$STAGE/02-mkinitramfs.txt" 2>&1
sudo lsinitramfs "$TMP_INIT" > "$STAGE/03-temp-contents.txt"

grep -Eq '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$' "$STAGE/03-temp-contents.txt" \
    || fail "temporary ADL-N initramfs is missing raw ADL-N firmware"
for item in "${modules[@]}"; do
    file="${item%%:*}"
    grep -F "sg4-ov5693-v4-adln/$file" "$STAGE/03-temp-contents.txt" >/dev/null \
        || fail "temporary ADL-N initramfs is missing $file"
done

{
    echo "===== firmware ====="
    grep -E '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$' "$STAGE/03-temp-contents.txt"
    echo
    echo "===== ADL-N modules ====="
    grep -F 'sg4-ov5693-v4-adln/' "$STAGE/03-temp-contents.txt" | sort -u
    echo
    echo "===== image hash ====="
    sudo sha256sum "$TMP_INIT"
} > "$STAGE/04-temp-verification.txt"

# Preserve current boot image then atomically replace it with the verified one.
if ! sudo test -f "$BOOT_BACKUP"; then
    sudo cp --reflink=auto --preserve=mode,timestamps "$BOOT_TARGET" "$BOOT_BACKUP"
fi
sudo sha256sum "$BOOT_BACKUP" > "$STAGE/05-boot-backup-sha256.txt"

NEW_BOOT="${BOOT_TARGET}.sg4-adln-new"
sudo rm -f "$NEW_BOOT"
sudo install -m 0600 -o root -g root "$TMP_INIT" "$NEW_BOOT"
sudo sync
sudo mv -f "$NEW_BOOT" "$BOOT_TARGET"
sudo sync
BOOT_SWITCHED=1

sudo lsinitramfs "$BOOT_TARGET" > "$STAGE/06-installed-contents.txt"
grep -Eq '(^|/)(usr/)?lib/firmware/intel/ipu/ipu6epadln_fw\.bin$' "$STAGE/06-installed-contents.txt" \
    || fail "installed boot initramfs lost ADL-N firmware"
for item in "${modules[@]}"; do
    file="${item%%:*}"
    grep -F "sg4-ov5693-v4-adln/$file" "$STAGE/06-installed-contents.txt" >/dev/null \
        || fail "installed boot initramfs is missing $file"
done

{
    echo "===== installed ADL-N module resolution ====="
    for item in "${modules[@]}"; do
        name="${item#*:}"
        echo "$name=$(modinfo -n "$name")"
        echo "srcversion=$(modinfo -F srcversion "$name")"
    done
    echo
    echo "===== current running modules (expected negative-control versions until shutdown) ====="
    for item in "${modules[@]}"; do
        name="${item#*:}"
        echo "$name=$(cat "/sys/module/$name/srcversion" 2>/dev/null || true)"
    done
    echo
    echo "===== installed boot image hash ====="
    sudo sha256sum "$BOOT_TARGET"
    echo "===== pre-ADL-N boot backup hash ====="
    sudo sha256sum "$BOOT_BACKUP"
} > "$STAGE/07-final-state.txt"

COMMITTED=1
log "ADL-N stack and verified initramfs installed successfully."
log "Negative-control module backup: $OLD_BACKUP"
log "Pre-ADL-N initramfs backup: $BOOT_BACKUP"
log "The currently running kernel still has the negative-control modules in memory."
log "POWER OFF REQUIRED. Do not run another camera stream before the cold-boot ADL-N verification."
