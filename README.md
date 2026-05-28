# Surface Go 4 IPU6 Camera on Linux

Experimental camera detection and partial streaming setup for the Microsoft Surface Go 4 on Linux.

This repository documents my current Surface Go 4 IPU6 camera test environment and provides experimental setup scripts for testing libcamera / PipeWire integration.

This is **not** a complete camera support solution.

Current status in my environment:

- Rear camera OV8865: detected and partially streaming
- Front camera OV5693: detected, LED turns on, but no usable video output
- PipeWire integration: partially working
- Image quality and stability: still limited

![Camera working on Ubuntu 25.10](docs/Screenshot%20From%202026-04-04%2003-35-26.png)

---

## Important warning

This repository is experimental.

The scripts are provided as-is under the MIT License, without any warranty.

They may fail depending on:

- kernel version
- Ubuntu version
- libcamera version
- PipeWire / WirePlumber configuration
- firmware state
- future package changes
- device-specific ACPI / software-node behavior

Please review the scripts before running them.

Do not expect this repository to make the Surface Go 4 cameras fully work in every environment.

---

## Tested environment

Current test environments:

- Device: Microsoft Surface Go 4
- CPU: Intel N200 / Alder Lake-N
- IPU: Intel IPU6
- Rear camera sensor: OmniVision OV8865
- Front camera sensor: OmniVision OV5693
- VCM / lens driver: dw9714
- Distribution: Ubuntu 25.10 / Ubuntu 26.04 LTS test environment
- Camera stack: libcamera simple pipeline + PipeWire

The Ubuntu 26.04 LTS branch is currently a test version.

---

## Hardware

| Item | Details |
| --- | --- |
| Device | Microsoft Surface Go 4 |
| CPU | Intel N200 / Alder Lake-N |
| IPU | Intel IPU6 |
| Rear camera sensor | OmniVision OV8865 |
| Front camera sensor | OmniVision OV5693 |
| VCM / lens driver | dw9714 |

---

## Current status

| Feature | Status | Notes |
| --- | --- | --- |
| IPU6 hardware detection | Partial / detected in my environment | Depends on kernel and firmware state |
| Rear camera OV8865 | Partial | Detected and can partially stream through libcamera simple pipeline |
| Front camera OV5693 | Not working properly | LED turns on, but no usable video stream is produced |
| PipeWire integration | Partial | Camera nodes can appear through libcamera / PipeWire |
| GNOME Camera / Cheese | Unreliable | May detect a camera, but output is not reliable |
| VLC | Unreliable | Not a reliable direct test application for this setup |
| Firefox native `.deb` | Partial / works in my environment | Uses PipeWire camera support |
| Firefox Snap | Not recommended | Snap sandboxing may block or limit camera access |
| Image quality | Limited | Missing proper sensor tuning files |
| Suspend / resume | Unknown / unstable | IPU6 reinitialization may fail after suspend on some systems |

---

## How the stack currently looks

The tested camera path is roughly:

```text
Sensor (OV8865 / OV5693)
  -> Intel IPU6 ISYS kernel driver
      -> libcamera simple pipeline
          -> Soft ISP
              -> PipeWire / WirePlumber
                  -> Applications
```

Important notes:

- The current setup relies on libcamera's simple pipeline.
- Image processing is done through Soft ISP.
- Proper sensor tuning files for OV8865 / OV5693 are not available in this repository.
- libcamera may fall back to uncalibrated settings.
- CPU usage can be high because image processing is done in software.
- This repository does not provide a complete IPU6 hardware ISP solution.

---

## Known limitations

- The front camera OV5693 is not usable yet.
- The front camera LED turns on, but no usable video stream is produced.
- The rear camera OV8865 is only partially working in my environment.
- Image quality is limited because proper calibration / tuning files are missing.
- Exposure can flicker under strong light.
- CPU usage can be high due to Soft ISP.
- GNOME Camera, Cheese, and VLC may not be reliable for testing.
- Suspend / resume may break camera initialization.
- Future Ubuntu, kernel, libcamera, or PipeWire updates may break the current behavior.

---

## Requirements

- Microsoft Surface Go 4
- Ubuntu 25.10 or Ubuntu 26.04 LTS test environment
- A kernel with Intel IPU6 ISYS support
- Internet connection
- Build tools and development packages
- Enough disk space to build libcamera

This script is intended for Surface Go 4 testing only.

It is not intended for Surface Go 1 / 2 / 3, because those devices use IPU3 instead of IPU6.

---

## Setup

Clone this repository and switch to the Ubuntu 26.04 LTS test branch:

```bash
git clone https://github.com/Fugu0141/Surface-Go4-IPU6-camera-linux.git
cd Surface-Go4-IPU6-camera-linux
git checkout test/26.04LTS
```

Run the experimental setup script:

```bash
chmod +x ipu6-camera-setup-en.sh
./ipu6-camera-setup-en.sh
```

The script is intended to:

1. Install required build dependencies.
2. Clone libcamera from the official repository.
3. Build libcamera with IPU6-compatible options.
4. Install the custom libcamera build under `/usr/local`.
5. Configure library path priority so PipeWire / WirePlumber can use the custom libcamera.
6. Restart WirePlumber / PipeWire components where needed.

---

## Testing

Check camera detection:

```bash
cam --list
v4l2-ctl --list-devices
pw-cli ls Node | grep -Ei "camera|libcamera|ov5693|ov8865"
```

Test the rear camera with GStreamer:

```bash
LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \
GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 \
gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PC00.I2C5.CAMR' \
! video/x-raw,width=640,height=480 ! videoconvert ! autovideosink
```

Capture a still image from the rear camera:

```bash
cd ~
~/libcamera/build/src/apps/cam/cam -c '\_SB_.PC00.I2C5.CAMR' -C -Fframe.ppm
```

The rear camera path used in my environment is:

```text
\_SB_.PC00.I2C5.CAMR
```

The front camera path detected in my environment is:

```text
\_SB_.PC00.I2C3.CAMF
```

At the moment, the front camera is not expected to produce usable video output.

---

## Diagnostic commands

These commands are useful when reporting results:

```bash
uname -r
cat /sys/devices/virtual/dmi/id/product_name
lspci -nn | grep -Ei "ipu|image|camera"
dmesg | grep -Ei "ipu|ov5693|ov8865|dw9714|int3472|v4l2|camera"
lsmod | grep -Ei "ipu|ov5693|ov8865|dw9714|v4l2"
v4l2-ctl --list-devices
cam --list
pw-cli ls Node | grep -Ei "camera|libcamera|ov5693|ov8865"
systemctl --user status pipewire wireplumber
```

---

## Related linux-surface issue

I opened a linux-surface issue for the Surface Go 4 IPU6 camera status:

https://github.com/linux-surface/linux-surface/issues/2154

---

## Notes for contributors / testers

If you test this repository, please include:

- Surface model
- distribution version
- kernel version
- libcamera version
- PipeWire version
- WirePlumber version
- `cam --list` output
- `v4l2-ctl --list-devices` output
- relevant `dmesg` output

Please mention whether you tested:

- rear camera OV8865
- front camera OV5693
- GNOME Camera / Cheese
- Firefox native `.deb`
- Firefox Snap
- VLC
- PipeWire camera nodes

---

## License

This repository is released under the MIT License.

The scripts are provided as-is, without any warranty.

See the `LICENSE` file for details.

---

## References

- libcamera official repository: https://git.libcamera.org/libcamera/libcamera.git
- linux-surface IPU6 camera discussion: https://github.com/linux-surface/linux-surface/discussions/1354
- linux-surface Surface Go 4 issue: https://github.com/linux-surface/linux-surface/issues/2154
- Fedora IPU6 camera support notes: https://fedoraproject.org/wiki/Changes/IPU6_Camera_support
