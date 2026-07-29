# Automatic WirePlumber camera recovery after login

## Problem

On the tested Surface Go 4 Ubuntu 26.04 environment, WirePlumber can start before the logged-in user has access to `/dev/media0`.

The initial libcamera enumeration then fails with messages such as:

```text
Failed to open media device at /dev/media0: Permission denied
Unable to populate media device /dev/media0 (Permission denied), skipping
```

At that point `cam --list` may still see the sensors, while GNOME Camera and other PipeWire clients do not receive the physical libcamera camera sources.

Restarting WirePlumber after the session is fully established is a verified workaround:

```bash
systemctl --user restart wireplumber.service
```

## Automatic workaround

The repository now provides:

```text
ipu6-camera-session-recovery-en.sh
```

It installs a per-user systemd oneshot service named:

```text
surface-go4-camera-session-recovery.service
```

The service runs after login and:

1. checks whether PipeWire already exposes a libcamera camera;
2. waits up to 60 seconds for `/dev/media0` to exist and become readable and writable by the current user;
3. restarts only `wireplumber.service` when camera recovery is still required;
4. checks whether a front or rear libcamera camera appears;
5. records the result in the user journal.

This avoids relying on a fixed `sleep 5`, which may be too short or unnecessarily long depending on the login sequence.

The helper intentionally exits successfully after logging a timeout or failed verification. Camera recovery is useful but should not make the whole graphical user session enter a failed systemd state.

## Recommended setup

Run the new wrapper from a normal graphical user session. Do not run it with `sudo`:

```bash
chmod +x \
  ipu6-camera-setup-en.sh \
  ipu6-camera-session-recovery-en.sh \
  setup-surface-go4-camera-en.sh

./setup-surface-go4-camera-en.sh -y
```

The wrapper performs the existing packaged camera-stack setup and then installs the automatic session recovery service.

## Install only the recovery service

When the camera stack is already installed:

```bash
chmod +x ipu6-camera-session-recovery-en.sh
./ipu6-camera-session-recovery-en.sh --install
```

## Check status and logs

```bash
./ipu6-camera-session-recovery-en.sh --status
```

Equivalent manual commands are:

```bash
systemctl --user status \
  surface-go4-camera-session-recovery.service \
  --no-pager

journalctl --user \
  -u surface-go4-camera-session-recovery.service \
  -b --no-pager
```

After a successful recovery, `wpctl status` should contain physical libcamera devices or sources similar to:

```text
ov5693 [libcamera]
ov8865 [libcamera]
Built-in Front Camera
Built-in Back Camera
```

## Remove the workaround

```bash
./ipu6-camera-session-recovery-en.sh --remove
```

This disables the user service and removes both the unit file and its helper script.

## Installed files

```text
~/.config/systemd/user/surface-go4-camera-session-recovery.service
~/.local/libexec/surface-go4-camera/wireplumber-session-recovery
```

No system-wide udev rule, broad device group membership, or root service is installed.

## Environment overrides for testing

The helper supports these optional environment variables:

```text
SURFACE_GO4_MEDIA_DEVICE
SURFACE_GO4_MEDIA_WAIT_SECONDS
SURFACE_GO4_CAMERA_VERIFY_SECONDS
```

They are mainly intended for development and controlled testing. The defaults are:

```text
/dev/media0
60 seconds waiting for device access
15 seconds verifying PipeWire camera export
```

## Scope and limitations

This service addresses only the login-time WirePlumber/libcamera discovery race.

It does not solve or automate:

- building the experimental OV5693 `MIPI_CTRL00 = 0x2d` module;
- Secure Boot signing and interactive MOK enrollment;
- rebuilding the external module after a kernel ABI update;
- rear DW9714 autofocus/lens initialization;
- missing OV5693/OV8865 IPA tuning files;
- suspend/resume behavior.

The automatic workaround should eventually be removed if WirePlumber, libcamera, udev/logind, or the distribution fixes the underlying startup race. Because the helper first checks whether a libcamera camera is already exported, it should become a no-op in the normal successful case.
