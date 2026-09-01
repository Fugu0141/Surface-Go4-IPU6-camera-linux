#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/post-reboot"
KVER="$(uname -r)"
STACK="$HOME/sg4-ov5693-v4-stack-$KVER/stack"
TARGET="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
EXPECTED_SIGNER="Surface Go 4 ov5693 local test"

mkdir -p "$STAGE"

modules=(
  "ov5693.ko:ov5693:ov5693"
  "ipu-bridge.ko:ipu_bridge:ipu_bridge"
  "intel-ipu6.ko:intel_ipu6:intel_ipu6"
  "intel-ipu6-isys.ko:intel_ipu6_isys:intel_ipu6_isys"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Verify the v4-unmodified experimental stack after reboot without accessing the camera"
    echo "Kernel: $KVER"
    echo "Expected target: $TARGET"
    echo "Expected signer: $EXPECTED_SIGNER"
} > "$STAGE/00-metadata.txt"

{
    echo "===== Secure Boot ====="
    mokutil --sb-state 2>&1 || true
    echo
    echo "===== kernel taint ====="
    cat /proc/sys/kernel/tainted 2>/dev/null || true
    echo
    echo "===== loaded modules ====="
    lsmod | grep -E '^(ov5693|ipu_bridge|intel_ipu6|intel_ipu6_isys)[[:space:]]' || true
} > "$STAGE/01-boot-state.txt"

{
    echo -e "module\tresolved_path\texpected_srcversion\tloaded_srcversion\tsrcversion_match\tsigner\tvermagic"
    overall=1
    for item in "${modules[@]}"; do
        file="${item%%:*}"
        rest="${item#*:}"
        name="${rest%%:*}"
        sysname="${rest#*:}"
        artifact="$STACK/$file"

        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        expected_src="$(modinfo -F srcversion "$artifact" 2>/dev/null || true)"
        signer="$(modinfo -F signer "$artifact" 2>/dev/null || true)"
        vermagic="$(modinfo -F vermagic "$artifact" 2>/dev/null || true)"
        loaded_src="$(cat "/sys/module/$sysname/srcversion" 2>/dev/null || true)"

        match="NO"
        if [ -n "$expected_src" ] && [ "$expected_src" = "$loaded_src" ]; then
            match="YES"
        else
            overall=0
        fi

        case "$resolved" in
            "$TARGET/$file") ;;
            *) overall=0 ;;
        esac
        [ "$signer" = "$EXPECTED_SIGNER" ] || overall=0

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$resolved" "$expected_src" "$loaded_src" "$match" "$signer" "$vermagic"
    done
    echo
    if [ "$overall" -eq 1 ]; then
        echo "RESULT=EXPERIMENTAL_STACK_CONFIRMED_LOADED"
    else
        echo "RESULT=STACK_VERIFICATION_FAILED_OR_INCOMPLETE"
    fi
} > "$STAGE/02-module-verification.txt"

{
    echo "===== boot kernel messages: relevant ====="
    sudo dmesg --color=never | grep -Ei \
      'ipu6|ipu[_-]bridge|ov5693|INT33BE|OVTI5693|stream (stop|close).*time ?out|Unknown symbol|disagrees about version|module verification|Required key|signature' \
      || true
} > "$STAGE/03-dmesg-relevant.txt" 2>&1

{
    echo "===== possible stream activity before deliberate test ====="
    sudo dmesg --color=never | grep -Ei \
      'stream (stop|close).*time ?out|stream.*time ?out|start.*stream|stream.*start|CSI.*packet|SOT|CRC' \
      || true
} > "$STAGE/04-prior-stream-activity.txt" 2>&1

{
    echo "===== current module resolution ====="
    for item in "${modules[@]}"; do
        file="${item%%:*}"
        rest="${item#*:}"
        name="${rest%%:*}"
        echo "--- $name ---"
        modinfo -n "$name" 2>/dev/null || true
        modinfo -F signer "$name" 2>/dev/null || true
        modinfo -F srcversion "$name" 2>/dev/null || true
        echo
    done
} > "$STAGE/05-resolution.txt"

echo "Post-reboot verification collected; no camera access was performed."
echo "Logs: $STAGE"
echo "Inspect:"
echo "  $STAGE/02-module-verification.txt"
echo "  $STAGE/04-prior-stream-activity.txt"
