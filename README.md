# Intel IPU6 Camera on Linux (Surface Go 4)

Getting the built-in IPU6 MIPI camera working on Linux using mainline kernel drivers and libcamera, without any proprietary or out-of-tree components.


![Camera working on Ubuntu 25.10](docs/Screenshot%20From%202026-04-04%2003-35-26.png)


Tested on **Microsoft Surface Go 4** with **Ubuntu 25.10 (Questing)**.

---

## Hardware

| Item | Details |
|---|---|
| Device | Microsoft Surface Go 4 |
| CPU | Intel N200 (Alder Lake-N) |
| IPU | Intel IPU6 (`PCI 0000:00:05.0`) |
| Rear camera sensor | OmniVision OV8865 |
| Front camera sensor | OmniVision OV5693 |

---

## Working status

| Feature | Status | Notes |
|---|---|---|
| IPU6 hardware detection | ✅ Working | Kernel 6.10+ required |
| Rear camera (OV8865) | ✅ Working | Via libcamera simple pipeline |
| Front camera (OV5693) | ⚠️ Partial | LED lights up, no video output |
| PipeWire integration | ✅ Working | Both cameras appear as PipeWire nodes |
| Cheese / GNOME Camera | ⚠️ Partial | Detected via PipeWire, image quality issues |
| Firefox (native) | ✅ Working | Via PipeWire camera support |
| Firefox (Snap) | ❌ Not working | Snap sandbox blocks PipeWire camera access |

---

## How it works

The IPU6 camera stack on mainline Linux looks like this:

```
Sensor (OV8865/OV5693)
  └─> IPU6 ISYS driver (in-tree since kernel 6.10)
        └─> libcamera Simple pipeline + Soft ISP (CPU-based debayering)
              └─> PipeWire (libspa-libcamera plugin)
                    └─> Applications (Firefox, Cheese, etc.)
```

Key points:
- The **IPU6 ISYS driver** has been in the mainline kernel since 6.10. No DKMS or out-of-tree drivers needed.
- The Ubuntu 25.10 system package `libcamera 0.5.0` does **not** include IPU6 IPA support. Building from source (v0.7.0) is required.
- The `simple` pipeline handler in libcamera enables IPU6 support via commit `06e0d850`.
- Since there is no mainline driver for the IPU6 hardware ISP (PSYS), image processing is done entirely in software (**Soft ISP**), which is CPU-intensive.
- **ldconfig path ordering** is the critical step that makes WirePlumber pick up the custom-built libcamera instead of the system version.

---

## Known limitations

- **Front camera (OV5693)**: The access LED turns on but no video is produced. This behavior was also observed on Fedora 43. Root cause unknown.
- **Image quality**: Images appear blurry because no sensor calibration files (`ov8865.yaml`, `ov5693.yaml`) are available for the Simple IPA module. It falls back to `uncalibrated.yaml`.
- **High CPU usage**: The Soft ISP processes raw Bayer data entirely on CPU. At 640×480, CPU usage is ~50%. At full resolution (3256×2448), it exceeds 100% on the Intel N200.
- **No GPU acceleration**: libcamera 0.7.0 has experimental GPU-accelerated Soft ISP support, but it was not available in this build configuration.
- **Firefox Snap**: The Snap sandbox prevents access to PipeWire camera nodes. Use the native `.deb` version of Firefox.
- **Suspend/resume**: IPU6 firmware re-authentication may fail after waking from suspend on some kernel versions.
- **Exposure flickering**: When exposed to strong light, the image starts flickering rapidly and does not recover. The auto-exposure algorithm in the Soft ISP appears to oscillate when overloaded, causing extreme brightness fluctuations that persist until the camera is restarted.

---

## Requirements

- Ubuntu 25.10 (Questing) or equivalent with kernel 6.10+
- Internet connection for package installation and git clone
- ~500MB disk space for build

---

## Setup

```bash
git clone https://github.com/Fugu0141/Surface-Go4-IPU6-camera-linux.git
cd Surface-Go4-IPU6-camera-linux
chmod +x ipu6-camera-setup-en.sh
./ipu6-camera-setup-en.sh
```

The script will:
1. Install build dependencies
2. Clone libcamera from the official repository
3. Build with IPU6-compatible options (`-Dipas=ipu3,simple`)
4. Install to `/usr/local`
5. Configure ldconfig to prioritize the custom build
6. Restart WirePlumber to pick up the new libcamera

---

## Testing

After setup, test with GStreamer:

```bash
LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \
GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 \
gst-launch-1.0 libcamerasrc camera-name='\\_SB_.PC00.I2C5.CAMR' \
! video/x-raw,width=640,height=480 ! videoconvert ! autovideosink
```

Capture a still image:

```bash
cd ~
~/libcamera/build/src/apps/cam/cam -c '\_SB_.PC00.I2C5.CAMR' -C -Fframe.ppm
```

---

## References

- [libcamera official repository](https://git.libcamera.org/libcamera/libcamera.git)
- [linux-surface IPU6 camera discussion](https://github.com/linux-surface/linux-surface/discussions/1354)
- [Fedora Changes: IPU6 Camera support](https://fedoraproject.org/wiki/Changes/IPU6_Camera_support)
- [Intel IPU6 Webcam on Linux (javier tia's blog)](https://jetm.github.io/blog/posts/ipu6-webcam-libcamera-on-linux/)
