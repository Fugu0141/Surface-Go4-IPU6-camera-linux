# Surface Go 4 IPU6 camera failure: root-cause analysis, workaround, and end-to-end validation

> **Status:** Experimental, device-specific technical report  
> **Last validated:** 2026-07-26  
> **Device:** Microsoft Surface Go 4  
> **Distribution:** Ubuntu 26.04 LTS  
> **Kernel used for the final validation:** `7.0.0-28-generic`  
> **Related upstream work:** [linux-surface/linux-surface#2171](https://github.com/linux-surface/linux-surface/pull/2171)

This document describes why the built-in cameras on the Microsoft Surface Go 4 can be detected by Linux while still failing in real applications, and records an end-to-end validation that reached actual live video in GNOME Camera.

The important result is that there were **two independent problems in different layers**:

1. **Front-camera stream initialization in the kernel driver**  
   The OV5693 sensor could be detected and powered, but the first stream attempt could produce no usable frames and end with IPU6 stream timeout messages. The experimental `MIPI_CTRL00 = 0x2d` change from linux-surface PR #2171 made cold-boot first-access streaming reliable in this Surface Go 4 test.

2. **libcamera discovery by WirePlumber at user-session startup**  
   WirePlumber sometimes started while `/dev/media0` was not accessible to the user session. It then skipped the IPU6 media device and did not expose either physical camera as a PipeWire libcamera source. Restarting WirePlumber after device access was available caused both cameras to appear and made them usable in GNOME Camera.

These failures look similar from the desktop — “the camera does not work” — but require different fixes.

---

## 1. Scope and safety notice

This is a reproducibility report for one tested Surface Go 4 environment. It is not a claim that every Surface, every Ubuntu release, or every future kernel will behave identically.

The kernel workaround described here:

- installs an out-of-tree replacement for the in-tree `ov5693` module;
- must be built for the exact running kernel ABI;
- requires a trusted signature when Secure Boot is enabled;
- may need to be rebuilt after every kernel update;
- is based on an open linux-surface pull request and may change during upstream review;
- must not be applied blindly to unrelated OV5693 systems, especially IPU3 devices, without checking the latest upstream discussion.

Always keep a rollback path and review the current state of:

- [linux-surface/linux-surface#2171](https://github.com/linux-surface/linux-surface/pull/2171)
- [linux-surface/linux-surface#2154](https://github.com/linux-surface/linux-surface/issues/2154)

---

## 2. Tested hardware and software

### Hardware

| Component | Identified device |
|---|---|
| Computer | Microsoft Surface Go 4 |
| CPU | Intel N200 / Alder Lake-N |
| Imaging controller | Intel IPU6, PCI `0000:00:05.0` |
| Front sensor | OmniVision OV5693 |
| Front camera ID | `\_SB_.PC00.I2C3.CAMF` |
| Rear sensor | OmniVision OV8865 |
| Rear camera ID | `\_SB_.PC00.I2C5.CAMR` |
| Rear lens/VCM | `dw9714 4-000c` |
| Media controller | `/dev/media0` |

### Final validation environment

| Component | Version |
|---|---|
| Ubuntu | 26.04 LTS, Resolute |
| Kernel | `7.0.0-28-generic` |
| Ubuntu kernel source package | `linux-source-7.0.0 7.0.0-28.28` |
| libcamera | `0.7.0-1ubuntu2` |
| PipeWire | `1.6.2-1ubuntu1.1` |
| WirePlumber | `0.5.13-1ubuntu1` |
| `libspa-0.2-libcamera` | `1.6.2-1ubuntu1.1` |
| Secure Boot | Enabled |

The final test used Ubuntu-packaged libcamera. It did **not** use a `/usr/local` libcamera override.

---

## 3. Camera stack on this device

The useful application path is:

```text
OV5693 / OV8865 sensor
        |
        v
Intel IPU6 ISYS kernel driver
        |
        v
libcamera simple pipeline
        |
        v
Soft ISP / IPA processing
        |
        v
WirePlumber + PipeWire libcamera monitor
        |
        v
GNOME Camera / WebRTC application / other PipeWire client
```

The many `/dev/video0` through `/dev/video31` nodes exposed by IPU6 are internal capture nodes in the media graph. They are not equivalent to a normal USB webcam node. A desktop application opening one of these raw V4L2 nodes directly may fail with messages such as:

```text
VIDIOC_STREAMON: Link has been severed
Start error: Link has been severed
```

For normal application use, the physical cameras should appear through libcamera and PipeWire as nodes similar to:

```text
Built-in Front Camera
Built-in Back Camera
```

---

## 4. Why detection alone was misleading

Several levels of “detection” can succeed while the camera is still unusable:

1. ACPI describes the sensor.
2. The kernel binds the `ov5693` or `ov8865` driver.
3. libcamera lists the camera.
4. The privacy/access LED turns on.
5. A stream is configured.
6. Actual CSI-2 frames arrive.
7. The frames contain a valid image.
8. PipeWire exposes the camera to applications.
9. A desktop application displays continuous live video.

The original front-camera symptom reached approximately steps 1–5 but did not reliably reach step 6. The later WirePlumber failure reached step 7 through the `cam` tool but failed at step 8.

Therefore, `cam --list`, an illuminated LED, or a successful device probe is not sufficient proof that the camera works.

---

# Part A — Front OV5693 kernel streaming failure

## 5. Stock-driver symptom

With the Ubuntu in-tree module on kernel `7.0.0-28-generic`, the selected module was:

```text
filename: /lib/modules/7.0.0-28-generic/kernel/drivers/media/i2c/ov5693.ko.zst
srcversion: 4C0FB4623E6E01183B0300B
intree: Y
signer: Build time autogenerated kernel key
```

A cold-boot first capture attempt could receive no frames and terminate only after the timeout wrapper. Kernel messages included:

```text
intel_ipu6_isys.isys intel_ipu6.isys.40: stream stop time out
intel_ipu6_isys.isys intel_ipu6.isys.40: stream close time out
```

A later retry during the same boot could sometimes receive frames. This is an important nuance: on this test system the unmodified driver was not always a permanent zero-frame state; it was **non-deterministic across attempts**.

The practical failure remained serious because normal applications generally expect the first stream start to work. An application may not perform the same retry sequence as a manual tester.

## 6. Kernel-side root cause investigated by PR #2171

The in-tree `ov5693_enable_streaming()` function writes the software stream register at `0x0100`, but the tested stock source did not program `MIPI_CTRL00` at register `0x4800` before stream-on.

The experimental linux-surface change in PR #2171 programs:

```c
#define OV5693_MIPI_CTRL00_REG  CCI_REG8(0x4800)
#define OV5693_MIPI_CTRL00_IPU6 0x2d
```

and, before writing the stream-on value:

```c
if (enable)
        cci_write(ov5693->regmap, OV5693_MIPI_CTRL00_REG,
                  OV5693_MIPI_CTRL00_IPU6, &ret);
```

The PR reports that `0x2d` was identified from the Windows vendor-driver register table and enables the IPU6 receiver to obtain frames from this sensor configuration.

### Important upstream caveats

- The exact meaning of every bit in `0x2d` is not established from a publicly cited sensor datasheet in the PR.
- The current PR may be revised to use a different value, additional gating, or a different upstream integration strategy.
- An unconditional write may affect IPU3 systems that use the same sensor driver.
- The latest upstream patch should be preferred over permanently copying this experimental implementation.

This report demonstrates the tested behavior of the PR-style change on Surface Go 4; it does not settle the final upstream design.

---

## 7. Building a matching external module

The most important build rule is to use source and headers matching the exact installed kernel package.

For the final test:

```text
running kernel:       7.0.0-28-generic
header package:       7.0.0-28.28
source package:       7.0.0-28.28
```

### 7.1 Install the matching source and build tools

```bash
sudo apt install \
  "linux-headers-$(uname -r)" \
  linux-source-7.0.0 \
  build-essential \
  mokutil \
  openssl
```

Confirm package versions:

```bash
dpkg-query -W -f='${Package} ${Version}\n' \
  "linux-headers-$(uname -r)" \
  linux-source-7.0.0
```

Do not continue when the source package revision does not correspond to the installed kernel revision unless you understand and have verified the ABI differences.

### 7.2 Extract the Ubuntu source

```bash
BASE="$HOME/sg4-ov5693-test"
mkdir -p "$BASE/source" "$BASE/build"

tar -xf /usr/src/linux-source-7.0.0.tar.bz2 \
  -C "$BASE/source"

cp "$BASE/source/linux-source-7.0.0/drivers/media/i2c/ov5693.c" \
   "$BASE/build/ov5693.c"

printf 'obj-m += ov5693.o\n' > "$BASE/build/Makefile"
```

### 7.3 Apply the experimental change

Apply the current patch from PR #2171, rather than relying on an old copy of this document. At the time of this validation, the effective change was:

```diff
+#define OV5693_MIPI_CTRL00_REG            CCI_REG8(0x4800)
+#define OV5693_MIPI_CTRL00_IPU6           0x2d
+
 static int ov5693_enable_streaming(struct ov5693_device *ov5693, bool enable)
 {
         int ret = 0;
 
+        if (enable)
+                cci_write(ov5693->regmap, OV5693_MIPI_CTRL00_REG,
+                          OV5693_MIPI_CTRL00_IPU6, &ret);
+
         cci_write(ov5693->regmap, OV5693_SW_STREAM_REG,
                   enable ? OV5693_START_STREAMING : OV5693_STOP_STREAMING,
                   &ret);
```

Review the resulting source before building:

```bash
grep -nE -C 8 \
  'MIPI_CTRL00|0x4800|0x2d|ov5693_enable_streaming' \
  "$BASE/build/ov5693.c"
```

### 7.4 Build against the running kernel

```bash
make -C "/lib/modules/$(uname -r)/build" \
  M="$BASE/build" \
  clean

make -C "/lib/modules/$(uname -r)/build" \
  M="$BASE/build" \
  modules \
  -j"$(nproc)"
```

The following messages were not fatal in the tested external-module build:

```text
warning: the compiler differs from the one used to build the kernel
Skipping BTF generation ... due to unavailability of vmlinux
```

In the observed compiler warning, both compiler versions were actually GCC `15.2.0-16ubuntu1`; only the executable names differed.

Check the module ABI:

```bash
modinfo "$BASE/build/ov5693.ko" | \
  grep -E 'filename|srcversion|vermagic|signer|sig_hashalgo'
```

The `vermagic` must match the running kernel, for example:

```text
7.0.0-28-generic SMP preempt mod_unload modversions
```

### 7.5 Reproducibility check used in this test

Before applying the patch, the unmodified Ubuntu source was also compiled as an external module. Its `srcversion` matched the packaged module exactly:

```text
packaged stock module: 4C0FB4623E6E01183B0300B
rebuilt stock module:  4C0FB4623E6E01183B0300B
```

This gave confidence that the correct Ubuntu source revision and build interface were being used.

The patched source produced:

```text
patched module srcversion: FBF85FE21991EC5ACB1D70C
```

These values are evidence from this exact build. They are not universal identifiers for every future kernel revision.

---

## 8. Secure Boot and MOK signing

When Secure Boot is enabled, the locally built module must be signed by a key trusted by the machine.

### 8.1 Create and enroll a MOK key when needed

Skip this section when a suitable key is already enrolled.

```bash
MOK_DIR="$HOME/sg4-ov5693-mok"
mkdir -p "$MOK_DIR"
chmod 700 "$MOK_DIR"

openssl req \
  -new \
  -x509 \
  -newkey rsa:2048 \
  -keyout "$MOK_DIR/MOK.priv" \
  -outform DER \
  -out "$MOK_DIR/MOK.der" \
  -nodes \
  -days 36500 \
  -subj '/CN=Surface Go 4 ov5693 local test/'

chmod 600 "$MOK_DIR/MOK.priv"
sudo mokutil --import "$MOK_DIR/MOK.der"
```

Reboot and complete enrollment in the firmware MOK manager. Then verify:

```bash
mokutil --test-key "$MOK_DIR/MOK.der"
```

### 8.2 Sign the module

```bash
SIGN_FILE="/usr/src/linux-headers-$(uname -r)/scripts/sign-file"
MOK_PRIV="$HOME/sg4-ov5693-mok/MOK.priv"
MOK_DER="$HOME/sg4-ov5693-mok/MOK.der"

"$SIGN_FILE" sha256 \
  "$MOK_PRIV" \
  "$MOK_DER" \
  "$BASE/build/ov5693.ko"
```

Verify the signature:

```bash
modinfo "$BASE/build/ov5693.ko" | \
  grep -E 'filename|srcversion|vermagic|signer|sig_key|sig_hashalgo'
```

The final test module showed:

```text
signer: Surface Go 4 ov5693 local test
sig_hashalgo: sha256
```

Never publish the private key.

---

## 9. Install the patched module without deleting the packaged module

Place the experimental module in the kernel `updates` directory. The packaged compressed module remains available under `kernel/drivers/media/i2c/` for rollback.

```bash
KVER="$(uname -r)"
UPDATES_DIR="/lib/modules/$KVER/updates"

sudo mkdir -p "$UPDATES_DIR"
sudo install -m 0644 \
  "$BASE/build/ov5693.ko" \
  "$UPDATES_DIR/ov5693.ko"

sudo depmod -a "$KVER"
```

Confirm that module resolution now selects the experimental copy:

```bash
modinfo -n ov5693
```

Expected form:

```text
/lib/modules/7.0.0-28-generic/updates/ov5693.ko
```

Update the initramfs:

```bash
sudo update-initramfs -u -k "$KVER"
```

Confirm that it contains the `updates` module:

```bash
sudo lsinitramfs "/boot/initrd.img-$KVER" | \
  grep -E '(^|/)ov5693\.ko(\.zst|\.xz)?$'
```

Observed result:

```text
usr/lib/modules/7.0.0-28-generic/updates/ov5693.ko
```

For a real cold-start test, power the machine off rather than merely rebooting:

```bash
sudo poweroff
```

Wait until the device is fully off before starting it again.

---

## 10. Verify the module that is actually loaded

`modinfo` before reboot tells you which file would be selected next. It does not prove that the running kernel has replaced the already-loaded module.

After cold boot, verify both the selected file and the live module `srcversion`:

```bash
modinfo -n ov5693

modinfo ov5693 | \
  grep -E 'filename|srcversion|vermagic|signer|sig_hashalgo'

cat /sys/module/ov5693/srcversion
```

The final validation showed:

```text
filename: /lib/modules/7.0.0-28-generic/updates/ov5693.ko
srcversion: FBF85FE21991EC5ACB1D70C
signer: Surface Go 4 ov5693 local test
sig_hashalgo: sha256
```

and the live sysfs value was:

```text
FBF85FE21991EC5ACB1D70C
```

---

## 11. Cold-boot first-access validation

The first camera access after power-on is the important test. Do not open GNOME Camera or run another camera command first.

```bash
START_TIME=$(date --iso-8601=seconds)

timeout 60s cam \
  -c '\_SB_.PC00.I2C3.CAMF' \
  -C300 \
  > front-first-300.log 2>&1

EXIT_CODE=$?

echo "Exit code: $EXIT_CODE"
grep -c 'cam0-stream0 seq:' front-first-300.log

tail -n 20 front-first-300.log

sudo journalctl -k -b --since "$START_TIME" | \
  grep -Ei 'stream|timeout|csi2|fifo|discard|error' || true
```

### Observed patched result

```text
Frames: 300
Exit code: 0
last sequence: 000299
approximately 28.66 fps
matching kernel warnings during this test: none
```

This was a cold-boot, first-access result. It is stronger evidence than a successful retry after a failed initialization.

### Earlier patched test on kernel 7.0.0-15

An earlier test of the same `0x2d` concept captured frames at approximately 28.6 fps but reported occasional CSI-2 warnings:

```text
Transfer FIFO overflow
Inter-frame long packet discarded
Inter-frame short packet discarded
```

Those warnings did not appear in the final 300-frame test on `7.0.0-28-generic`. This does not prove that they can never recur.

---

## 12. Validate actual image content

Frame counters and `bytesused` values prove data movement, not necessarily a meaningful image. Save real images and inspect them.

```bash
mkdir -p front-frames

cam \
  -c '\_SB_.PC00.I2C3.CAMF' \
  -C10 \
  -s width=640,height=480 \
  -F"$PWD/front-frames/front-#.ppm"

file front-frames/*.ppm
```

Observed result:

```text
10/10 frames captured
640 x 480 Netpbm PPM files
approximately 57.35 fps in this selected mode
```

The files were opened and visually confirmed to contain a real front-camera image. No personal test image is included in this repository.

The 57.35 fps observation applies only to this selected 640×480 mode and test path. It should not be treated as a general performance guarantee.

---

# Part B — WirePlumber/libcamera discovery failure

## 13. Symptom after the kernel fix

After the patched OV5693 module was confirmed to produce valid images, GNOME Camera still sometimes reported no camera after login.

At that time:

- `cam` could enumerate and use the sensors;
- the kernel stream fix was loaded;
- actual PPM images had already been captured;
- GNOME Camera did not list the physical cameras;
- PipeWire contained many raw IPU6 V4L2 devices but no usable libcamera camera sources.

This proved that the remaining failure was no longer the OV5693 stream itself.

## 14. Observed WirePlumber startup failure

The user-session journal showed:

```text
libcamera v0.7.0
Failed to open media device at /dev/media0: Permission denied
Unable to populate media device /dev/media0 (Permission denied), skipping
Failed to add device for '.../media0', skipping
Could not open any dma-buf provider
```

The key event is the failure to open `/dev/media0`. Because libcamera could not populate the IPU6 media graph, WirePlumber did not create the physical libcamera camera devices.

GNOME Camera then attempted to interact with an IPU6 raw V4L2 node and produced errors such as:

```text
spa.v4l2: /dev/video0: VIDIOC_S_PARM: Inappropriate ioctl for device
spa.v4l2: '/dev/video0' VIDIOC_STREAMON: Link has been severed
pw.node: suspended -> error
```

These V4L2 messages were a consequence of the useful libcamera nodes being absent; they were not proof that the newly patched OV5693 stream had regressed.

## 15. Verified user-space workaround

After the login session was fully established, only WirePlumber was restarted:

```bash
systemctl --user restart wireplumber.service
```

The new WirePlumber process then logged:

```text
Adding camera '\_SB_.PC00.I2C5.CAMR' for pipeline handler simple
Adding camera '\_SB_.PC00.I2C3.CAMF' for pipeline handler simple
```

`wpctl status` showed:

```text
Video
 ├─ Devices:
 │      ov5693 [libcamera]
 │      ov8865 [libcamera]
 ├─ Sources:
 │      Built-in Front Camera
 │      Built-in Back Camera
```

After this restart, both front and rear cameras were recognized by GNOME Camera and both produced live video.

A broader refresh can be used when an application or desktop portal has retained stale state:

```bash
systemctl --user restart \
  pipewire.service \
  pipewire-pulse.service \
  wireplumber.service \
  xdg-desktop-portal.service \
  xdg-desktop-portal-gnome.service
```

In the final isolation test, restarting WirePlumber alone was sufficient.

## 16. What is known and what is still an inference

### Directly observed

- WirePlumber tried to enumerate libcamera at session startup.
- `/dev/media0` returned `Permission denied` at that moment.
- WirePlumber skipped the media device.
- No physical libcamera sources were exported to PipeWire.
- Restarting WirePlumber later enumerated both sensors.
- GNOME Camera then used both cameras successfully.

### Strong interpretation, not yet an upstream-proven root cause

The behavior is consistent with a startup ordering or permission-timing race between the user session, udev/logind device access, and WirePlumber's initial libcamera enumeration.

This report does not yet prove which component should be changed upstream. Possibilities include:

- the device ACL becoming available after WirePlumber's first probe;
- WirePlumber not retrying after a permission-related enumeration failure;
- a session-start ordering issue specific to this Ubuntu configuration;
- a combination of the above.

Do not automatically add users to broad device-access groups as the first fix. Session ACL behavior and device ownership should be recorded before changing the security model.

Useful diagnostics are:

```bash
id
stat -c '%A %a %U:%G %n' /dev/media0 /dev/video0
getfacl -p /dev/media0 /dev/video0
loginctl session-status
udevadm info --query=property --name=/dev/media0
journalctl --user -b -u wireplumber.service --no-pager
```

## 17. Why the repository setup script appeared to fix application detection

In the Ubuntu 26.04 test branch, the setup script installs/checks the packaged camera stack and restarts the relevant user services.

The necessary packages were already present in the final test, including:

```text
libcamera0.7
libcamera-ipa
libcamera-tools
libcamera-v4l2
gstreamer1.0-libcamera
libspa-0.2-libcamera
pipewire
wireplumber
```

The major behavioral change came after the service restart: WirePlumber enumerated libcamera after `/dev/media0` was accessible, and PipeWire gained the two physical camera sources.

Therefore the script's success was not evidence that reinstalling libcamera repaired the kernel sensor stream. It repaired the **user-space discovery state**, while the separate OV5693 module change repaired the **front-camera stream initialization**.

---

# Part C — End-to-end result

## 18. Final working path

The final validated front-camera path was:

```text
OV5693 front sensor
  -> patched ov5693 module, MIPI_CTRL00 = 0x2d
  -> Intel IPU6 ISYS
  -> Ubuntu libcamera 0.7.0 simple pipeline
  -> Soft ISP
  -> WirePlumber libcamera monitor
  -> PipeWire Built-in Front Camera source
  -> GNOME Camera live video
```

The rear-camera path also reached GNOME Camera live video after WirePlumber re-enumeration:

```text
OV8865 rear sensor
  -> Intel IPU6 ISYS
  -> libcamera simple pipeline
  -> Soft ISP
  -> WirePlumber / PipeWire
  -> GNOME Camera live video
```

### Validation matrix

| Test | Stock OV5693 module | Patched `0x2d` module |
|---|---:|---:|
| Sensor listed by libcamera | Yes | Yes |
| Privacy/access LED | Yes | Yes |
| Cold-boot first stream reliable | No in tested baseline | Yes in final test |
| 300-frame first-access test | Failed in baseline condition | 300/300, exit 0 |
| Valid PPM image | Not established in baseline | Yes |
| GNOME Camera physical node | Depends on WirePlumber discovery | Depends on WirePlumber discovery |
| GNOME Camera front live video after WirePlumber restart | Not useful without reliable stream | Yes |
| GNOME Camera rear live video after WirePlumber restart | Partially available | Yes, with limitations |

---

## 19. Remaining limitations

### 19.1 Rear autofocus / VCM

libcamera still reports:

```text
'dw9714 4-000c': Failed to open V4L2 device
'ov8865 4-0010': Lens initialisation failed, lens disabled
```

This is a separate rear-camera lens-control problem. The OV5693 `MIPI_CTRL00` change does not fix it.

The rear camera can produce video, but autofocus may not work and the image can remain visibly out of focus.

### 19.2 Missing sensor tuning

The tested stack reports missing sensor-specific Simple IPA configuration:

```text
Configuration file 'ov5693.yaml' not found
Configuration file 'ov8865.yaml' not found
falling back to .../uncalibrated.yaml
```

Consequences may include:

- inaccurate exposure;
- brightness oscillation or flicker;
- incorrect color response;
- weak low-light behavior;
- generally unfinished image quality.

The kernel stream fix proves transport and real-image output. It does not supply sensor calibration or tuning.

### 19.3 Soft ISP cost

The libcamera simple pipeline performs image processing in software on this configuration. CPU use can be significant, especially at high resolution.

### 19.4 Session-start camera discovery

Manual WirePlumber restart is a verified workaround. A robust automatic retry or ordering fix still needs additional testing and preferably an upstream solution.

### 19.5 Suspend and resume

Suspend/resume reliability was not established by the final end-to-end test and should be tested separately.

### 19.6 Other applications

GNOME Camera was validated. Applications that use PipeWire/libcamera should be tested individually. Programs that require a conventional `/dev/video` webcam node may need a separate bridge such as `v4l2loopback`; that is outside the main validation in this document.

---

## 20. Troubleshooting decision tree

### A. `cam --list` does not show either camera

Investigate the kernel/media graph first:

```bash
sudo dmesg | grep -Ei 'ipu6|ov5693|ov8865|camera'
v4l2-ctl --list-devices
media-ctl -p -d /dev/media0
```

This is not primarily a GNOME Camera problem.

### B. `cam --list` shows OV5693, the LED turns on, but capture receives zero frames

Check for:

```text
stream stop time out
stream close time out
```

Verify which `ov5693` module is actually loaded:

```bash
modinfo -n ov5693
cat /sys/module/ov5693/srcversion
```

Review PR #2171 and test the current upstream candidate on a matching kernel.

### C. `cam` captures a real image, but GNOME Camera reports no camera

Inspect WirePlumber:

```bash
journalctl --user -b -u wireplumber.service --no-pager
wpctl status
```

Look for:

```text
Failed to open media device at /dev/media0: Permission denied
```

Then test the verified workaround:

```bash
systemctl --user restart wireplumber.service
```

Confirm that PipeWire now shows:

```text
Built-in Front Camera
Built-in Back Camera
```

### D. GNOME Camera opens an `ipu6 (V4L2)` source and fails with a broken link

The application is likely seeing a raw internal V4L2 capture node instead of the libcamera physical camera source. Restore WirePlumber/libcamera discovery rather than treating `/dev/video0` as a normal webcam.

### E. Rear video works but focus does not

Check for `dw9714` and “lens disabled” messages. This is the separate VCM/AF problem.

### F. Video works but brightness, color, or flicker is poor

Check whether libcamera is falling back to `uncalibrated.yaml`. This is a tuning/IPA issue, not proof that CSI-2 streaming is broken.

---

## 21. Rollback

To return to the Ubuntu packaged module for the current kernel:

```bash
KVER="$(uname -r)"

sudo rm -f "/lib/modules/$KVER/updates/ov5693.ko"
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
sudo poweroff
```

After powering on, verify:

```bash
modinfo -n ov5693
cat /sys/module/ov5693/srcversion
```

The path should return to the packaged module under:

```text
/lib/modules/<kernel>/kernel/drivers/media/i2c/ov5693.ko.zst
```

Never delete the packaged in-tree module as part of the experimental installation.

---

## 22. Information useful for upstream reports

A useful report should separate kernel streaming from desktop discovery and include:

```bash
uname -a
mokutil --sb-state
modinfo ov5693
cat /sys/module/ov5693/srcversion
cam --list
wpctl status
stat -c '%A %a %U:%G %n' /dev/media0
getfacl -p /dev/media0
journalctl -k -b --no-pager
journalctl --user -b -u wireplumber.service --no-pager
```

For stream tests, record:

- whether the machine was cold-booted;
- whether this was the first camera access;
- exact `cam` command;
- requested resolution and pixel format;
- frame count and last sequence number;
- exit status;
- kernel warnings during the exact test window;
- whether the output image was visually valid;
- whether a real desktop application displayed live video.

Avoid reporting “working” based only on detection, an LED, or frame counters.

---

## 23. Conclusions

The Surface Go 4 camera failure tested here was not one single bug.

### Front-camera kernel failure

The OV5693 was detected, but stream startup was unreliable with the stock driver. The experimental PR #2171-style `MIPI_CTRL00 = 0x2d` write made the tested Surface Go 4 produce:

- 300/300 frames on the first camera access after cold boot;
- a clean exit status;
- valid 640×480 PPM images;
- a visually confirmed real front-camera image.

### Desktop camera discovery failure

WirePlumber could start before it had permission to open `/dev/media0`, skip libcamera enumeration, and leave GNOME Camera with no usable physical camera source. Restarting WirePlumber after the session was established exposed both cameras and enabled live front and rear video in GNOME Camera.

### Still unresolved

- final upstream form of the OV5693 MIPI control change;
- automatic recovery from the WirePlumber startup permission race;
- rear `dw9714` autofocus/lens initialization;
- sensor-specific IPA tuning and stable image quality;
- suspend/resume and broader application compatibility.

The key engineering lesson is to validate each layer independently:

```text
kernel detection != frame transport
frame transport != valid image
valid image != PipeWire discovery
PipeWire discovery != application usability
```

Only the full end-to-end test proved that the Surface Go 4 front camera was actually usable.

---

## References

- [linux-surface PR #2171 — cameras: ov5693: make the IPU6 Surface front cameras stream](https://github.com/linux-surface/linux-surface/pull/2171)
- [linux-surface issue #2154 — Surface Go 4 IPU6 camera status](https://github.com/linux-surface/linux-surface/issues/2154)
- [linux-surface IPU6 camera discussion #1354](https://github.com/linux-surface/linux-surface/discussions/1354)
- [libcamera project](https://libcamera.org/)
- [This repository's Ubuntu 26.04 test branch](https://github.com/Fugu0141/Surface-Go4-IPU6-camera-linux/tree/test/26.04LTS)
