#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/14-temporal-noise-snr-ab"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CODE=0x3007
FOURCC=BG10
EXPOSURE=500
AGAIN=8
DGAIN=1024
SKIP=8
FRAMES=8

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$(uname -r)" = "7.0.0-30-generic" ] || fail "unexpected kernel: $(uname -r)"
for dev in "$SENSOR" "$CSI" "$VIDEO"; do
    [ -e "$dev" ] || fail "$dev missing"
done

v4l2-ctl -d "$VIDEO" --all | grep -F 'Intel IPU6 ISYS Capture 8' >/dev/null \
    || fail "$VIDEO is not Intel IPU6 ISYS Capture 8"

v4l2-ctl --help-streaming 2>&1 | grep -q -- '--stream-skip' \
    || fail 'this v4l2-ctl lacks --stream-skip'

BINNED_Y_OFFSET="$(cat /sys/module/ov5693/parameters/binned_y_offset 2>/dev/null || true)"
[ "$BINNED_Y_OFFSET" = "2" ] || fail "expected binned_y_offset=2, got '${BINNED_Y_OFFSET:-missing}'"

ORIG_EXPOSURE="$(v4l2-ctl -d "$SENSOR" --get-ctrl=exposure | awk '{print $2}')"
ORIG_AGAIN="$(v4l2-ctl -d "$SENSOR" --get-ctrl=analogue_gain | awk '{print $2}')"
ORIG_DGAIN="$(v4l2-ctl -d "$SENSOR" --get-ctrl=digital_gain | awk '{print $2}')"

configure_mode() {
    local w="$1" h="$2"
    v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$w",height="$h",pixelformat="$FOURCC",field=none >/dev/null
}

restore() {
    set +e
    configure_mode 2592 1944 >/dev/null 2>&1
    v4l2-ctl -d "$SENSOR" \
        --set-ctrl="exposure=$ORIG_EXPOSURE,analogue_gain=$ORIG_AGAIN,digital_gain=$ORIG_DGAIN" \
        >/dev/null 2>&1
}
trap restore EXIT

snapshot() {
    local out="$1"
    {
        echo '===== sensor format ====='
        v4l2-ctl -d "$SENSOR" --get-subdev-fmt pad=0
        echo
        echo '===== CSI sink ====='
        v4l2-ctl -d "$CSI" --get-subdev-fmt pad=0
        echo
        echo '===== CSI source ====='
        v4l2-ctl -d "$CSI" --get-subdev-fmt pad=1
        echo
        echo '===== capture format ====='
        v4l2-ctl -d "$VIDEO" --get-fmt-video
        echo
        echo '===== controls ====='
        v4l2-ctl -d "$SENSOR" --get-ctrl=exposure,analogue_gain,digital_gain
        echo
        echo '===== timing ====='
        v4l2-ctl -d "$SENSOR" --get-ctrl=horizontal_blanking,vertical_blanking,pixel_rate,link_frequency
    } > "$out" 2>&1
}

capture_sequence() {
    local label="$1" w="$2" h="$3"
    local dir="$STAGE/$label"
    local seq="$dir/frames.rawseq"
    mkdir -p "$dir"

    configure_mode "$w" "$h"
    v4l2-ctl -d "$SENSOR" \
        --set-ctrl="exposure=$EXPOSURE,analogue_gain=$AGAIN,digital_gain=$DGAIN" >/dev/null
    snapshot "$dir/01-before.txt"

    grep -q "Width/Height[[:space:]]*: ${w}/${h}" "$dir/01-before.txt" \
        || fail "$label: ${w}x${h} did not read back"
    grep -q "Pixel Format[[:space:]]*: '$FOURCC'" "$dir/01-before.txt" \
        || fail "$label: $FOURCC did not read back"
    grep -q "exposure: $EXPOSURE" "$dir/01-before.txt" || fail "$label: exposure mismatch"
    grep -q "analogue_gain: $AGAIN" "$dir/01-before.txt" || fail "$label: analogue gain mismatch"
    grep -q "digital_gain: $DGAIN" "$dir/01-before.txt" || fail "$label: digital gain mismatch"

    local size_image
    size_image="$(awk '/Size Image/{print $4; exit}' "$dir/01-before.txt")"
    [[ "$size_image" =~ ^[0-9]+$ ]] || fail "$label: could not parse Size Image"

    sudo dmesg --color=never > "$dir/02-dmesg-before.txt"
    local before_lines
    before_lines="$(wc -l < "$dir/02-dmesg-before.txt")"

    rm -f "$seq"
    set +e
    timeout 30s v4l2-ctl -d "$VIDEO" \
        --stream-mmap=4 --stream-poll \
        --stream-skip="$SKIP" --stream-count="$FRAMES" \
        --stream-to="$seq" > "$dir/03-capture.txt" 2>&1
    local rc=$?
    set -e
    echo "$rc" > "$dir/04-exit-code.txt"
    [ "$rc" -eq 0 ] || fail "$label capture failed with rc=$rc"
    [ -s "$seq" ] || fail "$label sequence file is empty"

    local actual_bytes expected_bytes
    actual_bytes="$(stat -c '%s' "$seq")"
    expected_bytes=$((size_image * FRAMES))

    {
        echo "width=$w"
        echo "height=$h"
        echo "fourcc=$FOURCC"
        echo "size_image=$size_image"
        echo "frames=$FRAMES"
        echo "stream_skip=$SKIP"
        echo "actual_bytes=$actual_bytes"
        echo "expected_bytes=$expected_bytes"
    } > "$dir/05-sequence-layout.txt"

    [ "$actual_bytes" -eq "$expected_bytes" ] \
        || fail "$label: sequence size $actual_bytes != expected $expected_bytes"

    sha256sum "$seq" > "$dir/06-sha256.txt"
    snapshot "$dir/07-after.txt"

    sudo dmesg --color=never > "$dir/08-dmesg-after.txt"
    tail -n "+$((before_lines + 1))" "$dir/08-dmesg-after.txt" > "$dir/09-dmesg-new.txt" || true
    grep -i -E 'frame sync|transfer fifo|overflow|inter-frame|csi2.*error|stream.*time' \
        "$dir/09-dmesg-new.txt" > "$dir/10-dmesg-targeted.txt" || true

    sync
    sleep 2
}

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: temporal RAW noise / SNR comparison, full-res vs OV5693 2x2 binning"
    echo "Sensor: $SENSOR"
    echo "CSI2: $CSI"
    echo "Capture: $VIDEO"
    echo "Media bus: SBGGR10_1X10 ($CODE)"
    echo "Capture FourCC: $FOURCC"
    echo "binned_y_offset=$BINNED_Y_OFFSET"
    echo "Exposure=$EXPOSURE"
    echo "Analogue gain=$AGAIN"
    echo "Digital gain=$DGAIN"
    echo "Frames saved per mode=$FRAMES after skipping $SKIP startup frames"
    echo "IMPORTANT: camera, scene, and illumination must remain stationary and non-flickering."
    echo "Original controls: exposure=$ORIG_EXPOSURE analogue_gain=$ORIG_AGAIN digital_gain=$ORIG_DGAIN"
} > "$STAGE/00-metadata.txt"

snapshot "$STAGE/01-initial.txt"

capture_sequence fullres 2592 1944
capture_sequence binned 1296 972

restore
trap - EXIT
snapshot "$STAGE/90-restored.txt"

{
    echo 'Temporal-noise capture completed.'
    echo "Fixed controls: exposure=$EXPOSURE analogue_gain=$AGAIN digital_gain=$DGAIN"
    echo "Frames per mode: $FRAMES"
    echo
    for label in fullres binned; do
        echo "===== $label ====="
        cat "$STAGE/$label/05-sequence-layout.txt"
        if [ -s "$STAGE/$label/10-dmesg-targeted.txt" ]; then
            echo 'targeted_dmesg=PRESENT'
            cat "$STAGE/$label/10-dmesg-targeted.txt"
        else
            echo 'targeted_dmesg=clean'
        fi
        echo
    done
} > "$STAGE/99-summary.txt"

cat "$STAGE/99-summary.txt"
