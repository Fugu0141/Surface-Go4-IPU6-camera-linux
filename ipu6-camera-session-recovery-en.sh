#!/usr/bin/env bash

# Install, remove, or inspect the per-user WirePlumber recovery workaround
# for the Surface Go 4 IPU6 camera startup race.

set -Eeuo pipefail

readonly UNIT_NAME="surface-go4-camera-session-recovery.service"
readonly UNIT_DIR="${HOME}/.config/systemd/user"
readonly UNIT_PATH="${UNIT_DIR}/${UNIT_NAME}"
readonly HELPER_DIR="${HOME}/.local/libexec/surface-go4-camera"
readonly HELPER_PATH="${HELPER_DIR}/wireplumber-session-recovery"

ACTION="install"

log_info() {
  printf '\n[INFO] %s\n' "$1"
}

log_warn() {
  printf '\n[WARN] %s\n' "$1" >&2
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./ipu6-camera-session-recovery-en.sh [--install|--remove|--status]

Actions:
  --install  Install and enable the user service (default).
  --remove   Disable and remove the user service.
  --status   Show service status and recent logs without changing anything.
EOF_USAGE
}

parse_arguments() {
  if [[ $# -gt 1 ]]; then
    usage
    exit 1
  fi

  case "${1:---install}" in
    --install) ACTION="install" ;;
    --remove)  ACTION="remove" ;;
    --status)  ACTION="status" ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf '[ERROR] Unknown option: %s\n' "$1" >&2
      usage
      exit 1
      ;;
  esac
}

require_user_session() {
  if (( EUID == 0 )); then
    printf '[ERROR] Do not run this script with sudo. Run it as the desktop user.\n' >&2
    exit 1
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    printf '[ERROR] systemctl is required.\n' >&2
    exit 1
  fi

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    printf '[ERROR] No usable systemd user session was found. Run this after logging in graphically.\n' >&2
    exit 1
  fi
}

write_helper() {
  mkdir -p "$HELPER_DIR"

  cat > "$HELPER_PATH" <<'EOF_HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly MEDIA_DEVICE="${SURFACE_GO4_MEDIA_DEVICE:-/dev/media0}"
readonly WAIT_SECONDS="${SURFACE_GO4_MEDIA_WAIT_SECONDS:-60}"
readonly VERIFY_SECONDS="${SURFACE_GO4_CAMERA_VERIFY_SECONDS:-15}"

log_message() {
  printf '[surface-go4-camera] %s\n' "$1"
  if command -v systemd-cat >/dev/null 2>&1; then
    printf '%s\n' "$1" | systemd-cat -t surface-go4-camera-recovery -p info || true
  fi
}

camera_is_exported() {
  command -v wpctl >/dev/null 2>&1 || return 1
  wpctl status 2>/dev/null | \
    grep -Eiq 'Built-in (Front|Back) Camera|ov5693.*libcamera|ov8865.*libcamera'
}

media_device_is_accessible() {
  [[ -c "$MEDIA_DEVICE" && -r "$MEDIA_DEVICE" && -w "$MEDIA_DEVICE" ]]
}

if camera_is_exported; then
  log_message "PipeWire already exposes a libcamera camera; no restart is needed."
  exit 0
fi

for ((elapsed = 0; elapsed < WAIT_SECONDS; elapsed++)); do
  if media_device_is_accessible; then
    log_message "$MEDIA_DEVICE is accessible; restarting WirePlumber for libcamera re-enumeration."

    if ! systemctl --user restart wireplumber.service; then
      log_message "WirePlumber restart failed. Check the user journal."
      exit 0
    fi

    for ((verify = 0; verify < VERIFY_SECONDS; verify++)); do
      if camera_is_exported; then
        log_message "Camera recovery succeeded; PipeWire exposes a libcamera camera."
        exit 0
      fi
      sleep 1
    done

    log_message "WirePlumber restarted, but a camera node was not confirmed automatically."
    exit 0
  fi

  sleep 1
done

log_message "Timed out waiting for read/write access to $MEDIA_DEVICE."
exit 0
EOF_HELPER

  chmod 0755 "$HELPER_PATH"
}

write_unit() {
  mkdir -p "$UNIT_DIR"

  cat > "$UNIT_PATH" <<'EOF_UNIT'
[Unit]
Description=Recover Surface Go 4 IPU6 cameras after user login
Documentation=https://github.com/Fugu0141/Surface-Go4-IPU6-camera-linux
Wants=wireplumber.service
After=wireplumber.service

[Service]
Type=oneshot
ExecStart=%h/.local/libexec/surface-go4-camera/wireplumber-session-recovery
TimeoutStartSec=90

[Install]
WantedBy=default.target
EOF_UNIT
}

install_recovery() {
  log_info "Installing the automatic WirePlumber camera recovery service."
  write_helper
  write_unit

  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME" >/dev/null
  systemctl --user restart "$UNIT_NAME" || \
    log_warn "The service could not run immediately, but it is enabled for the next login."

  log_info "Installed and enabled $UNIT_NAME."
  show_status
}

remove_recovery() {
  log_info "Removing the automatic WirePlumber camera recovery service."

  systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH" "$HELPER_PATH"
  rmdir "$HELPER_DIR" 2>/dev/null || true
  systemctl --user daemon-reload
  systemctl --user reset-failed "$UNIT_NAME" >/dev/null 2>&1 || true

  log_info "Removed $UNIT_NAME."
}

show_status() {
  log_info "Automatic camera recovery status"

  if [[ ! -f "$UNIT_PATH" ]]; then
    log_warn "$UNIT_NAME is not installed."
    return
  fi

  systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true
  systemctl --user status "$UNIT_NAME" --no-pager 2>/dev/null || true

  printf '\n--- recent recovery journal ---\n'
  journalctl --user -u "$UNIT_NAME" -b -n 40 --no-pager 2>/dev/null || true
}

main() {
  parse_arguments "$@"
  require_user_session

  case "$ACTION" in
    install) install_recovery ;;
    remove)  remove_recovery ;;
    status)  show_status ;;
  esac
}

main "$@"
