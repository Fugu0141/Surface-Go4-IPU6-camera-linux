# Surface Go 4 OV5693 2x2-binning / Alder Lake-N validation result

Status: **PASS with observations**  
Date: 2026-09-24  
Device: Microsoft Surface Go 4  
Kernel: `7.0.0-30-generic`  
IPU6 PCI ID: `8086:462e` (`PCI_DEVICE_ID_INTEL_IPU6EP_ADLN`)  
Front camera: `INT33BE` / CAMF / OV5693  
libcamera: `0.7.0`

No captured image or raw-frame payload is embedded or linked in this report.

## Patch stack

The tested local stack contained:

- Fernando Rimoli's v5 OV5693 / IPU6 clock-lane series;
- the Alder Lake-N (`8086:462e`) OV5693 bridge match;
- the follow-up fix keeping the `clock-noncontinuous` property name outside unloadable module rodata;
- D. Manresa's `ov5693-binned-no-mipictrl.patch`;
- binning patch header commit: `548281df0983aa0b4e15c923e97d122419787078`.

Build-time semantic checks confirmed that the tested source used the conditional MIPI bit-5 logic and did not contain the earlier unconditional `MIPI_CTRL00 = 0x2d` write.

## Media topology and formats

The OV5693 path used for direct raw capture was:

```text
OV5693                    /dev/v4l-subdev4
Intel IPU6 CSI2 1         /dev/v4l-subdev1
Intel IPU6 ISYS Capture 8 /dev/video8
```

The sensor and CSI-2 media-bus format exposed by this kernel was:

```text
MEDIA_BUS_FMT_SBGGR10_1X10 = 0x3007
```

The ISYS capture format was:

```text
BG10 = 10-bit Bayer BGGR, unpacked into 16-bit samples
```

Both full-resolution and binned tests read back the requested format at the sensor, CSI-2 sink/source, and capture node before streaming.

## 300-frame streaming

### Full resolution — 2592x1944

First run:

```text
requested_frames=300
captured_frames=300
exit_code=0
fps=28.64
Frame sync error=0
Transfer FIFO overflow=1
```

The startup log contained:

```text
Transfer FIFO overflow
Inter-frame long packet discarded
```

A second independent 2592x1944 / 300-frame run also completed all 300 frames at 28.64 fps:

```text
captured_frames=300
exit_code=0
Frame sync error=0
Transfer FIFO overflow=1
```

Its startup log contained one FIFO overflow plus inter-frame packet-discard messages.

### 2x2 binned — 1296x972

```text
requested_frames=300
captured_frames=300
exit_code=0
fps=28.64
Frame sync error=0
Transfer FIFO overflow=0
```

No new camera-related kernel warning was recorded during this 300-frame binned run.

Result: **1296x972 2x2 binning streams successfully on the Surface Go 4 Alder Lake-N IPU6 path.**

## Raw Bayer phase

A direct 1296x972 `BG10` raw capture was taken with:

```text
binned_y_offset=2
raw size=2,550,528 bytes
```

Analysis of the four Bayer parity positions against regions with distinct red and blue content gave:

```text
B G
G R
```

Observed Bayer phase: **BGGR**.

This matches the phase advertised by `MEDIA_BUS_FMT_SBGGR10_1X10` with the default even `binned_y_offset=2`.

## libcamera AE / analogue-gain comparison

libcamera SimplePipeline selected the intended sensor modes:

| Test | Requested output | Actual OV5693 sensor mode |
|---|---:|---:|
| Full-resolution | 2048x1536 | 2592x1944 |
| Binned | 1152x864 | 1296x972 |

After 180 frames, the final controls were identical:

| Control | Full-resolution | Binned |
|---|---:|---:|
| Exposure code | 2070 | 2070 |
| ExposureTime | 33183 us | 33183 us |
| Analogue-gain code | 28 | 28 |
| libcamera AnalogueGain | 1.75x | 1.75x |
| Digital gain | 1024 | 1024 |

The binned run followed the full-resolution run and therefore began with the full-resolution terminal gain already programmed. It remained at `1.75x` for all 180 binned frames.

The approximately 10x analogue-gain reduction previously reported on a Surface Pro 7+ was **not reproduced** on this Surface Go 4 test.

## Fixed-control raw signal comparison

To remove AE from the comparison, raw frames were captured with identical controls:

```text
analogue_gain=8
digital_gain=1024
exposure=500 and 1000
```

Global raw statistics were:

| Exposure | Mode | Mean DN | Median DN | Saturated pixels |
|---:|---|---:|---:|---:|
| 500 | 2592x1944 full | 120.34 | 38 | 2.61% |
| 500 | 1296x972 binned | 120.39 | 37 | 2.47% |
| 1000 | 2592x1944 full | 173.96 | 58 | 8.20% |
| 1000 | 1296x972 binned | 172.60 | 57 | 7.92% |

Using the approximately 16-DN black pedestal documented by the binning patch, the black-subtracted median changed as follows when exposure doubled:

```text
full:   22 -> 42  = 1.91x
binned: 21 -> 41  = 1.95x
```

At a fixed exposure and gain, the full-resolution and binned raw signal levels were therefore approximately equal. No multi-fold increase in raw DN level was observed from hardware binning on this Surface Go 4.

## Temporal-noise and SNR comparison

Eight consecutive raw frames were saved for each mode after eight startup frames were discarded.

Fixed controls:

```text
exposure=500
analogue_gain=8
digital_gain=1024
```

Temporal noise was measured as the per-pixel standard deviation across the eight frames. Slow frame-wide brightness drift was normalized before calculating the final values. A software 2x2 comparison was also generated by averaging four same-color samples from the full-resolution Bayer data.

Median temporal noise by raw-signal range:

| Mean raw level (DN) | Full-res single pixel sigma | Software 2x2 sigma | Hardware 2x2 sigma | HW SNR / Full | HW SNR / SW 2x2 |
|---:|---:|---:|---:|---:|---:|
| 40-64 | 7.50 | 3.90 | **3.58** | **2.09x** | **1.09x** |
| 64-96 | 8.90 | 4.57 | **3.94** | **2.26x** | **1.16x** |
| 96-160 | 11.24 | 5.85 | **4.91** | **2.29x** | **1.19x** |
| 160-256 | 14.33 | 7.86 | **6.85** | **2.09x** | **1.15x** |

Across these midtone ranges, hardware binning reduced temporal noise to approximately **0.44-0.48x** the full-resolution single-pixel noise level.

For approximately equal signal levels, this corresponds to an SNR improvement of **2.09-2.29x**, or about **+6.4 to +7.2 dB**, relative to a full-resolution single pixel.

Hardware binning also measured lower temporal noise than software averaging of four same-color full-resolution samples: approximately **0.84-0.92x** the software-averaged noise, corresponding to about **1.09-1.19x** higher SNR.

## CSI-2 observations during short fixed-control tests

The short fixed-control binned captures repeatedly produced one pair of startup messages:

```text
Inter-frame short packet discarded
Inter-frame long packet discarded
```

The same pair appeared at the start of the binned temporal-noise sequence. The saved frames were captured only after startup frames had been skipped, and all requested frames completed.

The full-resolution temporal-noise sequence produced a startup `Transfer FIFO overflow` followed by inter-frame packet-discard messages. Full-resolution fixed-control single-frame captures at exposure 500 and 1000 were clean.

No `Frame sync error` was observed in the completed full-resolution or binned tests described above.

## Alder Lake-N bit-5 + binning result

```text
Alder Lake-N IPU6 PCI 8086:462e recognized:      PASS
conditional MIPI bit-5 implementation present:   PASS
unconditional MIPI_CTRL00=0x2d absent:            PASS
1296x972 2x2 binned stream on ADL-N:              PASS
300/300 binned frames at ~28.64 fps:               PASS
binned Bayer phase with y_offset=2 is BGGR:        PASS
Frame sync error during 300-frame binned run:      0
Transfer FIFO overflow during 300-frame binned run:0
~10x AE analogue-gain reduction on Surface Go 4:  NOT OBSERVED
hardware-binning temporal-noise reduction:         OBSERVED
```

## Conclusion

On the tested Microsoft Surface Go 4 with Alder Lake-N IPU6 `8086:462e`, the patched OV5693 driver successfully streams the 1296x972 2x2-binned mode at the same approximately 28.64 fps as 2592x1944 full resolution. A 300-frame binned capture completed without `Frame sync error` or `Transfer FIFO overflow`, and the default `binned_y_offset=2` produced the expected BGGR Bayer phase.

The Surface Pro 7+ observation of an approximately 10x lower analogue gain in binned mode was not reproduced. At fixed exposure and gain, the binned raw signal level was approximately the same as full resolution. However, hardware binning produced a clear temporal-noise benefit: roughly half the single-pixel full-resolution noise and approximately 2.1-2.3x higher SNR in the measured midtone ranges. It also provided a smaller but repeatable SNR improvement over software averaging of four same-color full-resolution samples.
