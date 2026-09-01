# Surface Go 4 OV5693 v4 / Alder Lake-N A/B validation result

Date: 2026-09-02  
Device: Microsoft Surface Go 4  
Kernel: `7.0.0-30-generic`  
IPU6 PCI ID: `8086:462e` (`PCI_DEVICE_ID_INTEL_IPU6EP_ADLN`)  
Front camera: `\_SB_.PC00.I2C3.CAMF` / OV5693

## Scope

This validation compares the upstream OV5693 v4 semantics, minimally backported to Ubuntu `7.0.0-30.30`, against the same build with one additional Alder Lake-N bridge match for `INT33BE`.

The functional delta between the two bridge sources was only:

```c
IPU_SENSOR_CONFIG_MATCH_FL("INT33BE", PCI_DEVICE_ID_INTEL_IPU6EP_ADLN,
                           CSI2_CLK_NONCONTINUOUS, 1, 419200000),
```

The original v4 bridge source was preserved. The ADL-N test used an isolated copy of `ipu-bridge.c`. All four external modules were rebuilt together in one Kbuild/modpost run and signed with the same enrolled local MOK.

## Common test conditions

Both stream attempts used:

```bash
timeout 60s cam \
  -c '\_SB_.PC00.I2C3.CAMF' \
  -C300
```

For the ADL-N result, the machine was fully powered off and cold-booted. Before the deliberate stream, verification confirmed that all four ADL-N test modules were loaded and that there was no earlier IPU6 stream activity in the boot.

## Negative control: v4 without ADL-N match

Loaded experimental stack:

- `ov5693`: `96C1F839F2269A46CE5CD0E`
- `ipu_bridge`: `B08D82A08945153498EEB37`
- `intel_ipu6`: `0549D5D1ECD2708B2B4F29D`
- `intel_ipu6_isys`: `94DB31A2B1F8AE58F5E41C5`

Result:

```text
requested_frames=300
exit_code=124
frame_count=0
```

Relevant kernel messages:

```text
intel_ipu6_isys.isys intel_ipu6.isys.40: stream stop time out
intel_ipu6_isys.isys intel_ipu6.isys.40: stream close time out
```

libcamera still discovered and configured the front camera, so this was not a camera-enumeration failure. The failure occurred at frame delivery / stream operation.

## ADL-N bridge-match test

Loaded experimental stack:

- `ov5693`: `96C1F839F2269A46CE5CD0E`
- `ipu_bridge`: `489EA8A6496C8EC6241F077`
- `intel_ipu6`: `0549D5D1ECD2708B2B4F29D`
- `intel_ipu6_isys`: `94DB31A2B1F8AE58F5E41C5`

Only the bridge module source version changed, consistent with the intended one-entry source change.

Cold-boot first-stream result:

```text
requested_frames=300
exit_code=0
frame_count=300
last_frame_line=286.847522 (28.64 fps) cam0-stream0 seq: 000299 bytesused: 20404224
```

Relevant kernel messages during the successful stream: none.

## A/B result

```text
v4 without ADL-N match: 0 / 300 frames, timeout
v4 with ADL-N match:  300 / 300 frames, exit 0
```

This device-specific A/B test strongly supports adding the Alder Lake-N `INT33BE` bridge match so that the OV5693 endpoint receives the `clock-noncontinuous` property on Surface Go 4 / IPU6EP ADL-N.

This result demonstrates the behavior on the tested Surface Go 4 and should not be interpreted as a universal result for every OV5693/IPU6 system.

## Evidence directories

- Negative control: `tests/2026-09-01-ov5693-v4-adln/01-v4-unmodified/negative-control/`
- ADL-N source/build proof: `tests/2026-09-01-ov5693-v4-adln/02-v4-adln/stack-build-r2/`
- ADL-N post-cold-boot verification: `tests/2026-09-01-ov5693-v4-adln/02-v4-adln/post-coldboot/`
- ADL-N first stream: `tests/2026-09-01-ov5693-v4-adln/02-v4-adln/first-stream/`
