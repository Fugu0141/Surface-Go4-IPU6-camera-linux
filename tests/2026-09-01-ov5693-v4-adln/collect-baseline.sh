#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/00-baseline"
mkdir -p "$OUT"

run() {
    local file="$1"
    shift
    {
        echo '$' "$@"
        "$@"
    } >"$OUT/$file" 2>&1 || true
}

run_sh() {
    local file="$1"
    shift
    {
        echo '$' "$*"
        bash -lc "$*"
    } >"$OUT/$file" 2>&1 || true
}

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Surface Go 4 OV5693 upstream v4 baseline before applying any new patches"
} > "$OUT/00-metadata.txt"

run "01-uname.txt" uname -a
run_sh "02-os-release.txt" 'cat /etc/os-release'
run_sh "03-kernel-cmdline.txt" 'cat /proc/cmdline'
run_sh "04-secure-boot.txt" 'command -v mokutil >/dev/null && mokutil --sb-state || echo "mokutil not installed"'
run_sh "05-pci.txt" 'lspci -nn -k'
run_sh "06-pci-ipu-filtered.txt" 'lspci -nn -k | grep -i -A5 -B2 -E "image|ipu|camera|multimedia" || true'
run_sh "07-loaded-modules.txt" 'lsmod | sort'
run_sh "08-ipu-modules-filtered.txt" 'lsmod | grep -E "(^|_)ipu6|ov5693|ov8865|dw9714" || true'
run_sh "09-modinfo-ov5693.txt" 'modinfo ov5693 2>&1 || true'
run_sh "10-modinfo-intel-ipu6.txt" 'for m in intel_ipu6 intel_ipu6_isys intel_ipu6_psys; do echo "===== $m ====="; modinfo "$m" 2>&1 || true; done'
run_sh "11-i2c-devices.txt" 'ls -la /sys/bus/i2c/devices/'
run_sh "12-camera-i2c-filtered.txt" 'find /sys/bus/i2c/devices -maxdepth 2 -type f \( -name name -o -name modalias \) -print -exec cat {} \; 2>/dev/null | grep -i -B2 -A2 -E "INT33BE|OVTI5693|ov5693|ov8865|dw9714" || true'
run_sh "13-sysfs-camera-links.txt" 'ls -la /sys/bus/i2c/devices/ | grep -E "INT33BE|OVTI5693|ov5693|ov8865|dw9714" || true'
run_sh "14-acpi-paths.txt" 'for d in /sys/bus/i2c/devices/*; do n=$(cat "$d/name" 2>/dev/null || true); m=$(cat "$d/modalias" 2>/dev/null || true); if echo "$n $m $(basename "$d")" | grep -qiE "INT33BE|OVTI5693|ov5693|ov8865"; then echo "===== $d ====="; echo "name=$n"; echo "modalias=$m"; readlink -f "$d/firmware_node" 2>/dev/null || true; cat "$d/firmware_node/path" 2>/dev/null || true; fi; done'
run_sh "15-media-devices.txt" 'command -v media-ctl >/dev/null && media-ctl -p || echo "media-ctl not installed"'
run_sh "16-cam-version.txt" 'command -v cam >/dev/null && cam --version || echo "cam not installed"'
run_sh "17-cam-list.txt" 'command -v cam >/dev/null && cam -l || echo "cam not installed"'
run_sh "18-libcamera-packages.txt" 'dpkg-query -W "libcamera*" 2>/dev/null || true'
run_sh "19-kernel-packages.txt" 'dpkg-query -W "linux-image*" "linux-headers*" 2>/dev/null | grep "$(uname -r)" || true'
run_sh "20-git-logging-repo.txt" 'cd "'"$ROOT"'"/../../.." && git status --short --branch && git rev-parse HEAD'

# Kernel log: try without sudo first. If restricted, retry interactively with sudo.
if dmesg -T >"$OUT/21-dmesg-full.txt" 2>&1; then
    :
else
    {
        echo "Unprivileged dmesg was unavailable. Retrying with sudo..."
        sudo dmesg -T
    } >"$OUT/21-dmesg-full.txt" 2>&1 || true
fi

run_sh "22-dmesg-camera-filtered.txt" 'grep -i -E "ipu6|ov5693|ov8865|dw9714|INT33BE|OVTI5693|csi2|stream stop|stream close" "'"$OUT"'"/21-dmesg-full.txt || true'

cat > "$OUT/README.md" <<'EOF'
# Baseline

Collected before applying the upstream v4 OV5693 series or the proposed Surface Go 4 ADL-N bridge entry.

The key checks for this stage are:

- the machine is Surface Go 4 / Alder Lake-N IPU6
- the exact kernel and module build are recorded
- Secure Boot/module signing state is recorded
- the OV5693 enumeration is captured (`INT33BE` vs `OVTI5693`)
- current camera discovery and relevant kernel messages are preserved
EOF

echo "Baseline collected in: $OUT"
echo "Before patching anything, inspect 12-camera-i2c-filtered.txt, 13-sysfs-camera-links.txt, 14-acpi-paths.txt, 17-cam-list.txt, and 22-dmesg-camera-filtered.txt."
