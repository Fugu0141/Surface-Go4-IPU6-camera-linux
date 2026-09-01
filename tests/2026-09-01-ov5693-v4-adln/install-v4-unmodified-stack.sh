#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/install"
KVER="$(uname -r)"
STACK="$HOME/sg4-ov5693-v4-stack-$KVER/stack"
TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
EXPECTED_SIGNER="Surface Go 4 ov5693 local test"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"

modules=(
  "ov5693.ko:ov5693"
  "ipu-bridge.ko:ipu_bridge"
  "intel-ipu6.ko:intel_ipu6"
  "intel-ipu6-isys.ko:intel_ipu6_isys"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Install unified v4-unmodified Surface Go 4 negative-control module stack"
    echo "Kernel: $KVER"
    echo "Source stack: $STACK"
    echo "Target: $TARGET"
} > "$STAGE/00-metadata.txt"

# Record currently selected modules and refuse to hide any pre-existing non-stock override.
{
    echo "===== current module resolution before install ====="
    for item in "${modules[@]}"; do
        name="${item#*:}"
        printf '%s=' "$name"
        modinfo -n "$name" 2>/dev/null || true
    done
} > "$STAGE/01-before-resolution.txt"

for item in "${modules[@]}"; do
    file="${item%%:*}"
    name="${item#*:}"
    src="$STACK/$file"
    [ -f "$src" ] || fail "missing build artifact: $src"

    signer="$(modinfo -F signer "$src" 2>/dev/null || true)"
    [ "$signer" = "$EXPECTED_SIGNER" ] || fail "$file signer mismatch: '$signer'"

    vermagic="$(modinfo -F vermagic "$src" 2>/dev/null || true)"
    case "$vermagic" in
        "$KVER "*) ;;
        *) fail "$file vermagic mismatch: '$vermagic'" ;;
    esac

    current="$(modinfo -n "$name" 2>/dev/null || true)"
    case "$current" in
        ""|/lib/modules/"$KVER"/kernel/*) ;;
        "$TARGET"/*) ;;
        *) fail "$name currently resolves to a non-stock override: $current" ;;
    esac
done

{
    echo "===== artifacts ====="
    for item in "${modules[@]}"; do
        file="${item%%:*}"
        src="$STACK/$file"
        sha256sum "$src"
        echo "signer=$(modinfo -F signer "$src")"
        echo "vermagic=$(modinfo -F vermagic "$src")"
        echo
    done
} > "$STAGE/02-artifact-verification.txt"

if sudo test -e "$TARGET"; then
    if sudo test -n "$(sudo find "$TARGET" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null)"; then
        fail "target already contains files: $TARGET"
    fi
fi

sudo install -d -m 0755 "$TARGET"
for item in "${modules[@]}"; do
    file="${item%%:*}"
    sudo install -m 0644 "$STACK/$file" "$TARGET/$file"
done

sudo depmod -a "$KVER"

{
    echo "===== module resolution after depmod ====="
    ok=1
    for item in "${modules[@]}"; do
        file="${item%%:*}"
        name="${item#*:}"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        echo "$name=$resolved"
        if [ "$resolved" != "$TARGET/$file" ]; then
            echo "MISMATCH: expected $TARGET/$file"
            ok=0
        fi
        echo "signer=$(modinfo -F signer "$name" 2>/dev/null || true)"
        echo "vermagic=$(modinfo -F vermagic "$name" 2>/dev/null || true)"
        echo
    done
    [ "$ok" -eq 1 ] || exit 42
} > "$STAGE/03-after-depmod.txt" 2>&1 || fail "depmod did not select all four experimental modules; inspect 03-after-depmod.txt"

sudo update-initramfs -u -k "$KVER" > "$STAGE/04-update-initramfs.txt" 2>&1

{
    echo "===== installed files ====="
    sudo ls -lh "$TARGET"
    echo
    sha256sum "$STACK"/*.ko
    echo
    echo "===== loaded modules remain unchanged until reboot ====="
    lsmod | grep -E '^(ov5693|ipu_bridge|intel_ipu6|intel_ipu6_isys)[[:space:]]' || true
} > "$STAGE/05-installed-state.txt"

cat > "$STAGE/README.md" <<EOF
# v4 unmodified stack installation

The unified experimental stack was installed under:

\`$TARGET\`

The Ubuntu stock modules under \`/lib/modules/$KVER/kernel/\` were not modified or deleted.

A reboot is required before testing. Do not stream the front camera before collecting the post-reboot verification logs, so the first deliberate stream attempt remains auditable.

Rollback is provided by \`rollback-v4-unmodified-stack.sh\` in the test directory.
EOF

echo "Installation complete."
echo "Experimental stack: $TARGET"
echo "Ubuntu stock modules were left untouched."
echo "REBOOT REQUIRED before the negative-control test."
echo "Do not test the front camera before post-reboot verification."
