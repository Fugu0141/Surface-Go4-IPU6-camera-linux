#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/02-v4-adln/first-stream"
NEG="$ROOT/01-v4-unmodified/negative-control/05-result-summary.txt"
KVER="$(uname -r)"
CAM_ID='\_SB_.PC00.I2C3.CAMF'
EXPECTED_DIR="/lib/modules/$KVER/updates/sg4-ov5693-v4-adln"
WIREPLUMBER_RESTORE=0

mkdir -p "$OUT"

restore_wireplumber() {
    if [ "$WIREPLUMBER_RESTORE" -eq 1 ]; then
        if systemctl --user start wireplumber.service >/dev/null 2>&1; then
            WIREPLUMBER_RESTORE=0
        fi
    fi
}

trap restore_wireplumber EXIT

fail() {
    echo "ERROR: $*" | tee "$OUT/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
command -v cam >/dev/null 2>&1 || fail "cam is not installed"
command -v timeout >/dev/null 2>&1 || fail "timeout is not installed"

modules=(
  "ov5693:ov5693.ko:96C1F839F2269A46CE5CD0E"
  "ipu_bridge:ipu-bridge.ko:489EA8A6496C8EC6241F077"
  "intel_ipu6:intel-ipu6.ko:0549D5D1ECD2708B2B4F29D"
  "intel_ipu6_isys:intel-ipu6-isys.ko:94DB31A2B1F8AE58F5E41C5"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Camera: $CAM_ID"
    echo "Purpose: cold-boot first-stream test of v4 semantics plus exact INT33BE Alder Lake-N bridge match"
    echo
    echo "===== module verification ====="
    for item in "${modules[@]}"; do
        name="${item%%:*}"
        rest="${item#*:}"
        file="${rest%%:*}"
        expected_src="${rest#*:}"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        selected_src="$(modinfo -F srcversion "$name" 2>/dev/null || true)"
        loaded_src="$(cat "/sys/module/$name/srcversion" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$name" "$resolved" "$selected_src" "$loaded_src"
        [ "$resolved" = "$EXPECTED_DIR/$file" ] || fail "$name does not resolve to the ADL-N experimental module"
        [ "$selected_src" = "$expected_src" ] || fail "$name selected srcversion differs from expected ADL-N artifact"
        [ "$loaded_src" = "$expected_src" ] || fail "$name loaded srcversion differs from expected ADL-N artifact"
    done
    echo
    echo "===== negative-control reference ====="
    if [ -f "$NEG" ]; then
        cat "$NEG"
    else
        echo "negative-control summary missing: $NEG"
    fi
    echo
    echo "===== IPU6 PCI driver ====="
    lspci -nnk -s 00:05.0 || true
} > "$OUT/00-preflight.txt"

# Preserve first-stream semantics. Refuse if this boot already contains an IPU6
# stream event; enumeration/probe messages alone are allowed.
sudo dmesg > "$OUT/01-dmesg-before.txt"
if grep -Ei 'intel[_-]ipu6.*(stream (start|on)|stream stop time out|stream close time out)|intel_ipu6_isys.*(stream|csi2|fifo)' "$OUT/01-dmesg-before.txt" > "$OUT/02-prior-stream-check.txt"; then
    fail "possible IPU6 stream activity already exists in this boot; refusing to run a mislabeled cold-boot first-stream test"
else
    : > "$OUT/02-prior-stream-check.txt"
fi

# cam talks directly to libcamera. If WirePlumber is currently active, stop it
# temporarily so desktop camera discovery cannot race with this deliberate
# stream. Restore it after the stream, and also from the EXIT trap on errors.
if systemctl --user is-active --quiet wireplumber.service; then
    WIREPLUMBER_RESTORE=1
    systemctl --user stop wireplumber.service
fi

START_TIME="$(date --iso-8601=seconds)"
printf '%s\n' "$START_TIME" > "$OUT/03-start-time.txt"

set +e
timeout 60s cam \
  -c "$CAM_ID" \
  -C300 \
  > "$OUT/04-cam-front-first-300.log" 2>&1
CAM_EXIT=$?
set -e

# Restore the user's multimedia session immediately after the deliberate stream.
# If it was already inactive before the test, leave it inactive.
if [ "$WIREPLUMBER_RESTORE" -eq 1 ]; then
    systemctl --user start wireplumber.service \
        || fail "failed to restore wireplumber.service after camera test"
    WIREPLUMBER_RESTORE=0
fi

FRAME_COUNT="$(grep -c 'cam0-stream0 seq:' "$OUT/04-cam-front-first-300.log" || true)"
LAST_SEQ="$(grep 'cam0-stream0 seq:' "$OUT/04-cam-front-first-300.log" | tail -n 1 || true)"

{
    echo "camera=$CAM_ID"
    echo "timeout_seconds=60"
    echo "requested_frames=300"
    echo "exit_code=$CAM_EXIT"
    echo "frame_count=$FRAME_COUNT"
    echo "last_frame_line=$LAST_SEQ"
} > "$OUT/05-result-summary.txt"

sudo journalctl -k -b --since "$START_TIME" --no-pager > "$OUT/06-kernel-since-test.txt"
grep -Ei 'intel[_-]ipu6|ipu_bridge|ov5693|isys|stream|timeout|csi2|fifo|discard|error' \
    "$OUT/06-kernel-since-test.txt" > "$OUT/07-kernel-relevant.txt" || true

{
    echo "===== negative control ====="
    if [ -f "$NEG" ]; then cat "$NEG"; else echo "missing"; fi
    echo
    echo "===== ADL-N first stream ====="
    cat "$OUT/05-result-summary.txt"
    echo
    if [ "$CAM_EXIT" -eq 0 ] && [ "$FRAME_COUNT" -eq 300 ]; then
        echo "comparison=NEGATIVE_CONTROL_0_OF_300_TO_ADLN_300_OF_300"
    elif [ "$FRAME_COUNT" -gt 0 ]; then
        echo "comparison=ADLN_PARTIAL_OR_NONZERO_RESULT"
    else
        echo "comparison=ADLN_DID_NOT_DELIVER_FRAMES"
    fi
} > "$OUT/08-comparison.txt"

{
    echo "===== result ====="
    cat "$OUT/05-result-summary.txt"
    echo
    echo "===== comparison ====="
    cat "$OUT/08-comparison.txt"
    echo
    echo "===== last cam lines ====="
    tail -n 30 "$OUT/04-cam-front-first-300.log" || true
    echo
    echo "===== relevant kernel lines ====="
    tail -n 100 "$OUT/07-kernel-relevant.txt" || true
} > "$OUT/09-report.txt"

cat "$OUT/09-report.txt"
echo
echo "Logs: $OUT"
echo "Do not run a second camera stream until this first-attempt result is reviewed."
