#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/13-fixed-raw-sensitivity-ab"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CODE=0x3007
FOURCC=BG10
AGAIN=8
DGAIN=1024
EXPOSURES=(500 1000)

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$(uname -r)" = "7.0.0-30-generic" ] || fail "unexpected kernel: $(uname -r)"
[ -e "$SENSOR" ] || fail "$SENSOR missing"
[ -e "$CSI" ] || fail "$CSI missing"
[ -e "$VIDEO" ] || fail "$VIDEO missing"

v4l2-ctl -d "$VIDEO" --all | grep -F 'Intel IPU6 ISYS Capture 8' >/dev/null \
    || fail "$VIDEO is not Intel IPU6 ISYS Capture 8"

v4l2-ctl --help-streaming 2>&1 | grep -q -- '--stream-skip' \
    || fail 'this v4l2-ctl lacks --stream-skip; stop rather than capture an unstable first frame'

ORIG_EXPOSURE="$(v4l2-ctl -d "$SENSOR" --get-ctrl=exposure | awk '{print $2}')"
ORIG_AGAIN="$(v4l2-ctl -d "$SENSOR" --get-ctrl=analogue_gain | awk '{print $2}')"
ORIG_DGAIN="$(v4l2-ctl -d "$SENSOR" --get-ctrl=digital_gain | awk '{print $2}')"

restore() {
    set +e
    v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width=2592,height=1944,code="$CODE" >/dev/null 2>&1
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width=2592,height=1944,code="$CODE" >/dev/null 2>&1
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width=2592,height=1944,code="$CODE" >/dev/null 2>&1
    v4l2-ctl -d "$VIDEO" --set-fmt-video=width=2592,height=1944,pixelformat="$FOURCC",field=none >/dev/null 2>&1
    v4l2-ctl -d "$SENSOR" --set-ctrl="exposure=$ORIG_EXPOSURE,analogue_gain=$ORIG_AGAIN,digital_gain=$ORIG_DGAIN" >/dev/null 2>&1
}
trap restore EXIT

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: fixed-control raw sensitivity comparison, full-res vs 2x2 binning"
    echo "Sensor: $SENSOR (OV5693)"
    echo "CSI2: $CSI (Intel IPU6 CSI2 1)"
    echo "Capture: $VIDEO (Intel IPU6 ISYS Capture 8)"
    echo "Media bus: SBGGR10_1X10 ($CODE)"
    echo "Capture FourCC: $FOURCC"
    echo "Analogue gain code: $AGAIN"
    echo "Digital gain code: $DGAIN"
    echo "Exposure codes: ${EXPOSURES[*]}"
    echo "Five frames are skipped after each stream start; one raw frame is saved."
    echo "IMPORTANT: camera, scene, and lighting must not move/change during the test."
    echo
    echo "Original controls: exposure=$ORIG_EXPOSURE analogue_gain=$ORIG_AGAIN digital_gain=$ORIG_DGAIN"
} > "$STAGE/00-metadata.txt"

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
        echo '===== fixed controls ====='
        v4l2-ctl -d "$SENSOR" --get-ctrl=exposure,analogue_gain,digital_gain
        echo
        echo '===== timing controls ====='
        v4l2-ctl -d "$SENSOR" --get-ctrl=horizontal_blanking,vertical_blanking,pixel_rate,link_frequency
    } > "$out" 2>&1
}

configure_mode() {
    local w="$1" h="$2"
    v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width="$w",height="$h",code="$CODE" >/dev/null
    v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$w",height="$h",pixelformat="$FOURCC",field=none >/dev/null
}

capture_one() {
    local label="$1" w="$2" h="$3" exposure="$4"
    local dir="$STAGE/$label-exp$exposure"
    local raw="$dir/frame.raw"
    mkdir -p "$dir"

    configure_mode "$w" "$h"
    v4l2-ctl -d "$SENSOR" --set-ctrl="exposure=$exposure,analogue_gain=$AGAIN,digital_gain=$DGAIN"
    snapshot "$dir/01-before.txt"

    grep -q "Width/Height[[:space:]]*: ${w}/${h}" "$dir/01-before.txt" \
        || fail "$label exp=$exposure: requested ${w}x${h} did not read back"
    grep -q "exposure: $exposure" "$dir/01-before.txt" \
        || fail "$label exp=$exposure: exposure control did not read back"
    grep -q "analogue_gain: $AGAIN" "$dir/01-before.txt" \
        || fail "$label exp=$exposure: analogue gain did not read back"
    grep -q "digital_gain: $DGAIN" "$dir/01-before.txt" \
        || fail "$label exp=$exposure: digital gain did not read back"

    sudo dmesg --color=never > "$dir/02-dmesg-before.txt"
    local before_lines
    before_lines="$(wc -l < "$dir/02-dmesg-before.txt")"

    set +e
    timeout 20s v4l2-ctl -d "$VIDEO" \
        --stream-mmap=4 --stream-poll --stream-skip=5 --stream-count=1 \
        --stream-to="$raw" > "$dir/03-capture.txt" 2>&1
    local rc=$?
    set -e
    echo "$rc" > "$dir/04-exit-code.txt"
    [ "$rc" -eq 0 ] || fail "$label exp=$exposure capture failed with rc=$rc"
    [ -s "$raw" ] || fail "$label exp=$exposure raw file is empty"

    snapshot "$dir/05-after.txt"
    stat -c 'raw_bytes=%s' "$raw" > "$dir/06-raw-size.txt"
    sha256sum "$raw" > "$dir/07-sha256.txt"

    sudo dmesg --color=never > "$dir/08-dmesg-after.txt"
    tail -n "+$((before_lines + 1))" "$dir/08-dmesg-after.txt" > "$dir/09-dmesg-new.txt" || true
    grep -i -E 'frame sync|transfer fifo|overflow|inter-frame|csi2.*error|stream.*time' \
        "$dir/09-dmesg-new.txt" > "$dir/10-dmesg-targeted.txt" || true

    sleep 1
}

snapshot "$STAGE/01-initial.txt"

for exposure in "${EXPOSURES[@]}"; do
    capture_one fullres 2592 1944 "$exposure"
    capture_one binned 1296 972 "$exposure"
done

restore
trap - EXIT
snapshot "$STAGE/90-restored.txt"

{
    echo 'Fixed-control raw A/B completed.'
    echo "Analogue gain=$AGAIN, digital gain=$DGAIN"
    echo "Exposure values: ${EXPOSURES[*]}"
    echo
    for exposure in "${EXPOSURES[@]}"; do
        for label in fullres binned; do
            dir="$STAGE/$label-exp$exposure"
            printf '%-18s ' "$label exp=$exposure"
            cat "$dir/06-raw-size.txt"
            if [ -s "$dir/10-dmesg-targeted.txt" ]; then
                echo '  targeted_dmesg: PRESENT'
            else
                echo '  targeted_dmesg: clean'
            fi
        done
    done
} > "$STAGE/99-summary.txt"

cat "$STAGE/99-summary.txt"
