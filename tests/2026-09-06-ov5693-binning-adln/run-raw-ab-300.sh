#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/10-raw-ab-300"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CODE=0x3007
FOURCC=BG10

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
media-ctl -p | grep -F 'ov5693 2-0036' >/dev/null || fail 'ov5693 entity missing'

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $(uname -r)"
    echo "Sensor: $SENSOR (ov5693 2-0036)"
    echo "CSI2: $CSI (Intel IPU6 CSI2 1)"
    echo "Capture: $VIDEO (Intel IPU6 ISYS Capture 8)"
    echo "Sensor/CSI mbus code: $CODE = SBGGR10_1X10"
    echo "Capture FourCC: $FOURCC = 10-bit Bayer BGGR, unpacked"
    echo "Frames per mode: 300"
    echo "No frame payloads are saved in this A/B run."
} > "$STAGE/00-metadata.txt"

snapshot_formats() {
    local out="$1"
    {
        echo '===== sensor pad0 ====='
        v4l2-ctl -d "$SENSOR" --get-subdev-fmt pad=0
        echo
        echo '===== CSI pad0 ====='
        v4l2-ctl -d "$CSI" --get-subdev-fmt pad=0
        echo
        echo '===== CSI pad1 ====='
        v4l2-ctl -d "$CSI" --get-subdev-fmt pad=1
        echo
        echo '===== capture node ====='
        v4l2-ctl -d "$VIDEO" --get-fmt-video
        echo
        echo '===== ov5693 controls ====='
        v4l2-ctl -d "$SENSOR" --all
    } > "$out" 2>&1
}

configure_mode() {
    local w="$1" h="$2" log="$3"
    {
        echo "== set sensor ${w}x${h} SBGGR10 =="
        v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE"
        echo
        echo "== set CSI sink ${w}x${h} SBGGR10 =="
        v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE"
        echo
        echo "== set CSI source ${w}x${h} SBGGR10 =="
        v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width="$w",height="$h",code="$CODE"
        echo
        echo "== set capture ${w}x${h} BG10 =="
        v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$w",height="$h",pixelformat="$FOURCC",field=none
    } > "$log" 2>&1
}

verify_mode() {
    local w="$1" h="$2" out="$3"
    snapshot_formats "$out"
    grep -Eq "Width/Height[[:space:]]*: ${w}/${h}" "$out" || fail "capture node did not read back ${w}x${h}"
    grep -F "Pixel Format      : '$FOURCC'" "$out" >/dev/null || fail "capture node did not read back $FOURCC"
    # Three subdev read-backs should all show the requested dimensions.
    [ "$(grep -c "Width/Height[[:space:]]*: ${w}/${h}" "$out")" -ge 4 ] \
        || fail "not all sensor/CSI/capture formats read back as ${w}x${h}"
    grep -F 'Mediabus Code     : 0x3007 (MEDIA_BUS_FMT_SBGGR10_1X10)' "$out" >/dev/null \
        || fail "SBGGR10 read-back missing"
}

run_capture() {
    local label="$1" w="$2" h="$3"
    local dir="$STAGE/$label"
    mkdir -p "$dir"

    configure_mode "$w" "$h" "$dir/01-configure.txt"
    verify_mode "$w" "$h" "$dir/02-formats-before.txt"

    sudo dmesg --color=never > "$dir/03-dmesg-before.txt"
    local before_lines
    before_lines="$(wc -l < "$dir/03-dmesg-before.txt")"

    set +e
    {
        echo '$ timeout 60s v4l2-ctl -d '"$VIDEO"' --stream-mmap=4 --stream-count=300 --stream-poll'
        /usr/bin/time -p timeout 60s v4l2-ctl -d "$VIDEO" \
            --stream-mmap=4 --stream-count=300 --stream-poll
    } > "$dir/04-stream.txt" 2>&1
    local rc=$?
    set -e
    echo "$rc" > "$dir/05-exit-code.txt"

    sudo dmesg --color=never > "$dir/06-dmesg-after.txt"
    tail -n "+$((before_lines + 1))" "$dir/06-dmesg-after.txt" > "$dir/07-dmesg-new.txt" || true
    grep -i -E 'ov5693|ipu6|csi2|frame sync|transfer fifo|overflow|stream' "$dir/07-dmesg-new.txt" \
        > "$dir/08-dmesg-camera-filtered.txt" || true

    local frame_sync fifo
    frame_sync="$(grep -ic 'Frame sync error' "$dir/07-dmesg-new.txt" || true)"
    fifo="$(grep -ic 'Transfer FIFO overflow' "$dir/07-dmesg-new.txt" || true)"

    {
        echo "mode=${w}x${h}"
        echo "exit_code=$rc"
        echo "frame_sync_error_count=$frame_sync"
        echo "transfer_fifo_overflow_count=$fifo"
        if [ "$rc" -eq 0 ]; then
            echo 'capture_300=PASS'
        elif [ "$rc" -eq 124 ]; then
            echo 'capture_300=TIMEOUT'
        else
            echo 'capture_300=FAIL'
        fi
    } > "$dir/09-summary.txt"

    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
}

snapshot_formats "$STAGE/01-initial-formats.txt"
sudo dmesg --color=never > "$STAGE/02-initial-dmesg.txt"

full_rc=0
run_capture 01-fullres 2592 1944 || full_rc=$?

if [ "$full_rc" -eq 0 ]; then
    sleep 2
    binned_rc=0
    run_capture 02-binned 1296 972 || binned_rc=$?
else
    binned_rc=125
    echo 'Skipped because full-resolution control failed.' > "$STAGE/02-binned-SKIPPED.txt"
fi

# Always leave the graph in the known full-resolution configuration.
configure_mode 2592 1944 "$STAGE/03-restore-fullres.txt" || true
snapshot_formats "$STAGE/04-final-formats.txt" || true

{
    echo "fullres_exit_code=$full_rc"
    echo "binned_exit_code=$binned_rc"
    if [ -f "$STAGE/01-fullres/09-summary.txt" ]; then
        echo
        echo '===== full resolution ====='
        cat "$STAGE/01-fullres/09-summary.txt"
    fi
    if [ -f "$STAGE/02-binned/09-summary.txt" ]; then
        echo
        echo '===== binned ====='
        cat "$STAGE/02-binned/09-summary.txt"
    fi
} > "$STAGE/05-overall-summary.txt"

cat "$STAGE/05-overall-summary.txt"

[ "$full_rc" -eq 0 ] || exit "$full_rc"
[ "$binned_rc" -eq 0 ] || exit "$binned_rc"
