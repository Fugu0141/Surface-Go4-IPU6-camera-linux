#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/01-v4-unmodified/negative-control"
KVER="$(uname -r)"
CAM_ID='\_SB_.PC00.I2C3.CAMF'
EXPECTED_DIR="/lib/modules/$KVER/updates/sg4-ov5693-v4-unmodified"
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
  "ov5693:ov5693.ko"
  "ipu_bridge:ipu-bridge.ko"
  "intel_ipu6:intel-ipu6.ko"
  "intel_ipu6_isys:intel-ipu6-isys.ko"
)

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $KVER"
    echo "Camera: $CAM_ID"
    echo "Purpose: v4 semantics minimally backported to Ubuntu 7.0.0-30.30, without ADL-N bridge match"
    echo
    echo "===== module verification ====="
    for item in "${modules[@]}"; do
        name="${item%%:*}"
        file="${item#*:}"
        resolved="$(modinfo -n "$name" 2>/dev/null || true)"
        expected_src="$(modinfo -F srcversion "$resolved" 2>/dev/null || true)"
        loaded_src="$(cat "/sys/module/$name/srcversion" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$name" "$resolved" "$expected_src" "$loaded_src"
        [ "$resolved" = "$EXPECTED_DIR/$file" ] || fail "$name does not resolve to the v4-unmodified experimental module"
        [ -n "$loaded_src" ] || fail "$name is not loaded"
        [ "$expected_src" = "$loaded_src" ] || fail "$name loaded srcversion differs from selected experimental module"
    done
    echo
    echo "===== IPU6 PCI driver ====="
    lspci -nnk -s 00:05.0 || true
} > "$OUT/00-preflight.txt"

# Preserve the first deliberate camera stream. If the kernel already records
# an IPU6 stream event in this boot, stop rather than mislabel a later retry as
# a cold/first-stream negative control.
sudo dmesg > "$OUT/01-dmesg-before.txt"
if grep -Ei 'intel[_-]ipu6.*(stream (start|on)|stream stop time out|stream close time out)|intel_ipu6_isys.*(stream|csi2|fifo)' "$OUT/01-dmesg-before.txt" > "$OUT/02-prior-stream-check.txt"; then
    fail "possible IPU6 stream activity already exists in this boot; refusing to run a mislabeled first-stream test"
else
    : > "$OUT/02-prior-stream-check.txt"
fi

# WirePlumber is not needed by cam. If it is currently active, stop it only for
# the deliberate stream and restore it afterwards. The EXIT trap also restores
# it if the script exits early after the stop.
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
    echo "===== result ====="
    cat "$OUT/05-result-summary.txt"
    echo
    echo "===== last cam lines ====="
    tail -n 30 "$OUT/04-cam-front-first-300.log" || true
    echo
    echo "===== relevant kernel lines ====="
    tail -n 100 "$OUT/07-kernel-relevant.txt" || true
} > "$OUT/08-report.txt"

cat "$OUT/08-report.txt"
echo
echo "Logs: $OUT"
echo "Do not run a second camera stream yet; preserve this first-attempt result for comparison with the ADL-N match test."
