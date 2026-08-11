# Surface Go 4 Camera Analysis

## Scope and evidence rules

This report keeps observation, source analysis, hypothesis, and proposed verification separate. It does not modify a kernel driver.

- **CONFIRMED** means directly present in repository evidence or in the pinned upstream source.
- **LIKELY** means the evidence strongly supports the conclusion but a decisive hardware observation is missing.
- **UNKNOWN** means the required dump, trace, specification, or test is absent.

Audited repository snapshot: main commit `3b580309b35a` (2026-07-26). Upstream source snapshots and register-level detail are recorded in [sensor-register-map.md](sensor-register-map.md).

Information not available in this repository:

- a Windows camera dump or Windows INF package;
- a Linux dump containing ACPI tables, full media topology, all V4L2 controls, and live I2C traces from the same boot;
- OV8865/OV5693 public vendor register specifications;
- sensor-specific tuning/calibration files;
- a before/after I2C trace for exposure, gain, VBLANK, and focus commands.

Those gaps are not filled by guessing.

## Repository audit

The repository is small and contains no vendored kernel, IPU6, or libcamera source. At the audited commit it contains:

- `README.md`: hardware/status summary and basic tests;
- `ipu6-camera-setup-en.sh`: Ubuntu 26.04 package/setup diagnostics, including DW9714 and tuning checks;
- `docs/surface-go4-ipu6-camera-root-cause-and-validation.md`: detailed OV5693, WirePlumber, and end-to-end validation;
- photographs/screenshots and the MIT license.

No `patches/` directory, sensor driver source, ACPI dump, Windows dump, register trace, tuning data, or in-repository TODO file existed before this analysis.

Important history recoverable through the GitHub API:

| Date (UTC) | Commit | Relevant change |
| --- | --- | --- |
| 2026-04-03 | `31c8a6d6e740` | Documented exposure flicker. |
| 2026-07-26 | `efbb2ffd9130` | Added Ubuntu 26.04 setup support. |
| 2026-07-26 | `3b580309b35a` | Added the root-cause and end-to-end validation report. |

Open repository Issue #1 records the DW9714 binding-without-devnode failure. The other entries returned by the issue API were pull requests. Branches found were `main`, `test/26.04LTS`, `agent/automate-wireplumber-camera-recovery`, and `docs/surface-go4-ipu6-root-cause-report`. Git itself was unavailable in the analysis environment, so history was read through the API and the working source came from the main-branch archive.

## Current Status

### OV8865 rear camera

| Area | Status | Evidence |
| --- | --- | --- |
| Probe | CONFIRMED working in the tested system | Entity `ov8865 4-0010` and rear camera are listed. |
| Stream | CONFIRMED partial/basic operation | Rear live video and still capture were observed. This does not prove every mode/timing is correct. |
| Exposure | LIKELY register path works; behavior not validated | Upstream maps exposure to `0x3500..0x3502`; repository reports flicker but contains no I2C trace/readback. |
| Analogue gain | LIKELY register path works; behavior not validated | Upstream maps gain to `0x3508/0x3509`, consistent with libcamera's `gain/128` helper. |
| Digital gain / WB | PARTIAL | No `DIGITAL_GAIN`; red/blue sensor ISP balance controls exist, green is not exposed. Soft ISP also applies AWB separately. |
| Autofocus | CONFIRMED unavailable in tested stack | DW9714 binds but has no V4L2 devnode; libcamera disables the lens. Simple pipeline has no lens/AF path in the audited upstream source. |
| ISP / tuning | CONFIRMED uncalibrated | `ov8865.yaml` is missing; simple IPA falls back to `uncalibrated.yaml`; processing is Soft ISP, not a complete IPU6 hardware ISP solution. |
| Known issues | CONFIRMED/PARTIAL | Exposure flicker, missing AF, missing tuning, CPU-heavy Soft ISP, startup/discovery sensitivity. |

### OV5693 front camera

| Area | Status | Evidence |
| --- | --- | --- |
| Probe | CONFIRMED | Sensor is enumerated as front camera at `\_SB_.PC00.I2C3.CAMF`. |
| Stream | CONFIRMED with experimental workaround | Stock cold-start could produce zero frames and IPU6 timeouts. Writing `MIPI_CTRL00 (0x4800)=0x2d` immediately before stream-on produced valid cold-boot frames in the recorded test. |
| Exposure | LIKELY register path works; not traced | Upstream writes `(lines << 4)` to 24-bit `0x3500`. |
| Analogue gain | LIKELY path works, encoding needs hardware validation | Upstream writes `(code << 4)` to `0x350a`; libcamera maps code as `code/16`. Default code 8 is 0.5x. |
| Digital gain | CONFIRMED control/write path exists | Same 12-bit value goes to RGB `0x3400/0x3402/0x3404`; current simple AGC does not drive it. |
| Autofocus | Not applicable/UNKNOWN | No front VCM is identified by repository evidence. Do not infer one. |
| ISP / tuning | CONFIRMED uncalibrated | `ov5693.yaml` missing; same simple Soft ISP constraints as rear. |
| Known issues | CONFIRMED/PARTIAL | Missing upstream Surface/IPU6 MIPI write, occasional CSI-2 warnings in an earlier test, missing tuning, application discovery timing. |

## Camera Architecture

```text
Microsoft Surface Go 4 firmware
  ACPI devices: CAMF / CAMR
  SSDB: CSI link, lane count, MCLK, rotation, VCM type
  _PLD: front/back orientation
        |
        v
Linux intel IPU bridge
  creates software-node endpoints, link-frequency, clock/regulator/GPIO mappings
  and (for CAMR) a lens-focus reference / VCM I2C client
        |
        +---------------- sensor path -----------------------------+
        |                                                          |
        v                                                          v
OV5693 front subdevice                                      OV8865 rear subdevice
  I2C + 2-lane RAW10                                         I2C + RAW10
        |                                                          |
        +-------------------- MIPI CSI-2 ---------------------------+
                                   |
                                   v
                         Intel IPU6 ISYS receiver
                                   |
                         media controller / V4L2
                                   |
                         libcamera simple pipeline
                                   |
                         simple IPA + Soft ISP / 3A
                                   |
                         PipeWire / WirePlumber
                                   |
                              application

Separate rear focus path:

libcamera pipeline/AF request (currently missing in simple pipeline)
        |
V4L2_CID_FOCUS_ABSOLUTE
        |
DW9714 lens subdevice (binds, but tested system has no /dev/v4l-subdev node)
        |
16-bit I2C payload: (position << 4) | slope
        |
lens actuator
```

IPU6 ISYS receives and DMA-captures raw CSI-2 frames. In this repository's configuration, image processing is performed by libcamera's software ISP. ISYS detection, sensor streaming, 3A behavior, Soft ISP image quality, PipeWire publication, and application behavior are distinct success/failure boundaries.

## Linux Driver Analysis

### ACPI, SSDB, and software nodes

Pinned upstream `ipu-bridge.c` contains explicit entries:

- OV5693 ACPI HID `INT33BE`, link frequency 419.2 MHz;
- OV8865 ACPI HID `INT347A`, link frequency 360 MHz.

The bridge reads `SSDB` fields for CSI link, lane count, MCLK, rotation, and VCM type; `_PLD` supplies front/back orientation. It creates CSI endpoint properties and, when a VCM type exists, a `lens-focus` reference. VCM instantiation is deferred work: the sensor is runtime-resumed, an I2C client is created from the ACPI secondary fwnode, and a runtime-PM device link to the sensor is added.

The Surface-specific actual SSDB bytes, lane/link indices, GPIO mappings, regulator mappings, clock provider, and privacy LED routing are UNKNOWN because there is no ACPI/sysfs dump in the repository. The Linux collector added by this work captures the evidence needed to resolve them.

### Sensor lifecycle comparison

| Stage | OV8865 | OV5693 |
| --- | --- | --- |
| Probe checks | regulators, fwnode CSI endpoint, reset/powerdown GPIO, sensor clock (19.2 or 24 MHz), link frequency | two-lane endpoint, 419.2 MHz link frequency, 19.2 MHz clock warning, GPIOs, three regulators |
| Power on | DOVDD → AVDD → DVDD → clock → deassert GPIOs → 10–12 ms | clock → AVDD/DOVDD/DVDD bulk enable → deassert GPIOs → 5–7.5 ms |
| Reset/init | reset, standby, chip ID, global init, MIPI/ISP/BLC, current mode | reset, 145-register global table, current crop/mode, standby |
| Runtime PM | resume reapplies init and all controls; stop uses runtime put | resume reapplies init; stream-on calls control-handler setup; autosuspend configured at probe |
| Stream | `0x0100` standby bit | `0x0100=1/0`; no upstream `0x4800` write |
| Format | four discrete RAW10 modes | dynamic crop plus 1×/2× binning, RAW10 only |
| Embedded metadata | no exposed stream | no exposed stream |
| Group hold | absent | absent |

Both drivers keep desired mode in driver state and normally program it during runtime resume/init. A mode/crop change made while the device remains powered does not itself call the mode-I2C function. Whether the normal libcamera stop/configure/start sequence always forces a suspend before stream-on must be tested. This is a code-level risk, not proof of the currently reported brightness or AF symptoms.

## OV8865 Register Analysis

The control-to-register path is concrete:

```text
V4L2_CID_EXPOSURE
  -> ov8865_s_ctrl()
  -> ov8865_exposure_configure(lines)
  -> lines * 16
  -> I2C 0x3500, 0x3501, 0x3502

V4L2_CID_ANALOGUE_GAIN
  -> ov8865_analog_gain_configure(code)
  -> I2C 0x3508, 0x3509

V4L2_CID_VBLANK
  -> exposure max = height + vblank - 8
  -> ov8865_vts_configure()
  -> I2C 0x380e, 0x380f
```

This disproves the broad hypothesis that these controls only change driver variables in current upstream source. It does not prove that the tested distribution used the same source, that I2C writes succeeded, or that delayed controls arrived at the intended frame. Capture kernel source identity and an I2C trace before proposing a sensor-driver fix.

Most suspicious OV8865-specific areas:

1. no group hold across multi-register exposure/gain updates;
2. no readback or trace proving values reach the physical sensor in the failing scene;
3. mode programming deferred to resume, requiring a powered reconfigure test;
4. MIPI `0x4837=0x16` is an upstream empirically chosen value with an explicitly uncertain clock relationship;
5. no calibrated simple IPA tuning, which can mimic a sensor-control error.

See [sensor-register-map.md](sensor-register-map.md#ov8865) for mode/register tables.

## OV5693 Register Analysis

The exposure/gain/VTS/mode write paths exist and are internally consistent at source level. The decisive difference is stream initialization:

```text
upstream ov5693_enable_streaming():
  0x0100 <- 0x01

Surface Go 4 experimental sequence that produced cold-boot frames:
  0x4800 <- 0x2d
  0x0100 <- 0x01
```

The repository records a cold-boot A/B result and IPU6 timeout symptoms, so the missing `0x4800` programming is the strongest front-camera bug candidate. It remains inappropriate to copy a Windows register table wholesale. The clean-room next step is to trace the minimal Windows/Linux hardware configuration, decode `0x2d` only from public documentation if available, and upstream a narrowly scoped, reviewed fix.

Other audit findings:

- active crop is 2592×1944 at `(16,6)` within 2624×1956;
- HTS is fixed at 2688; VTS is height plus VBLANK;
- exposure is lines shifted left by four, clamped to VTS minus eight;
- analogue gain is code shifted left by four; libcamera maps code/16;
- digital gain writes equal RGB 12-bit values;
- no group hold protects these multi-register sequences;
- mode changes are state-only until sensor init/resume.

See [sensor-register-map.md](sensor-register-map.md#ov5693).

## Autofocus / VCM Analysis

### What is confirmed

- Surface Go 4 rear ACPI data causes a `dw9714` VCM I2C client at `4-000c` to exist.
- The kernel driver is bound and the media graph contains a Lens entity.
- The VCM driver exposes `V4L2_CID_FOCUS_ABSOLUTE` from 0 to 1023 and converts it to a big-endian two-byte I2C payload `(position << 4) | 0`.
- On the tested machine, the lens entity has no `/dev/v4l-subdev*` node. libcamera logs “Failed to open V4L2 device” and disables the lens.
- Pinned upstream libcamera discovers ancillary lens entities and requires an openable lens subdevice with `FOCUS_ABSOLUTE`.
- Pinned upstream simple pipeline contains no focus-lens, `LensPosition`, `AfMode`, or AF algorithm path.

### Failure-chain assessment

| Candidate | Assessment | Evidence / missing evidence |
| --- | --- | --- |
| 1. VCM device not recognized | Unlikely as primary | I2C device and driver binding are CONFIRMED. |
| 2. Driver not bound | Rejected for recorded boot | `DRIVER=dw9714` and media Lens entity are CONFIRMED. |
| 3. Not connected in media graph | PARTIAL | Ancillary Lens entity is present, but devnode is blank. Exact ancillary link/notifier state needs full `media-ctl -p` and sysfs dump. |
| 4. libcamera does not recognize VCM | CONFIRMED consequence | It finds the entity but cannot open it, then disables it. |
| 5. AF algorithm absent | CONFIRMED in simple pipeline snapshot | Even after fixing the node, automatic/continuous AF is not implemented by this pipeline. Manual lens plumbing is also absent there. |
| 6. Focus command does not reach I2C | CONFIRMED under current stack | No open lens/control path means no userspace focus command reaches `dw9714_set_ctrl()`. Direct V4L2-subdev testing is impossible until a devnode exists. |
| 7. Calibration/range wrong | UNKNOWN | No command reaches the actuator and no calibration data/range sweep exists. Test only after 3–6 are fixed. |

The immediate kernel/media problem is devnode registration. The next userspace problem is lens-control support in the simple pipeline. Continuous AF then additionally requires an AF algorithm and tuning/calibration. Fixing only OV8865 sensor code cannot resolve this chain.

## Exposure / Gain Analysis

### Sensor layer

- Both sensors have explicit exposure, analogue gain, and VTS I2C write paths.
- Both update exposure maximum when VBLANK changes.
- OV5693 also exposes digital gain; OV8865 exposes red/blue balance instead.
- Neither uses group hold, and neither repository nor dump provides register readback/I2C proof.

### libcamera control propagation

The simple pipeline's Soft IPA requires `V4L2_CID_EXPOSURE` and `V4L2_CID_ANALOGUE_GAIN`, computes new line/gain-code values, and sends them through delayed controls. Pinned current source applies controls at frame-start when an emitter is available; without one it applies immediately and contains a source TODO warning that this can cross frame boundaries and create AGC regulation issues.

The tested libcamera 0.7 camera-facing control list reportedly contained only `Contrast` and `Gamma`. That does not prove sensor exposure/gain are unused internally: simple AGC can still drive kernel V4L2 controls. It does mean applications cannot independently disable/override AE or request `ExposureTime`, `AnalogueGain`, or `LensPosition` through the reported camera interface.

### 3A and tuning

- simple AGC uses image statistics to change exposure first, then analogue gain when dark, and reverses gain first when bright;
- AWB gains are applied in software debayer parameters, not necessarily to OV8865 red/blue sensor registers;
- missing sensor YAML causes fallback to generic uncalibrated algorithms/parameters;
- no automatic focus algorithm exists in the audited simple pipeline.

### ISP/image layer

Gamma, contrast, black level, AWB gains, color correction, demosaic, and noise/tone behavior can change perceived brightness even when exposure registers are correct. The current configuration uses CPU Soft ISP. A dark/bright/flickering image must therefore be correlated with:

1. requested sensor controls;
2. actual sensor register writes/readback;
3. per-frame statistics and delayed-control frame number;
4. Soft ISP parameters/output histogram;
5. application/PipeWire conversion.

## ISP / 3A Analysis

| Layer | Current evidence | Confidence | Decisive test |
| --- | --- | --- | --- |
| Sensor exposure | Source path exists; no hardware trace | LIKELY working | Trace/read `0x3500..` while sweeping manual control. |
| Sensor analogue gain | Source/helper encodings align; no hardware trace | LIKELY working | Sweep code and correlate raw mean/variance. |
| Sensor digital gain | OV5693 path exists; OV8865 has no generic control | CONFIRMED source | Direct V4L2 sweep on raw capture. |
| libcamera propagation | simple IPA/delayed-control path exists | CONFIRMED source, UNKNOWN tested timing | `LIBCAMERA_LOG_LEVELS=*:DEBUG` plus V4L2/I2C trace. |
| AE/AGC | generic simple AGC exists; flicker reported | PARTIAL | Log statistics, exposure, gain per frame under fixed lighting. |
| AWB | generic software AWB; sensor YAML absent | PARTIAL/uncalibrated | RAW chart captures and AWB metadata. |
| AF | no usable lens path and no simple AF | CONFIRMED unavailable | Devnode first, then manual sweep, then AF implementation. |
| Gamma/contrast | only reported app controls | CONFIRMED | Fixed raw input, sweep Soft ISP controls. |
| CCM/noise/tone | no sensor calibration in repository | UNKNOWN/uncalibrated | Calibration chart plus tuning file audit. |

## Windows Reference Environment

Windows is used only as a working hardware-configuration reference. The added collector records:

- OS, Surface model, BIOS/UEFI, PnP Camera/Image devices and all relevant properties;
- hardware/compatible/instance IDs, class GUID, driver provider/version, INF, and service;
- `pnputil` device/driver/file inventory;
- relevant registry observations when explicitly requested;
- matching INF text when explicitly requested;
- path, version, size, timestamp, and SHA256 for relevant SYS/DLL/firmware, without copying those binaries.

It does not export complete DriverStore packages or commit any output. Static vendor binary analysis, if separately authorized and legally appropriate, must remain limited to identifiers, strings, firmware/configuration names, registry/IOCTL metadata, and evidence that an initialization step exists. Machine code or source-equivalent sequences must not be transplanted into Linux.

Run:

```powershell
tools\windows-camera-dump\collect.ps1 -IncludeRegistry -CopyInfFiles
```

## Windows vs Linux Comparison

The added comparison script scans sanitized dump text/JSON, maps OV8865, OV5693, IPU6, CSI, and VCM aliases/IDs, and emits HIGH/MEDIUM/LOW mapping confidence. HIGH requires the same exact ACPI/HW ID on both sides; a component name alone cannot become HIGH.

```bash
python3 tools/compare-camera-dumps.py \
  /path/to/windows-dump /path/to/linux-dump \
  --output analysis/reports/comparison.md \
  --json analysis/reports/comparison.json
```

Expected anchor mappings from upstream, pending actual Windows/Linux dumps:

| Component | Windows/ACPI anchor | Linux expectation | Current status |
| --- | --- | --- | --- |
| OV8865 | `INT347A` / CAMR | I2C sensor, driver `ov8865`, 360 MHz endpoint | LIKELY; exact dump absent |
| OV5693 | `INT33BE` / CAMF | I2C sensor, driver `ov5693`, 419.2 MHz endpoint | LIKELY; exact dump absent |
| IPU6 | Intel imaging controller | PCI IPU6 + ISYS media graph | LIKELY; IDs absent |
| CSI | SSDB link/lanes | IPU6 ISYS CSI receiver endpoints | UNKNOWN without SSDB/topology |
| Rear VCM | SSDB VCM type | `dw9714 4-000c`, lens-focus ancillary entity | CONFIRMED on Linux; Windows ID absent |

## Suspicious Differences

1. **OV5693 MIPI_CTRL00:** working Surface sequence has `0x4800=0x2d`; upstream stream-on does not.
2. **Rear VCM accessibility:** ACPI bridge and driver create/bind a lens entity, but the tested Linux graph gives it no userspace subdev node.
3. **AF capability:** Windows reportedly autofocuses; Linux simple pipeline exposes no AF/lens controls.
4. **Tuning/calibration:** Windows vendor stack has device calibration/configuration; Linux falls back to generic `uncalibrated.yaml`.
5. **Control surface:** tested Linux camera exposes only Contrast/Gamma, despite sensor-side exposure/gain controls.
6. **Discovery timing:** Windows reference is stable; Linux WirePlumber can enumerate before `/dev/media0` is accessible.
7. **Mode transition semantics:** Linux sensor mode writes are deferred to resume/init; actual Windows sequencing is not yet collected.
8. **Atomicity:** Linux drivers do not use group hold for exposure/gain; Windows behavior is unknown.

## Bug Candidates

### Candidate #1 — OV5693 missing IPU6 MIPI stream initialization

- **Description:** upstream stream-on omits `MIPI_CTRL00 0x4800=0x2d` required by the tested Surface Go 4.
- **Evidence:** cold-boot stock module produced zero frames/timeouts; minimal extra write produced valid frames.
- **Confidence:** HIGH for tested hardware; bit meaning UNKNOWN.
- **Expected symptom:** LED/sensor detected, no frames, IPU6 stream stop/close timeouts.
- **How to verify:** cold power-off A/B test, same kernel/config, 30+ first-access cycles; trace I2C and CSI errors.
- **Possible fix direction:** narrowly scoped IPU6/ACPI quirk or reviewed mode init after establishing public semantics and upstream consensus.

### Candidate #2 — DW9714 lens entity lacks a V4L2 devnode

- **Description:** driver binds and media entity exists, but entity devname is empty.
- **Evidence:** repository Issue #1, sysfs binding, media graph, and libcamera open failure.
- **Confidence:** HIGH.
- **Expected symptom:** lens disabled; no `LensPosition`; no I2C focus commands.
- **How to verify:** full `media-ctl -p`, `/sys/class/video4linux`, software-node/ancillary links, notifier logs, compare a system with a working DW9714.
- **Possible fix direction:** diagnose V4L2 async notifier/subdev-node registration and media ancillary-link creation; do not patch sensor controls.

### Candidate #3 — simple pipeline has no lens/AF plumbing

- **Description:** audited simple pipeline never accesses `focusLens()` or advertises focus/AF controls.
- **Evidence:** pinned upstream source has no lens/Focus/Af symbols in the pipeline; generic CameraSensor can discover a lens but the pipeline does not use it.
- **Confidence:** HIGH for the audited source.
- **Expected symptom:** fixing the devnode alone still does not yield application AF.
- **How to verify:** run a build with devnode fixed, inspect camera controls, attempt manual `LensPosition`, trace `FOCUS_ABSOLUTE`.
- **Possible fix direction:** add reviewed manual lens plumbing, then an AF algorithm/tuning; treat these as separate milestones.

### Candidate #4 — missing OV8865/OV5693 simple IPA tuning

- **Description:** both sensors use `uncalibrated.yaml`.
- **Evidence:** explicit libcamera warnings in the repository.
- **Confidence:** HIGH.
- **Expected symptom:** unstable brightness/color, weak AWB/AE response, poor black level/CCM/gamma/noise behavior.
- **How to verify:** save RAW frames and per-frame stats; compare a minimal sensor YAML and calibrated chart dataset.
- **Possible fix direction:** build reproducible tuning datasets; do not mask a CSI/register failure with tuning changes.

### Candidate #5 — delayed-control/frame association causes AE oscillation

- **Description:** controls may be applied outside the intended frame boundary if IPU6 lacks a usable frame-start emitter/path.
- **Evidence:** simple pipeline source explicitly warns immediate fallback can cause AGC regulation issues; repository reports flicker.
- **Confidence:** MEDIUM.
- **Expected symptom:** exposure/gain lag, oscillation, brightness flicker while I2C values still change.
- **How to verify:** log frame sequence, requested/applied exposure and gain, frame-start events, and image mean.
- **Possible fix direction:** ensure IPU6 frame-start events and correct sensor delay properties are used.

### Candidate #6 — mode changes are not applied while the sensor remains powered

- **Description:** `set_fmt`/crop updates state; mode I2C writes occur during resume/init.
- **Evidence:** CONFIRMED source structure for both drivers; normal runtime-PM sequencing may avoid it.
- **Confidence:** MEDIUM.
- **Expected symptom:** requested dimensions/timing reported by controls but old sensor output remains, CSI mismatch/timeouts.
- **How to verify:** stop, change mode within autosuspend window, restart while tracing PM and `0x3800..0x3821` writes.
- **Possible fix direction:** only after reproduction, guarantee mode programming before stream-on or force a safe reinit.

### Candidate #7 — OV5693 analogue gain range/default mismatch

- **Description:** driver default code 8 maps to 0.5x with libcamera's `code/16` helper and allows code 1.
- **Evidence:** source values are internally observable; correct sensor range/spec is absent.
- **Confidence:** MEDIUM-LOW.
- **Expected symptom:** unexpected initial darkness or nonlinear AE near low gain.
- **How to verify:** fixed exposure RAW sweep codes 1, 8, 16, 32…; measure mean/variance and actual registers.
- **Possible fix direction:** align control range/default/helper only with specification or measured transfer curve.

### Candidate #8 — non-atomic multi-register exposure/gain updates

- **Description:** no group hold surrounds multi-byte/multiple-control writes.
- **Evidence:** CONFIRMED source absence; impact not observed directly.
- **Confidence:** MEDIUM-LOW.
- **Expected symptom:** occasional torn exposure/gain frame or flicker at update boundaries.
- **How to verify:** high-rate I2C trace synchronized with frame starts and controlled large steps.
- **Possible fix direction:** use documented group hold only if public spec and hardware testing confirm it.

### Candidate #9 — WirePlumber media-device permission/startup race

- **Description:** WirePlumber enumerates before `/dev/media0` access is ready and does not retry.
- **Evidence:** recorded failure and recovery after service restart.
- **Confidence:** HIGH for the recorded userspace failure.
- **Expected symptom:** sensors work with `cam`, but desktop app shows no physical libcamera camera or opens an internal raw IPU6 V4L2 node.
- **How to verify:** compare boot journal, ACLs, `cam -l`, and PipeWire nodes before/after restart.
- **Possible fix direction:** correct session/udev ordering and trigger safe re-enumeration; keep separate from sensor fixes.

### Candidate #10 — OV8865 MIPI timing or mode-specific edge case

- **Description:** empirical `0x4837=0x16`, multiple PLL/mode tables, and untested mode transitions may hide mode-specific errors.
- **Evidence:** upstream comment says the relationship is unclear; rear basic stream works.
- **Confidence:** LOW-MEDIUM.
- **Expected symptom:** only certain resolutions/frame rates show CSI errors or unstable capture.
- **How to verify:** cold/warm matrix of all four modes with receiver counters and I2C register snapshots.
- **Possible fix direction:** derive timing from clock configuration only after reproducible mode-specific evidence.

## Priority ranking — current most suspicious issues

1. OV5693 missing `0x4800=0x2d` Surface/IPU6 stream initialization.
2. DW9714 bound lens entity without `/dev/v4l-subdev*`.
3. No lens/AF support in libcamera simple pipeline.
4. Missing `ov8865.yaml` and `ov5693.yaml` tuning/calibration.
5. Delayed-control/frame-start timing causing AE/AGC flicker.
6. WirePlumber `/dev/media0` permission/startup race.
7. Mode state changed without guaranteed same-power-session register programming.
8. OV5693 low analogue-gain range/default encoding.
9. No group hold for exposure/gain updates.
10. OV8865 mode/MIPI timing edge cases, including empirical `0x4837`.

The ranking combines impact, repository evidence, and confidence. Items 1, 2, 4, and 6 have direct Surface observations. Items 5, 7, 8, 9, and 10 need targeted traces before any driver change.

## Data to collect next

### Windows

Run `tools/windows-camera-dump/collect.ps1 -IncludeRegistry -CopyInfFiles` and retain, after redaction:

- exact PnP hardware/compatible IDs for CAMR/CAMF/IPU6/CSI/VCM;
- ACPI/instance IDs and class/parent relationships;
- driver versions, INF names, services, and INF text;
- firmware/configuration filenames and binary metadata/SHA256;
- camera control ranges and mode lists if accessible through Windows camera APIs;
- a clean-room I2C/register observation for stream start, exposure/gain change, and focus sweep, if a lawful supported tracing method exists.

Do not add vendor binaries to Git.

### Linux

Run `tools/linux-camera-dump/collect.sh --sudo --debug-libcamera` immediately after a cold boot and again after a successful capture. Preserve:

- ACPI dump, decoded SSDB/DSD/PLD, software nodes, I2C devices and drivers;
- full media graph including entity devnames and ancillary links;
- every sensor/lens V4L2 control/range;
- kernel and libcamera debug logs with frame/CSI errors;
- module filenames, versions, source versions, and whether OV5693 is stock/patched;
- exposure/gain/VBLANK requested values and actual I2C writes/readback;
- PipeWire/WirePlumber state and `/dev/media0` ACL timing.

## Next physical tests

1. Fully power off, boot, identify exact kernel/modules/libcamera, and collect the baseline Linux dump before opening any camera.
2. Run 30 cold-boot first-access OV5693 captures with stock and minimal `0x4800=0x2d` builds; record frames, FPS, CSI errors, and timeouts.
3. On OV8865 RAW capture under fixed light, sweep manual exposure while holding gain constant; trace `0x3500..0x3502` and verify image mean is monotonic.
4. Sweep OV8865 analogue gain while holding exposure constant; trace `0x3508/0x3509` and measure mean/noise.
5. Repeat exposure/gain/VBLANK tests on OV5693, including gain codes 1, 8, 16, 32, 64, 127 and VTS/exposure boundary cases.
6. Stop a stream, change mode before autosuspend, restart, and verify `0x3800..0x3821` are rewritten and CSI dimensions match.
7. Diagnose DW9714 devnode registration using full media/sysfs/notifier evidence. Do not test AF algorithm yet.
8. Once a lens devnode exists, perform a direct `FOCUS_ABSOLUTE` 0→1023→0 sweep, trace I2C, confirm motion/direction/range, and only then add libcamera manual lens plumbing.
9. Record per-frame exposure/gain/statistics and image mean under fixed lighting to determine whether flicker is sensor write, delayed control, or AGC behavior.
10. Capture color chart, gray card, dark frames, and flat fields for both sensors before creating sensor-specific tuning.

The next code change should follow the first failing boundary demonstrated by these tests, not the visually most obvious symptom.
