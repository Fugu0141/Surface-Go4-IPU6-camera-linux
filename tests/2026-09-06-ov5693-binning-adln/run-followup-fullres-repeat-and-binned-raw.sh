#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/11-followup-fullres-repeat-binned-raw"
SENSOR=/dev/v4l-subdev4
CSI=/dev/v4l-subdev1
VIDEO=/dev/video8
CODE=0x3007
FOURCC=BG10
mkdir -p "$STAGE"

fail(){ echo "ERROR: $*" >&2; exit 1; }
[ "$(uname -r)" = "7.0.0-30-generic" ] || fail "unexpected kernel"
for n in "$SENSOR" "$CSI" "$VIDEO"; do [ -e "$n" ] || fail "$n missing"; done

configure_mode(){
  local w="$1" h="$2"
  v4l2-ctl -d "$SENSOR" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
  v4l2-ctl -d "$CSI" --set-subdev-fmt pad=0,width="$w",height="$h",code="$CODE" >/dev/null
  v4l2-ctl -d "$CSI" --set-subdev-fmt pad=1,width="$w",height="$h",code="$CODE" >/dev/null
  v4l2-ctl -d "$VIDEO" --set-fmt-video=width="$w",height="$h",pixelformat="$FOURCC",field=none >/dev/null
}

snapshot(){
  local out="$1"
  {
    echo '===== sensor ====='; v4l2-ctl -d "$SENSOR" --get-subdev-fmt pad=0
    echo '===== CSI sink ====='; v4l2-ctl -d "$CSI" --get-subdev-fmt pad=0
    echo '===== CSI source ====='; v4l2-ctl -d "$CSI" --get-subdev-fmt pad=1
    echo '===== capture ====='; v4l2-ctl -d "$VIDEO" --get-fmt-video
    echo '===== controls ====='; v4l2-ctl -d "$SENSOR" --all
  } > "$out" 2>&1
}

# 1) Repeat full-resolution 300-frame run to distinguish mode-specific FIFO errors
#    from a first-stream-after-boot transient.
configure_mode 2592 1944
snapshot "$STAGE/01-fullres-repeat-before.txt"
sudo dmesg --color=never > "$STAGE/02-fullres-repeat-dmesg-before.txt"
before_lines=$(wc -l < "$STAGE/02-fullres-repeat-dmesg-before.txt")
set +e
/usr/bin/time -p timeout 60s v4l2-ctl -d "$VIDEO" --stream-mmap=4 --stream-count=300 --stream-poll \
  > "$STAGE/03-fullres-repeat-stream.txt" 2>&1
full_rc=$?
set -e
sudo dmesg --color=never > "$STAGE/04-fullres-repeat-dmesg-after.txt"
tail -n "+$((before_lines+1))" "$STAGE/04-fullres-repeat-dmesg-after.txt" > "$STAGE/05-fullres-repeat-dmesg-new.txt" || true
full_fs=$(grep -ic 'Frame sync error' "$STAGE/05-fullres-repeat-dmesg-new.txt" || true)
full_fifo=$(grep -ic 'Transfer FIFO overflow' "$STAGE/05-fullres-repeat-dmesg-new.txt" || true)
{
  echo "exit_code=$full_rc"
  echo "progress_frame_count=$(tr -cd '<' < "$STAGE/03-fullres-repeat-stream.txt" | wc -c)"
  echo "frame_sync_error_count=$full_fs"
  echo "transfer_fifo_overflow_count=$full_fifo"
} > "$STAGE/06-fullres-repeat-summary.txt"

# 2) Capture one binned raw frame. Keep test_pattern disabled: this preserves
#    the real optical Bayer mosaic for phase analysis after upload.
configure_mode 1296 972
v4l2-ctl -d "$SENSOR" -c test_pattern=0 >/dev/null
snapshot "$STAGE/07-binned-before-raw.txt"
rm -f "$STAGE/binned-1296x972-bg10.raw"
set +e
v4l2-ctl -d "$VIDEO" --stream-mmap=4 --stream-count=1 --stream-to="$STAGE/binned-1296x972-bg10.raw" \
  > "$STAGE/08-binned-raw-capture.txt" 2>&1
raw_rc=$?
set -e
{
  echo "exit_code=$raw_rc"
  stat -c 'size_bytes=%s' "$STAGE/binned-1296x972-bg10.raw" 2>/dev/null || true
  sha256sum "$STAGE/binned-1296x972-bg10.raw" 2>/dev/null || true
  echo "binned_y_offset=$(cat /sys/module/ov5693/parameters/binned_y_offset 2>/dev/null || true)"
} > "$STAGE/09-binned-raw-summary.txt"

# Restore known full-resolution graph.
configure_mode 2592 1944
snapshot "$STAGE/10-final-fullres.txt"

cat "$STAGE/06-fullres-repeat-summary.txt"
echo
cat "$STAGE/09-binned-raw-summary.txt"

[ "$full_rc" -eq 0 ] || exit "$full_rc"
[ "$raw_rc" -eq 0 ] || exit "$raw_rc"
