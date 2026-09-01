#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/02-v4-adln/post-coldboot"
KVER="$(uname -r)"
EXPECTED_DIR="/lib/modules/$KVER/updates/sg4-ov5693-v4-adln"
mkdir -p "$OUT"

fail() {
    echo "ERROR: $*" | tee "$OUT/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"

modules=(
  "ov5693:ov5693.ko:96C1F839F2269A46CE5CD0E"
  "ipu_bridge:ipu-bridge.ko:489EA8A6496C8EC6241F077"
  "intel_ipu6:intel-ipu6.ko:0549D5D1ECD2708B2B4F29D"
  "intel_ipu6_isys:intel-ipu6-isys.ko:94DB31A2B1F8AE58F5E41C5"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Expected module directory: $EXPECTED_DIR"
    echo
    echo "===== boot identity ====="
    uptime -s || true
    cat /proc/cmdline || true
    echo
    echo "===== PCI device ====="
    lspci -nnk -s 00:05.0 || true
} > "$OUT/00-system.txt"

{
    printf 'module\tresolved_path\texpected_srcversion\tloaded_srcversion\tsrcversion_match\tsigner\tvermagic\n'
    all_ok=1
    for item in "${modules[@]}"; do
        IFS=: read -r name file expected_src <<<"$item"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        loaded_src="$(cat "/sys/module/$name/srcversion" 2>/dev/null || true)"
        signer="$(modinfo -F signer "$name" 2>/dev/null || true)"
        vermagic="$(modinfo -F vermagic "$name" 2>/dev/null || true)"
        match=NO
        if [ "$resolved" = "$EXPECTED_DIR/$file" ] && [ "$loaded_src" = "$expected_src" ]; then
            match=YES
        else
            all_ok=0
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$resolved" "$expected_src" "$loaded_src" "$match" "$signer" "$vermagic"
    done
    echo
    if [ "$all_ok" -eq 1 ]; then
        echo "RESULT=ADLN_EXPERIMENTAL_STACK_CONFIRMED_LOADED"
    else
        echo "RESULT=ADLN_STACK_VERIFICATION_FAILED_OR_INCOMPLETE"
    fi
} > "$OUT/01-module-verification.txt"

sudo dmesg > "$OUT/02-dmesg-full.txt"

grep -Ei 'intel-ipu6|intel_ipu6|ipu_bridge|ov5693|isys|firmware|unknown symbol|disagrees about version|key was rejected' \
    "$OUT/02-dmesg-full.txt" > "$OUT/03-dmesg-relevant.txt" || true

{
    echo "===== possible stream activity before deliberate ADL-N test ====="
    grep -Ei 'intel[_-]ipu6.*(stream (start|on)|stream stop time out|stream close time out)|intel_ipu6_isys.*(stream|csi2|fifo)' \
        "$OUT/02-dmesg-full.txt" || true
} > "$OUT/04-prior-stream-activity.txt"

{
    echo "===== firmware/probe failure check ====="
    grep -Ei 'ipu6epadln.*(failed|error)|Requesting signed firmware.*failed|probe with driver intel-ipu6 failed|unknown symbol|disagrees about version|key was rejected' \
        "$OUT/02-dmesg-full.txt" || true
} > "$OUT/05-failure-check.txt"

cat "$OUT/01-module-verification.txt"
echo
cat "$OUT/04-prior-stream-activity.txt"
echo
cat "$OUT/05-failure-check.txt"
echo
printf 'Logs: %s\n' "$OUT"
printf 'No camera access was performed by this verifier.\n'
