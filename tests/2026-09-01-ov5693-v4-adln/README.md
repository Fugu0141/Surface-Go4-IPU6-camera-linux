# Surface Go 4 OV5693 upstream v4 / ADL-N validation

This directory records the full validation process requested in linux-surface/linux-surface PR #2171 for the upstream OV5693 v4 series on Microsoft Surface Go 4 (Alder Lake-N / IPU6).

## Goal

1. Confirm the Surface Go 4 sensor enumeration (expected `INT33BE`, but verify it on the test machine).
2. Apply the upstream v4 series exactly as posted and confirm the front camera does **not** stream on ADL-N without the bridge match entry.
3. Add the proposed ADL-N bridge entry:

```c
IPU_SENSOR_CONFIG_MATCH_FL("INT33BE", PCI_DEVICE_ID_INTEL_IPU6EP_ADLN,
                           CSI2_CLK_NONCONTINUOUS, 1, 419200000),
```

4. Rebuild/retest and confirm whether the front camera streams.
5. If successful, perform a 300-frame capture run and preserve complete logs for a `Tested-by:` report.

## Test stages

- `00-baseline/` — system/hardware/kernel/libcamera state before changes
- `01-v4-unmodified/` — upstream v4 series exactly as posted; expected failure on Go 4
- `02-v4-adln-entry/` — v4 plus proposed ADL-N bridge entry; expected success if the hypothesis is correct
- `03-summary/` — concise comparison and material suitable for upstream reporting

## Logging policy

Preserve complete command output whenever practical. Do not trim warnings merely because they appear unrelated; this directory is intended to make the full experimental sequence auditable.

For each stage, record:

- exact kernel version and git commit / patch source
- Secure Boot state
- module paths, versions and signatures
- PCI ID / IPU generation
- ACPI / I2C sensor enumeration
- `cam -l`
- capture command output
- relevant `dmesg` / journal output
- any build or module-load errors

## Upstream context

The v4 bridge currently has confirmed clock-noncontinuous matches for Tiger Lake and Alder Lake-P. Surface Go 4 uses Alder Lake-N (`0x462e`), so without an ADL-N match the bridge falls back to the plain sensor configuration and leaves `MIPI_CTRL00` at its power-on default. The requested experiment is to confirm that adding the ADL-N match is sufficient on real Surface Go 4 hardware.
