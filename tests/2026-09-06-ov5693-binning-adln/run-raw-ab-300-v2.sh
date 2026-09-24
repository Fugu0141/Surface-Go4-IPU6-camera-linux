#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/10-raw-ab-300"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CODE=0x3007
FOURCC=BG10
RESTORING=0

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

configure_mode() {
    local w="$1" h="$2" log="$3"
    : > "$log"

    echo "== set sensor ${w}x${h} SBGGR10 ==" >> "$log"
    v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >> "$log" 2>&1 \
        || { echo 'sensor set_fmt failed' >> "$log"; return 10; }

    echo "== set CSI sink ${w}x${h} SBGGR10 ==" >> "$log"
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >> "$log" 2>&1 \
        || { echo 'CSI sink set_fmt failed' >> "$log"; return 11; }

    echo "== set CSI source ${w}x${h} SBGGR10 ==" >> "$log"
    v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width="$w",height="$h",code="$CODE" >> "$log" 2>&1 \
        || { echo 'CSI source set_fmt failed' >> "$log"; return 12; }

    echo "== set capture ${w}x${h} BG10 ==" >> "$log"
    v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$w",height="$h",pixelformat="$FOURCC",field=none >> "$log" 2>&1 \
        || { echo 'capture set_fmt failed' >> "$log"; return 13; }
}

snapshot_formats() {
    local out="$1"
    : > "$out"
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
    } >> "$out" 2>&1
}

verify_mode() {
    local w="$1" h="$2" out="$3"
    snapshot_formats "$out" || return 20

    local dim_count
    dim_count="$(grep -Ec "Width/Height[[:space:]]*: ${w}/${h}" "$out" || true)"
    [ "$dim_count" -ge 4 ] || return 21
    grep -F "Pixel Format      : '$FOURCC'" "$out" >/dev/null || return 22
    [ "$(grep -Fc 'Mediabus Code     : 0x3007 (MEDIA_BUS_FMT_SBGGR10_1X10)' "$out" || true)" -ge 3 ] || return 23
}

restore_fullres() {
    [ "$RESTORING" -eq 0 ] || return 0
    RESTORING=1
    configure_mode 2592 1944 "$STAGE/90-restore-fullres.txt" || true
    snapshot_formats "$STAGE/91-final-formats.txt" || true
}
trap restore_fullres EXIT INT TERM

run_capture() {
    local label="$1" w="$2" h="$3"
    local dir="$STAGE/$label"
    mkdir -p "$dir"

    configure_mode "$w" "$h" "$dir/01-configure.txt" || return $?
    verify_mode "$w" "$h" "$dir/02-formats-before.txt" || return $?

    sudo dmesg --color=never > "$dir/03-dmesg-before.txt" || return 30
    local before_lines
    before_lines="$(wc -l < "$dir/03-dmesg-before.txt")"

    {
        echo '$ timeout 60s v4l2-ctl -d '"$VIDEO"' --stream-mmap=4 --stream-count=300 --stream-poll'
        /usr/bin/time -p timeout 60s v4l2-ctl -d "$VIDEO" \
            --stream-mmap=4 --stream-count=300 --stream-poll
    } > "$dir/04-stream.txt" 2>&1
    local rc=$?
    echo "$rc" > "$dir/05-exit-code.txt"

    sudo dmesg --color=never > "$dir/06-dmesg-after.txt" || return 31
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

    return "$rc"
}

[ "$(uname -r)" = "7.0.0-30-generic" ] || fail "unexpected kernel: $(uname -r)"
[ -e "$SENSOR" ] || fail "$SENSOR missing"
[ -e "$CSI" ] || fail "$CSI missing"
[ -e "$VIDEO" ] || fail "$VIDEO missing"

v4l2-ctl -d "$VIDEO" --all | grep -F 'Intel IPU6 ISYS Capture 8' >/dev/null \
    || fail "$VIDEO is not Intel IPU6 ISYS Capture 8"
media-ctl -p | grep -F 'ov5693 2-0036' >/dev/null || fail 'ov5693 entity missing'
[ "$(cat /sys/module/ov5693/parameters/binned_y_offset 2>/dev/null || true)" = "2" ] \
    || fail 'binned_y_offset is not 2'

sudo -v || fail 'sudo authentication failed'

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Kernel: $(uname -r)"
    echo "Sensor: $SENSOR (ov5693 2-0036)"
    echo "CSI2: $CSI (Intel IPU6 CSI2 1)"
    echo "Capture: $VIDEO (Intel IPU6 ISYS Capture 8)"
    echo "Sensor/CSI: SBGGR10_1X10 ($CODE)"
    echo "Capture FourCC: $FOURCC (unpacked 10-bit BGGR)"
    echo "binned_y_offset: 2"
    echo "Frames per mode: 300"
    echo "Frame payloads are discarded for this transport A/B test."
} > "$STAGE/00-metadata.txt"

snapshot_formats "$STAGE/01-initial-formats.txt" || fail 'could not snapshot initial formats'
sudo dmesg --color=never > "$STAGE/02-initial-dmesg.txt" || fail 'could not record initial dmesg'

full_rc=0
run_capture 01-fullres 2592 1944 || full_rc=$?

binned_rc=125
if [ "$full_rc" -eq 0 ]; then
    sleep 2
    binned_rc=0
    run_capture 02-binned 1296 972 || binned_rc=$?
else
    echo 'Skipped because full-resolution control failed.' > "$STAGE/02-binned-SKIPPED.txt"
fi

restore_fullres
trap - EXIT INT TERM

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
