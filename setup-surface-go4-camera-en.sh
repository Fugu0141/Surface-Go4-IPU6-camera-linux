#!/usr/bin/env bash

# Recommended entry point for Surface Go 4 camera setup.
# It runs the existing camera-stack setup and then installs the
# per-user WirePlumber recovery service used to fix login-time discovery.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CAMERA_SETUP="${SCRIPT_DIR}/ipu6-camera-setup-en.sh"
readonly SESSION_RECOVERY="${SCRIPT_DIR}/ipu6-camera-session-recovery-en.sh"

if (( EUID == 0 )); then
  printf '[ERROR] Do not run this script with sudo. Run it as your desktop user.\n' >&2
  exit 1
fi

if [[ ! -x "$CAMERA_SETUP" ]]; then
  printf '[ERROR] Missing executable: %s\n' "$CAMERA_SETUP" >&2
  printf 'Run: chmod +x ipu6-camera-setup-en.sh ipu6-camera-session-recovery-en.sh setup-surface-go4-camera-en.sh\n' >&2
  exit 1
fi

if [[ ! -x "$SESSION_RECOVERY" ]]; then
  printf '[ERROR] Missing executable: %s\n' "$SESSION_RECOVERY" >&2
  printf 'Run: chmod +x ipu6-camera-setup-en.sh ipu6-camera-session-recovery-en.sh setup-surface-go4-camera-en.sh\n' >&2
  exit 1
fi

"$CAMERA_SETUP" "$@"
"$SESSION_RECOVERY" --install

cat <<'EOF'

============================================================
Surface Go 4 camera setup finished
============================================================
The user service below is now enabled:
  surface-go4-camera-session-recovery.service

It runs once after login, waits until /dev/media0 is accessible,
and restarts WirePlumber only when PipeWire has not already exported
a libcamera camera.

Check it with:
  ./ipu6-camera-session-recovery-en.sh --status

Remove it with:
  ./ipu6-camera-session-recovery-en.sh --remove

Important: this automates the WirePlumber discovery workaround. It does
not yet build/sign/install the experimental OV5693 kernel module.
============================================================
EOF
