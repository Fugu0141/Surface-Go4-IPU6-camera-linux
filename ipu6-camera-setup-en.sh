#!/usr/bin/env bash

# ============================================================
# Surface Go 4 / Intel IPU6 Camera Setup Script
# Ubuntu 26.04 LTS + system libcamera 0.7 packages
#
# Target:
#   - Microsoft Surface Go 4
#   - Intel N200
#   - Intel IPU6
#   - Front camera: OV5693
#   - Rear camera: OV8865
#   - VCM / lens actuator: DW9714
#
# Normal setup policy:
#   - Use Ubuntu 26.04 packaged libcamera 0.7.
#   - Do not build libcamera from source by default.
#   - Do not force /usr/local libcamera by default.
#   - Install v4l-utils instead of a standalone media-ctl package.
#
# Known limitations detected by this script:
#   - Missing ov8865.yaml / ov5693.yaml may cause uncalibrated image quality.
#   - DW9714 VCM may be bound but may not expose a V4L2 subdev node.
#   - If DW9714 has no /dev/v4l-subdevX node, autofocus/lens control will not work.
# ============================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="Surface Go 4 / Intel IPU6 Camera Setup for Ubuntu 26.04 LTS"
readonly TARGET_UBUNTU_VERSION="26.04"
readonly MIN_KERNEL_MAJOR=6
readonly MIN_KERNEL_MINOR=10

readonly LOCAL_LIBCAMERA_LDCONFIG_FILE="/etc/ld.so.conf.d/libcamera-local.conf"
readonly LOCAL_LIBCAMERA_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu"
readonly LIBCAMERA_SOURCE_DIR="${HOME}/libcamera"

readonly FRONT_CAMERA_NAME='\_SB_.PC00.I2C3.CAMF'
readonly BACK_CAMERA_NAME='\_SB_.PC00.I2C5.CAMR'

RUN_DIAGNOSTICS_ONLY=false
REMOVE_LOCAL_LIBCAMERA_CONFIG=false
SOURCE_BUILD=false
ASSUME_YES=false

log_info() {
  printf '\n[INFO] %s\n' "$1"
}

log_warn() {
  printf '\n[WARN] %s\n' "$1" >&2
}

log_error() {
  printf '\n[ERROR] %s\n' "$1" >&2
}

print_usage() {
  cat <<'EOF'
Usage:
  ./ipu6-camera-setup-en.sh [options]

Options:
  --diagnose-only
      Do not install packages. Only print diagnostic information.

  --remove-local-libcamera-config
      Remove /etc/ld.so.conf.d/libcamera-local.conf if it exists.
      This is useful when an older source-built libcamera in /usr/local
      is overriding Ubuntu 26.04's packaged libcamera.

  --source-build
      Build libcamera from source.
      Not recommended by default on Ubuntu 26.04 LTS.
      Use this only when Ubuntu packaged libcamera does not work.

  -y, --yes
      Assume yes for apt operations.

  -h, --help
      Show this help message.

Recommended normal setup for Ubuntu 26.04 LTS:
  ./ipu6-camera-setup-en.sh -y

Diagnostics only:
  ./ipu6-camera-setup-en.sh --diagnose-only

When old /usr/local libcamera may be interfering:
  ./ipu6-camera-setup-en.sh --remove-local-libcamera-config -y

EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --diagnose-only)
        RUN_DIAGNOSTICS_ONLY=true
        shift
        ;;
      --remove-local-libcamera-config)
        REMOVE_LOCAL_LIBCAMERA_CONFIG=true
        shift
        ;;
      --source-build)
        SOURCE_BUILD=true
        shift
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    log_error "Required command is missing: $command_name"
    exit 1
  fi
}

check_basic_commands() {
  require_command sudo
  require_command uname
  require_command grep
  require_command awk
  require_command cut
  require_command sed
  require_command dpkg
  require_command dpkg-query
  require_command find
  require_command readlink

  if [[ "$RUN_DIAGNOSTICS_ONLY" == false ]]; then
    require_command apt
  fi
}

apt_install() {
  local apt_yes_option=()

  if [[ "$ASSUME_YES" == true ]]; then
    apt_yes_option=(-y)
  fi

  sudo apt install "${apt_yes_option[@]}" "$@"
}

is_package_installed() {
  local package_name="$1"

  dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q "install ok installed"
}

warn_if_package_missing() {
  local package_name="$1"

  if is_package_installed "$package_name"; then
    printf '[OK] %s is installed\n' "$package_name"
  else
    printf '[MISSING] %s is not installed\n' "$package_name"
  fi
}

check_ubuntu_version() {
  if ! command -v lsb_release >/dev/null 2>&1; then
    log_warn "lsb_release is not installed. Ubuntu version check skipped."
    return
  fi

  local detected_version
  detected_version="$(lsb_release -rs || true)"

  if [[ -z "$detected_version" ]]; then
    log_warn "Could not detect Ubuntu version."
    return
  fi

  if [[ "$detected_version" != "$TARGET_UBUNTU_VERSION" ]]; then
    log_warn "This script is designed for Ubuntu ${TARGET_UBUNTU_VERSION} LTS."
    log_warn "Detected Ubuntu version: ${detected_version}"
    log_warn "Continuing, but package names or libcamera versions may differ."
    return
  fi

  log_info "Detected Ubuntu ${TARGET_UBUNTU_VERSION} LTS."
}

check_kernel_version() {
  local kernel_version
  kernel_version="$(uname -r)"

  local kernel_major
  local kernel_minor

  kernel_major="$(printf '%s' "$kernel_version" | cut -d. -f1)"
  kernel_minor="$(printf '%s' "$kernel_version" | cut -d. -f2)"

  if [[ ! "$kernel_major" =~ ^[0-9]+$ ]] || [[ ! "$kernel_minor" =~ ^[0-9]+$ ]]; then
    log_warn "Could not parse kernel version: $kernel_version"
    return
  fi

  if (( kernel_major < MIN_KERNEL_MAJOR )); then
    log_error "Kernel is too old: $kernel_version"
    log_error "Expected kernel ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+ for modern IPU6 support."
    exit 1
  fi

  if (( kernel_major == MIN_KERNEL_MAJOR && kernel_minor < MIN_KERNEL_MINOR )); then
    log_error "Kernel is too old: $kernel_version"
    log_error "Expected kernel ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR}+ for modern IPU6 support."
    exit 1
  fi

  log_info "Kernel version looks usable: $kernel_version"
}

check_local_libcamera_override() {
  log_info "Checking for /usr/local libcamera override."

  if [[ -f "$LOCAL_LIBCAMERA_LDCONFIG_FILE" ]]; then
    log_warn "Found local libcamera ldconfig file: $LOCAL_LIBCAMERA_LDCONFIG_FILE"
    log_warn "This may force applications to load /usr/local libcamera instead of Ubuntu packaged libcamera."
  else
    log_info "No libcamera-local ldconfig override file found."
  fi

  if [[ -d "$LOCAL_LIBCAMERA_LIBRARY_PATH" ]]; then
    if find "$LOCAL_LIBCAMERA_LIBRARY_PATH" -maxdepth 1 -name 'libcamera*.so*' 2>/dev/null | grep -q .; then
      log_warn "Found libcamera libraries under: $LOCAL_LIBCAMERA_LIBRARY_PATH"
      log_warn "Old source-built libcamera may interfere with Ubuntu 26.04 packages."
    else
      log_info "No libcamera shared libraries found directly under $LOCAL_LIBCAMERA_LIBRARY_PATH."
    fi
  else
    log_info "Local libcamera library path does not exist: $LOCAL_LIBCAMERA_LIBRARY_PATH"
  fi
}

remove_local_libcamera_config_if_requested() {
  if [[ "$REMOVE_LOCAL_LIBCAMERA_CONFIG" != true ]]; then
    return
  fi

  log_info "Requested removal of local libcamera ldconfig override."

  if [[ -f "$LOCAL_LIBCAMERA_LDCONFIG_FILE" ]]; then
    sudo rm -f "$LOCAL_LIBCAMERA_LDCONFIG_FILE"
    sudo ldconfig
    log_info "Removed $LOCAL_LIBCAMERA_LDCONFIG_FILE and refreshed ldconfig."
  else
    log_info "No file to remove: $LOCAL_LIBCAMERA_LDCONFIG_FILE"
  fi
}

install_system_camera_stack() {
  log_info "Installing Ubuntu packaged camera stack."

  sudo apt update

  # Important:
  # Do not install "media-ctl" as a package on Ubuntu 26.04.
  # It may not have an installation candidate.
  # v4l-utils is the correct package to install here.
  apt_install \
    linux-firmware \
    v4l-utils \
    pipewire \
    wireplumber \
    libcamera0.7 \
    libcamera-ipa \
    libcamera-tools \
    libcamera-v4l2 \
    gstreamer1.0-libcamera \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-good \
    libspa-0.2-libcamera

  log_info "System camera stack installation completed."
}

warn_about_legacy_or_conflicting_packages() {
  log_info "Checking for legacy or potentially conflicting camera packages."

  local legacy_packages=(
    "intel-ipu6-dkms"
    "libcamhal-ipu6"
    "v4l2-relayd"
    "v4l2loopback-dkms"
    "pipewire-libcamera"
  )

  local found_any=false

  for package_name in "${legacy_packages[@]}"; do
    if is_package_installed "$package_name"; then
      log_warn "Potentially conflicting package installed: $package_name"
      found_any=true
    fi
  done

  if [[ "$found_any" == false ]]; then
    log_info "No obvious legacy/conflicting packages detected."
  else
    log_warn "Do not remove packages blindly."
    log_warn "If Ubuntu 26.04 packaged libcamera does not work, review these packages manually."
  fi
}

restart_user_camera_services() {
  log_info "Restarting user PipeWire and WirePlumber services."

  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl is missing. Skipping service restart."
    return
  fi

  local services=(
    "pipewire.service"
    "pipewire-pulse.service"
    "wireplumber.service"
    "xdg-desktop-portal.service"
    "xdg-desktop-portal-gnome.service"
  )

  for service_name in "${services[@]}"; do
    if systemctl --user list-unit-files "$service_name" >/dev/null 2>&1; then
      systemctl --user restart "$service_name" 2>/dev/null || log_warn "Failed to restart user service: $service_name"
    fi
  done

  log_info "Service restart step completed."
}

build_libcamera_from_source_if_requested() {
  if [[ "$SOURCE_BUILD" != true ]]; then
    return
  fi

  log_warn "Source-build mode was requested."
  log_warn "On Ubuntu 26.04 LTS, packaged libcamera 0.7 is recommended first."
  log_warn "This mode may install libcamera into /usr/local and can conflict with system packages."

  sudo apt update

  apt_install \
    git \
    meson \
    ninja-build \
    pkg-config \
    libboost-dev \
    libgnutls28-dev \
    openssl \
    libssl-dev \
    python3-yaml \
    python3-ply \
    libdw-dev \
    libudev-dev \
    libevent-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-good

  if [[ -d "$LIBCAMERA_SOURCE_DIR/.git" ]]; then
    log_info "Existing libcamera source tree found: $LIBCAMERA_SOURCE_DIR"
    git -C "$LIBCAMERA_SOURCE_DIR" fetch --all --tags
  elif [[ -d "$LIBCAMERA_SOURCE_DIR" ]]; then
    log_error "$LIBCAMERA_SOURCE_DIR exists but is not a git repository."
    log_error "Move it away or remove it before using --source-build."
    exit 1
  else
    git clone https://git.libcamera.org/libcamera/libcamera.git "$LIBCAMERA_SOURCE_DIR"
  fi

  cd "$LIBCAMERA_SOURCE_DIR"

  log_info "Configuring libcamera source build."

  meson setup --reconfigure build \
    -Dipas=ipu3,simple \
    -Dcam=enabled \
    -Dgstreamer=enabled \
    -Dqcam=disabled \
    -Dtest=false

  log_info "Building libcamera from source."
  ninja -C build

  log_info "Installing source-built libcamera into /usr/local."
  sudo ninja -C build install

  log_warn "Source-built libcamera has been installed."
  log_warn "This script intentionally does not force /usr/local priority automatically."

  sudo ldconfig
}

print_system_information() {
  log_info "System information"

  printf 'Kernel: '
  uname -r || true

  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -a || true
  fi
}

print_package_information() {
  log_info "Package status"

  local packages=(
    "linux-firmware"
    "v4l-utils"
    "pipewire"
    "wireplumber"
    "libcamera0.7"
    "libcamera-ipa"
    "libcamera-tools"
    "libcamera-v4l2"
    "gstreamer1.0-libcamera"
    "libspa-0.2-libcamera"
  )

  for package_name in "${packages[@]}"; do
    warn_if_package_missing "$package_name"
  done

  echo "--- libcamera package versions ---"
  dpkg-query -W -f='${Package} ${Version}\n' \
    libcamera0.7 \
    libcamera-ipa \
    libcamera-tools \
    libcamera-v4l2 \
    gstreamer1.0-libcamera \
    libspa-0.2-libcamera \
    2>/dev/null || true
}

print_pci_information() {
  log_info "PCI devices related to IPU, imaging, or camera"

  if ! command -v lspci >/dev/null 2>&1; then
    log_warn "lspci is not installed. Install pciutils if needed."
    return
  fi

  echo "--- PCI device 00:05.0 ---"
  lspci -nn -s 00:05.0 || true

  echo "--- Possible camera/IPU PCI devices ---"
  lspci -nn | grep -Ei 'ipu|imaging|camera|multimedia|0480' || \
    log_warn "No matching PCI device found by text search. This may be harmless if V4L2 shows ipu6."
}

print_v4l2_information() {
  log_info "V4L2 devices"

  if command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl --list-devices || log_warn "v4l2-ctl could not list devices."
  else
    log_warn "v4l2-ctl is not available."
  fi

  log_info "Media controller devices"

  if command -v media-ctl >/dev/null 2>&1; then
    local found_media_device=false

    for media_device in /dev/media*; do
      if [[ -e "$media_device" ]]; then
        found_media_device=true
        printf '\n--- %s ---\n' "$media_device"
        media-ctl -d "$media_device" -p 2>/dev/null | head -n 180 || true
      fi
    done

    if [[ "$found_media_device" == false ]]; then
      log_warn "No /dev/media* devices found."
    fi
  else
    log_warn "media-ctl command is not available. This is not fatal."
    log_warn "v4l2-ctl diagnostics are still available through v4l-utils."
  fi
}

print_kernel_camera_logs() {
  log_info "Recent kernel messages related to IPU6 and camera sensors"

  if command -v dmesg >/dev/null 2>&1; then
    sudo dmesg | grep -Ei 'ipu6|isys|psys|ov8865|ov5693|dw9714|camera|camr|camf|ipu|cio2|lens|vcm' | tail -n 160 || \
      log_warn "No matching dmesg lines found."
  else
    log_warn "dmesg is not available."
  fi
}

print_libcamera_information() {
  log_info "libcamera information"

  if ! command -v cam >/dev/null 2>&1; then
    log_warn "cam command is not available. Install libcamera-tools."
    return
  fi

  echo "--- libcamera package versions ---"
  dpkg-query -W -f='${Package} ${Version}\n' libcamera0.7 libcamera-tools 2>/dev/null || true

  printf '\n--- cam --list ---\n'
  cam --list || log_warn "cam --list failed or found no cameras."

  printf '\n--- back camera properties ---\n'
  cam -c "$BACK_CAMERA_NAME" --list-properties || log_warn "Could not list back camera properties."

  printf '\n--- back camera controls ---\n'
  cam -c "$BACK_CAMERA_NAME" --list-controls || log_warn "Could not list back camera controls."

  printf '\n--- front camera properties ---\n'
  cam -c "$FRONT_CAMERA_NAME" --list-properties || log_warn "Could not list front camera properties."

  printf '\n--- front camera controls ---\n'
  cam -c "$FRONT_CAMERA_NAME" --list-controls || log_warn "Could not list front camera controls."

  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    printf '\n--- gst-inspect-1.0 libcamerasrc ---\n'
    if gst-inspect-1.0 libcamerasrc >/dev/null 2>&1; then
      echo "GStreamer libcamerasrc plugin is available."
    else
      log_warn "GStreamer libcamerasrc plugin is not available."
    fi
  else
    log_warn "gst-inspect-1.0 is not available."
  fi
}

print_pipewire_information() {
  log_info "PipeWire camera information"

  if command -v pw-cli >/dev/null 2>&1; then
    pw-cli list-objects 2>/dev/null | grep -Ei 'camera|libcamera|node.description|object.path|media.class|media.role' || \
      log_warn "No camera-related PipeWire objects found."
  else
    log_warn "pw-cli is not available."
  fi

  if command -v wpctl >/dev/null 2>&1; then
    printf '\n--- wpctl status ---\n'
    wpctl status 2>/dev/null | grep -Ei 'camera|video|source|libcamera|ov5693|ov8865' || \
      log_warn "No camera-related WirePlumber status found."
  else
    log_warn "wpctl is not available."
  fi
}

print_lens_and_sensor_topology() {
  log_info "Lens and sensor media topology"

  if ! command -v media-ctl >/dev/null 2>&1; then
    log_warn "media-ctl command is not available."
    return
  fi

  if [[ ! -e /dev/media0 ]]; then
    log_warn "/dev/media0 does not exist."
    return
  fi

  media-ctl -d /dev/media0 -p | \
    grep -Ei 'ov8865|ov5693|dw9714|lens|vcm|CAMR|CAMF' -A20 -B20 || \
    log_warn "No OV/DW lens or sensor entries found in media topology."
}

print_subdev_information() {
  log_info "V4L2 sub-device information"

  if ! compgen -G "/dev/v4l-subdev*" >/dev/null; then
    log_warn "No /dev/v4l-subdev* devices found."
    return
  fi

  for dev in /dev/v4l-subdev*; do
    echo "===== $dev ====="

    if command -v udevadm >/dev/null 2>&1; then
      udevadm info --query=all --name="$dev" 2>/dev/null | \
        grep -Ei 'DEVPATH|DEVNAME|ID_V4L|ID_MODEL|ID_PATH|DRIVER|SUBSYSTEM|dw9714|ov8865|ov5693|ipu' || true
    else
      log_warn "udevadm is not available."
    fi

    if command -v v4l2-ctl >/dev/null 2>&1; then
      v4l2-ctl -d "$dev" --all 2>/dev/null | \
        grep -Ei 'Driver name|Card type|Bus info|dw9714|ov8865|ov5693|focus|ctrl|error' || true
    fi
  done
}

print_vcm_information() {
  log_info "DW9714 VCM information"

  if command -v modinfo >/dev/null 2>&1; then
    echo "--- modinfo dw9714 ---"
    modinfo dw9714 2>/dev/null | grep -Ei 'filename|description|depends|intree|vermagic|alias|name' || \
      log_warn "dw9714 module information is not available."
  else
    log_warn "modinfo is not available."
  fi

  if [[ ! -d /sys/bus/i2c/drivers/dw9714 ]]; then
    log_warn "/sys/bus/i2c/drivers/dw9714 does not exist."
    return
  fi

  echo "--- /sys/bus/i2c/drivers/dw9714 ---"
  ls -l /sys/bus/i2c/drivers/dw9714 || true

  local vcm_link=""
  if [[ -L /sys/bus/i2c/drivers/dw9714/i2c-INT347A:00-VCM ]]; then
    vcm_link="/sys/bus/i2c/drivers/dw9714/i2c-INT347A:00-VCM"
  else
    vcm_link="$(find /sys/bus/i2c/drivers/dw9714 -maxdepth 1 -type l -name '*VCM*' 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -z "$vcm_link" ]]; then
    log_warn "No DW9714 VCM sysfs link was found."
    return
  fi

  local vcm_path
  vcm_path="$(readlink -f "$vcm_link")"

  if [[ -z "$vcm_path" ]] || [[ ! -e "$vcm_path" ]]; then
    log_warn "Could not resolve DW9714 VCM path from: $vcm_link"
    return
  fi

  echo "--- Resolved VCM path ---"
  echo "$vcm_path"

  echo "--- VCM basic files ---"
  for file_name in name modalias uevent; do
    if [[ -f "$vcm_path/$file_name" ]]; then
      echo "[$file_name]"
      cat "$vcm_path/$file_name" || true
    fi
  done

  echo "--- VCM udev info ---"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm info --query=all --path="$vcm_path" 2>/dev/null | \
      grep -Ei 'DEVPATH|DEVNAME|DRIVER|SUBSYSTEM|MODALIAS|OF_NAME|ID_PATH|dw9714|INT347A|VCM' || true
  else
    log_warn "udevadm is not available."
  fi

  echo "--- VCM software node ---"
  if [[ -L "$vcm_path/software_node" ]]; then
    local software_node_path
    software_node_path="$(readlink -f "$vcm_path/software_node")"

    if [[ -n "$software_node_path" ]] && [[ -e "$software_node_path" ]]; then
      echo "$software_node_path"
      find "$software_node_path" -maxdepth 3 \( -type f -o -type l \) 2>/dev/null || true
    else
      log_warn "Could not resolve DW9714 software_node path."
    fi
  else
    log_warn "No software_node link found for DW9714 VCM."
  fi

  echo "--- VCM video4linux children ---"
  local vcm_video_nodes
  vcm_video_nodes="$(find "$vcm_path" -maxdepth 5 \( -iname 'video4linux' -o -iname 'v4l-subdev*' \) 2>/dev/null || true)"

  if [[ -n "$vcm_video_nodes" ]]; then
    printf '%s\n' "$vcm_video_nodes"
  else
    log_warn "DW9714 VCM is bound, but no V4L2 subdev node was found."
    log_warn "Autofocus and LensPosition control are likely unavailable."
  fi
}

print_tuning_information() {
  log_info "libcamera simple IPA tuning files"

  local tuning_dir="/usr/share/libcamera/ipa/simple"

  if [[ ! -d "$tuning_dir" ]]; then
    log_warn "Tuning directory does not exist: $tuning_dir"
    return
  fi

  echo "--- $tuning_dir ---"
  ls -l "$tuning_dir" || true

  if [[ ! -f "$tuning_dir/ov8865.yaml" ]]; then
    log_warn "ov8865.yaml is missing. libcamera may fall back to uncalibrated.yaml."
  fi

  if [[ ! -f "$tuning_dir/ov5693.yaml" ]]; then
    log_warn "ov5693.yaml is missing. libcamera may fall back to uncalibrated.yaml."
  fi

  if [[ -f "$tuning_dir/uncalibrated.yaml" ]]; then
    log_info "uncalibrated.yaml exists."
  else
    log_warn "uncalibrated.yaml is missing."
  fi
}

print_test_commands() {
  cat <<'EOF'

============================================================
Manual test commands
============================================================

1. Check whether libcamera can see the cameras:

   cam --list

2. Check rear camera properties:

   cam -c '\_SB_.PC00.I2C5.CAMR' --list-properties

3. Check rear camera controls:

   cam -c '\_SB_.PC00.I2C5.CAMR' --list-controls

4. Capture frames from rear camera:

   cam -c '\_SB_.PC00.I2C5.CAMR' -C5 -Fframe-#.ppm

5. Try rear camera with GStreamer:

   gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PC00.I2C5.CAMR' \
     ! video/x-raw,width=640,height=480 \
     ! queue \
     ! videoconvert \
     ! autovideosink

6. Try rear camera with basic visual correction:

   gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PC00.I2C5.CAMR' \
     ! video/x-raw,width=640,height=480 \
     ! queue \
     ! videobalance brightness=0.05 contrast=1.25 saturation=1.15 \
     ! gamma gamma=0.9 \
     ! videoconvert \
     ! autovideosink

7. Get verbose libcamera logs:

   LIBCAMERA_LOG_LEVELS='*:DEBUG' cam --list

8. Check kernel logs:

   sudo dmesg | grep -Ei 'ipu6|isys|ov8865|ov5693|dw9714|camera|lens|vcm'

9. Check PipeWire objects:

   pw-cli list-objects | grep -Ei 'camera|libcamera|node.description|object.path|media.class'

============================================================
Application notes
============================================================

- Prefer native Firefox instead of Snap Firefox when testing camera access.
- For Firefox, check about:config if needed:

  media.webrtc.camera.allow-pipewire = true

- For Chromium / Chrome, try:

  chromium --enable-features=WebRtcPipeWireCamera

============================================================
Known Surface Go 4 limitations
============================================================

- Rear camera OV8865 can output video in the tested Ubuntu 26.04 setup.
- Front camera OV5693 may still have limited behavior.
- Sensor-specific tuning files may be missing:
  - ov8865.yaml
  - ov5693.yaml
- libcamera may fall back to uncalibrated.yaml.
- Only limited controls may be exposed, such as Contrast and Gamma.
- DW9714 VCM may be bound but may not expose a V4L2 subdev node.
- If DW9714 has no /dev/v4l-subdevX node, autofocus and LensPosition control are unavailable.

EOF
}

run_diagnostics() {
  print_system_information
  print_package_information
  check_local_libcamera_override
  warn_about_legacy_or_conflicting_packages
  print_pci_information
  print_v4l2_information
  print_kernel_camera_logs
  print_libcamera_information
  print_pipewire_information
  print_lens_and_sensor_topology
  print_subdev_information
  print_vcm_information
  print_tuning_information
  print_test_commands
}

main() {
  parse_arguments "$@"

  log_info "$SCRIPT_NAME"

  check_basic_commands
  check_ubuntu_version
  check_kernel_version

  remove_local_libcamera_config_if_requested
  check_local_libcamera_override

  if [[ "$RUN_DIAGNOSTICS_ONLY" == true ]]; then
    run_diagnostics
    exit 0
  fi

  install_system_camera_stack
  warn_about_legacy_or_conflicting_packages
  build_libcamera_from_source_if_requested
  restart_user_camera_services
  run_diagnostics

  log_info "Setup completed. Reboot is recommended before final camera testing."
}

main "$@"
