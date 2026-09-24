#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/12-libcamera-gain-ab"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CAM='\_SB_.PC00.I2C3.CAMF'
CODE=0x3007
FOURCC=BG10

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$(uname -r)" = "7.0.0-30-generic" ] || fail "unexpected kernel: $(uname -r)"
command -v cam >/dev/null || fail "cam is not installed"
[ -e "$SENSOR" ] || fail "$SENSOR missing"

# This test deliberately uses two 4:3 output sizes. 2048x1536 cannot be
# produced from the 1296x972 sensor mode, so it forces full resolution.
# 1152x864 fits inside 1296x972 and is expected to make SimplePipeline pick
# the binned mode. The actual sensor read-back is recorded and must be checked.

snapshot_sensor() {
    local out="$1"
    {
        echo '===== sensor format ====='
        v4l2-ctl -d "$SENSOR" --get-subdev-fmt pad=0
        echo
        echo '===== sensor controls ====='
        v4l2-ctl -d "$SENSOR" --get-ctrl=exposure,analogue_gain,digital_gain
        echo
        echo '===== full sensor control listing ====='
        v4l2-ctl -d "$SENSOR" --all
    } > "$out" 2>&1
}

run_cam_mode() {
    local label="$1" outw="$2" outh="$3" expected_sensor="$4"
    local dir="$STAGE/$label"
    mkdir -p "$dir"

    sudo dmesg --color=never > "$dir/00-dmesg-before.txt"
    local before_lines
    before_lines="$(wc -l < "$dir/00-dmesg-before.txt")"

    set +e
    timeout 30s cam -c "$CAM" \
        -s role=viewfinder,width="$outw",height="$outh",pixelformat=ABGR8888 \
        --strict-formats --metadata -C180 \
        > "$dir/01-cam.txt" 2>&1
    local rc=$?
    set -e
    echo "$rc" > "$dir/02-exit-code.txt"

    snapshot_sensor "$dir/03-sensor-after.txt"
    media-ctl -p > "$dir/04-media-topology-after.txt" 2>&1 || true

    sudo dmesg --color=never > "$dir/05-dmesg-after.txt"
    tail -n "+$((before_lines + 1))" "$dir/05-dmesg-after.txt" > "$dir/06-dmesg-new.txt" || true

    local actual
    actual="$(awk '/Width\/Height/{print $3; exit}' "$dir/03-sensor-after.txt" | tr '/' 'x')"

    {
        echo "cam_exit_code=$rc"
        echo "requested_output=${outw}x${outh}"
        echo "expected_sensor_mode=$expected_sensor"
        echo "actual_sensor_mode=$actual"
        echo
        echo '===== final controls ====='
        grep -E 'exposure:|analogue_gain:|digital_gain:' "$dir/03-sensor-after.txt" || true
        echo
        echo '===== last metadata lines containing gain/exposure ====='
        grep -Ei 'AnalogueGain|ExposureTime|DigitalGain' "$dir/01-cam.txt" | tail -n 60 || true
        echo
        echo '===== targeted dmesg ====='
        grep -i -E 'frame sync|transfer fifo|overflow|csi2.*error|stream.*time' "$dir/06-dmesg-new.txt" || true
    } > "$dir/07-summary.txt"

    [ "$rc" -eq 0 ] || return "$rc"
}

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: compare libcamera AE analogue gain for full-res vs 2x2-binned OV5693"
    echo "Camera: $CAM"
    echo "Full-res output request: 2048x1536 ABGR8888"
    echo "Binned output request: 1152x864 ABGR8888"
    echo "Frames per run: 180"
    echo "IMPORTANT: scene and lighting must remain fixed throughout both runs."
} > "$STAGE/00-metadata.txt"

snapshot_sensor "$STAGE/01-initial-sensor.txt"

full_rc=0
run_cam_mode 01-fullres 2048 1536 2592x1944 || full_rc=$?
sleep 2
bin_rc=0
run_cam_mode 02-binned 1152 864 1296x972 || bin_rc=$?

# Restore the direct media graph to the known full-resolution raw configuration.
{
    v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width=2592,height=1944,code="$CODE"
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width=2592,height=1944,code="$CODE"
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width=2592,height=1944,code="$CODE"
    v4l2-ctl -d "$VIDEO" --set-fmt-video=width=2592,height=1944,pixelformat="$FOURCC",field=none
} > "$STAGE/03-restore-fullres.txt" 2>&1 || true

{
    echo "fullres_exit_code=$full_rc"
    echo "binned_exit_code=$bin_rc"
    echo
    echo '===== FULL RES ====='
    cat "$STAGE/01-fullres/07-summary.txt" 2>/dev/null || true
    echo
    echo '===== BINNED ====='
    cat "$STAGE/02-binned/07-summary.txt" 2>/dev/null || true
} > "$STAGE/04-overall-summary.txt"

cat "$STAGE/04-overall-summary.txt"

# Do not fail merely because SimplePipeline selected an unexpected sensor mode;
# the logs are still useful for deciding the next measurement method.
[ "$full_rc" -eq 0 ] || exit "$full_rc"
[ "$bin_rc" -eq 0 ] || exit "$bin_rc"
