#!/usr/bin/env bash
# Collect read-only Linux camera diagnostics for Windows/Linux comparison.

set -u
set -o pipefail

output_dir=""
use_sudo=0
debug_libcamera=0

usage() {
    cat <<'EOF'
Usage: collect.sh [--output DIR] [--sudo] [--debug-libcamera]

  --output DIR       Destination (default: ./camera-dump-linux-<timestamp>)
  --sudo             Use non-interactive sudo for privileged diagnostics
  --debug-libcamera  Capture a verbose `cam -l` log
EOF
}

while (($#)); do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 2; }
            output_dir=$2
            shift 2
            ;;
        --sudo)
            use_sudo=1
            shift
            ;;
        --debug-libcamera)
            debug_libcamera=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

timestamp=$(date -u +%Y%m%d-%H%M%S)
if [[ -z "$output_dir" ]]; then
    output_dir="$PWD/camera-dump-linux-$timestamp"
fi
mkdir -p "$output_dir"/{system,pci-usb,kernel,media,v4l2,sysfs,acpi,modules,libcamera,desktop}
output_dir=$(cd "$output_dir" && pwd -P)
errors_file="$output_dir/collection-errors.txt"
: >"$errors_file"

have() {
    command -v "$1" >/dev/null 2>&1
}

record_error() {
    printf '%s\n' "$*" >>"$errors_file"
}

capture() {
    local relative=$1
    shift
    local target="$output_dir/$relative"
    if ! have "$1"; then
        printf 'UNAVAILABLE: %s\n' "$1" >"$target"
        record_error "$relative: command unavailable: $1"
        return 0
    fi
    if ! "$@" >"$target" 2>&1; then
        record_error "$relative: command failed: $*"
    fi
}

capture_root() {
    local relative=$1
    shift
    local target="$output_dir/$relative"
    if ! have "$1"; then
        printf 'UNAVAILABLE: %s\n' "$1" >"$target"
        record_error "$relative: command unavailable: $1"
        return 0
    fi
    if ((EUID == 0)); then
        "$@" >"$target" 2>&1 || record_error "$relative: command failed: $*"
    elif ((use_sudo)) && have sudo; then
        sudo -n "$@" >"$target" 2>&1 || record_error "$relative: privileged command failed: $*"
    else
        "$@" >"$target" 2>&1 || record_error "$relative: unprivileged command failed: $*"
    fi
}

capture_shell() {
    local relative=$1
    local script=$2
    local target="$output_dir/$relative"
    if ! bash -o pipefail -c "$script" >"$target" 2>&1; then
        record_error "$relative: pipeline failed"
    fi
}

echo "Collecting Surface Go 4 camera diagnostics in: $output_dir"

capture system/uname.txt uname -a
capture system/os-release.txt sh -c 'cat /etc/os-release'
capture system/dmi.txt sh -c 'for f in /sys/devices/virtual/dmi/id/{sys_vendor,product_name,product_version,board_name,bios_vendor,bios_version,bios_date}; do printf "--- %s ---\n" "$f"; cat "$f" 2>/dev/null || true; done'
capture system/udevadm-info.txt udevadm info --export-db
capture pci-usb/lspci-nnk.txt lspci -nnk
capture pci-usb/lsusb.txt lsusb
capture pci-usb/lsusb-tree.txt lsusb -t

capture_root kernel/dmesg.txt dmesg --color=never
capture_root kernel/journal-kernel.txt journalctl -k --no-pager -b
capture_shell kernel/camera-relevant.txt "(dmesg --color=never 2>/dev/null || journalctl -k --no-pager -b 2>/dev/null) | grep -Ei 'ipu6|isys|psys|ov8865|ov5693|dw9714|dw9719|ad5820|vcm|lens|camera|csi|mipi|int3472|int347a|int33be|privacy|led'"

capture modules/lsmod.txt lsmod
capture_shell modules/relevant-modules.txt "lsmod 2>/dev/null | grep -Ei 'ipu|ov8865|ov5693|dw9714|dw9719|ad5820|v4l2|videodev|int3472'"
if have lsmod && have modinfo; then
    while read -r module _; do
        [[ -n "$module" ]] || continue
        if [[ "$module" =~ (ipu|ov8865|ov5693|dw9714|dw9719|ad5820|v4l2|videodev|int3472) ]]; then
            capture "modules/modinfo-$module.txt" modinfo "$module"
        fi
    done < <(lsmod | tail -n +2)
fi

capture media/media-ctl-all.txt media-ctl -p
if have media-ctl; then
    for node in /dev/media*; do
        [[ -e "$node" ]] || continue
        name=$(basename "$node")
        capture "media/$name-topology.txt" media-ctl -d "$node" -p
    done
fi

capture v4l2/list-devices.txt v4l2-ctl --list-devices
if have v4l2-ctl; then
    for node in /dev/video* /dev/v4l-subdev*; do
        [[ -e "$node" ]] || continue
        name=$(basename "$node")
        capture "v4l2/$name-all.txt" v4l2-ctl -d "$node" --all
        capture "v4l2/$name-controls.txt" v4l2-ctl -d "$node" --list-ctrls
        capture "v4l2/$name-control-menus.txt" v4l2-ctl -d "$node" --list-ctrls-menus
        capture "v4l2/$name-formats.txt" v4l2-ctl -d "$node" --list-formats-ext
    done
fi

capture sysfs/i2c-tree.txt find -L /sys/bus/i2c/devices -maxdepth 3 -printf '%y %p -> %l\n'
capture sysfs/platform-tree.txt find -L /sys/bus/platform/devices -maxdepth 2 -printf '%y %p -> %l\n'
capture sysfs/video4linux-tree.txt find -L /sys/class/video4linux -maxdepth 4 -printf '%y %p -> %l\n'
capture sysfs/leds-tree.txt find -L /sys/class/leds -maxdepth 3 -printf '%y %p -> %l\n'
capture_shell sysfs/camera-device-attributes.txt "for d in /sys/bus/i2c/devices/* /sys/bus/platform/devices/* /sys/class/video4linux/*; do case \"\$(basename \"\$d\") \$(cat \"\$d/name\" 2>/dev/null) \$(cat \"\$d/modalias\" 2>/dev/null)\" in *[Ii][Pp][Uu]*|*[Oo][Vv]8865*|*[Oo][Vv]5693*|*[Dd][Ww]9714*|*[Vv][Cc][Mm]*|*[Cc][Aa][Mm][Ee][Rr][Aa]*|*INT347*) echo \"=== \$d ===\"; find -L \"\$d\" -maxdepth 2 -type f -size -64k -print -exec sh -c 'cat \"\$1\" 2>/dev/null || true' sh {} \;; esac; done"
capture_shell sysfs/software-nodes.txt "find -L /sys/kernel/software_nodes -maxdepth 4 -printf '%y %p -> %l\n' 2>/dev/null"

if have acpidump; then
    if ((EUID == 0)); then
        acpidump -o "$output_dir/acpi/acpidump.bin" 2>"$output_dir/acpi/acpidump-error.txt" || record_error 'acpi/acpidump.bin: acpidump failed'
        acpidump >"$output_dir/acpi/acpidump.txt" 2>>"$output_dir/acpi/acpidump-error.txt" || true
    elif ((use_sudo)) && have sudo; then
        sudo -n acpidump -o "$output_dir/acpi/acpidump.bin" 2>"$output_dir/acpi/acpidump-error.txt" || record_error 'acpi/acpidump.bin: privileged acpidump failed'
        sudo -n acpidump >"$output_dir/acpi/acpidump.txt" 2>>"$output_dir/acpi/acpidump-error.txt" || true
    else
        acpidump -o "$output_dir/acpi/acpidump.bin" 2>"$output_dir/acpi/acpidump-error.txt" || record_error 'acpi/acpidump.bin: unprivileged acpidump failed'
    fi
else
    printf 'UNAVAILABLE: acpidump\n' >"$output_dir/acpi/acpidump-error.txt"
fi
capture_shell acpi/sysfs-acpi-devices.txt "find -L /sys/bus/acpi/devices -maxdepth 3 -printf '%y %p -> %l\n' 2>/dev/null | grep -Ei 'INT347A|INT33BE|CAMR|CAMF|OV8865|OV5693|IPU|camera|vcm|lens'"

capture libcamera/cam-list.txt cam -l
capture libcamera/cam-help.txt cam --help
capture libcamera/pkg-config-version.txt pkg-config --modversion libcamera
capture libcamera/ldconfig.txt ldconfig -p
if have dpkg-query; then
    capture_shell libcamera/packages-debian.txt "dpkg-query -W -f='\${Package} \${Version}\\n' 'libcamera*' 'gstreamer1.0-libcamera' 'libspa-0.2-libcamera' 'pipewire*' 'wireplumber*' 2>/dev/null"
elif have rpm; then
    capture_shell libcamera/packages-rpm.txt "rpm -qa | grep -Ei 'libcamera|pipewire|wireplumber|ipu6'"
fi
if have libcamerify; then
    capture libcamera/libcamerify-help.txt libcamerify --help
fi
if ((debug_libcamera)) && have cam; then
    capture libcamera/cam-list-debug.txt env 'LIBCAMERA_LOG_LEVELS=*:DEBUG' cam -l
fi

capture desktop/pipewire-nodes.txt pw-cli list-objects Node
capture desktop/wpctl-status.txt wpctl status
capture desktop/wireplumber-status.txt systemctl --user status wireplumber
capture desktop/pipewire-status.txt systemctl --user status pipewire
capture_shell desktop/relevant-pipewire-nodes.txt "pw-cli list-objects Node 2>/dev/null | grep -Ei 'camera|libcamera|ov8865|ov5693|ipu6|media.class|node.name|node.description'"

cat >"$output_dir/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "collectedAtUtc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname 2>/dev/null || printf unknown)",
  "useSudo": $([[ $use_sudo -eq 1 ]] && printf true || printf false),
  "debugLibcamera": $([[ $debug_libcamera -eq 1 ]] && printf true || printf false),
  "notice": "This is a read-only observation dump. Absence of data may reflect missing tools or permissions; see collection-errors.txt."
}
EOF

echo "Collection complete. Review and redact before sharing: $output_dir"
