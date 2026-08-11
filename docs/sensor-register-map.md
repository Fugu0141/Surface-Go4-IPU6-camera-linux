# Surface Go 4 sensor register map

This is a source audit, not a vendor datasheet. Meanings are classified as:

- **CONFIRMED** — named and used for that purpose by upstream Linux, or observed in this repository's reproducible test.
- **LIKELY** — strong source/behavioral evidence, but no public sensor specification was available in this repository.
- **UNKNOWN** — a literal exists in an initialization table but its purpose is not established here.

Source snapshots used on 2026-08-11:

- Linux `f5bbbfec59b4e2fb7520a91de3df8a6174325d6a`: [`ov8865.c`](https://github.com/torvalds/linux/blob/f5bbbfec59b4e2fb7520a91de3df8a6174325d6a/drivers/media/i2c/ov8865.c), [`ov5693.c`](https://github.com/torvalds/linux/blob/f5bbbfec59b4e2fb7520a91de3df8a6174325d6a/drivers/media/i2c/ov5693.c), [`dw9714.c`](https://github.com/torvalds/linux/blob/f5bbbfec59b4e2fb7520a91de3df8a6174325d6a/drivers/media/i2c/dw9714.c), and [`ipu-bridge.c`](https://github.com/torvalds/linux/blob/f5bbbfec59b4e2fb7520a91de3df8a6174325d6a/drivers/media/pci/intel/ipu-bridge.c).
- Repository main `3b580309b35a`, especially `surface-go4-ipu6-camera-root-cause-and-validation.md`.

## OV8865

### V4L2 controls to I2C writes

| V4L2 control | Driver function | Register(s) and written value | Status | Notes |
| --- | --- | --- | --- | --- |
| `V4L2_CID_EXPOSURE` | `ov8865_s_ctrl()` → `ov8865_exposure_configure()` | `0x3500=(E*16)[19:16]`, `0x3501=(E*16)[15:8]`, `0x3502=(E*16)[7:0]` | CONFIRMED | V4L2 value is in whole lines. Sensor storage uses 1/16-line units. No rounding is needed because the control step is one line. |
| `V4L2_CID_ANALOGUE_GAIN` | `ov8865_s_ctrl()` → `ov8865_analog_gain_configure()` | `0x3508=G[12:8]`, `0x3509=G[7:0]` | CONFIRMED | Control range `128..2048`, step `128`; libcamera helper maps real gain as `G/128`. This is 1x to 16x in coarse 1x control steps. |
| `V4L2_CID_RED_BALANCE` | `ov8865_red_balance_configure()` | `0x5018=R[13:6]`, `0x5019=R[5:0]` | CONFIRMED | Per-channel ISP gain in the sensor driver; not advertised as `DIGITAL_GAIN`. |
| `V4L2_CID_BLUE_BALANCE` | `ov8865_blue_balance_configure()` | `0x501c=B[13:6]`, `0x501d=B[5:0]` | CONFIRMED | The green registers `0x501a/0x501b` are defined but have no V4L2 control write path. |
| `V4L2_CID_VBLANK` | `ov8865_vts_configure()` | `VTS=height+VBLANK`; `0x380e=VTS[11:8]`, `0x380f=VTS[7:0]` | CONFIRMED | Exposure maximum is simultaneously changed to `height + VBLANK - 8`. |
| `V4L2_CID_HBLANK` | none (read-only) | No runtime write | CONFIRMED | Value is fixed per mode as `HTS-width`; mode programming writes `0x380c/0x380d`. |
| `V4L2_CID_HFLIP` | `ov8865_flip_horz_configure()` | read/modify/write `0x3821`, bits 2 and 1 | CONFIRMED | Sensor and ISP horizontal flip bits move together. |
| `V4L2_CID_VFLIP` | `ov8865_flip_vert_configure()` | read/modify/write `0x3820`, bits 2 and 1 | CONFIRMED | Sensor and ISP vertical flip bits move together. |
| `V4L2_CID_TEST_PATTERN` | `ov8865_test_pattern_configure()` | `0x5e00` menu encoding | CONFIRMED | Disabled, random, bars, rolling bars, squares, rolling squares. |
| `V4L2_CID_LINK_FREQ` | read-only state calculation | menu value `360000000` Hz | CONFIRMED | Checked against the firmware endpoint link frequency. |
| `V4L2_CID_PIXEL_RATE` | read-only state calculation | `link_freq * 2 * lanes / 10` | CONFIRMED | RAW10 only. For two lanes this is 144 MHz. |

There is no OV8865 `V4L2_CID_DIGITAL_GAIN` control and no group-hold write in this driver. Exposure and analogue gain are therefore separate multi-byte I2C transactions. Whether a frame can observe a partially updated value is **UNKNOWN** without an I2C/frame timing trace.

### Mode programming

| Mode | Output registers | HTS | VTS | Binning/subsample | Extra table |
| --- | --- | ---: | ---: | --- | --- |
| 3264×2448 | `0x3808..0x380b` | 3888 | 2470 | 1×1 | native |
| 3264×1836 | `0x3808..0x380b` | 3888 | 2470 | 1×1 | native |
| 1632×1224 | `0x3808..0x380b` | 1923 | 1248 | Y binning; increments 3/1 | binning |
| 800×600 | `0x3808..0x380b` | 1250 | 640 | Y binning + variopixel; X 3/1, Y 5/3 | binning |

`ov8865_sensor_init()` performs reset, standby, chip-ID check, the global init sequence, charge-pump, MIPI, sensor ISP/BLC, and current-mode programming before stream-on. Mode configuration writes output size, HTS, VTS, automatic crop boundaries, VFIFO, binning, black-level parameters, PLL1/PLL2/SCLK, and a native/binning table. `set_fmt()` only updates driver state; actual I2C mode programming occurs during runtime resume/init. A format change that reaches stream-on without an intervening resume is therefore a verification target, not a proven failure.

### Other important OV8865 registers

| Register | Purpose | Linux usage | Status / notes |
| --- | --- | --- | --- |
| `0x0100` | standby/stream | bit 0 set for stream-on | CONFIRMED |
| `0x0103` | software reset | written during sensor init | CONFIRMED |
| `0x300a..0x300c` | chip ID | expected `00 88 65` | CONFIRMED |
| `0x3018` | MIPI lane count/enable | lane count from fwnode plus enable and an unnamed bit | Lane/enable CONFIRMED; unnamed bit UNKNOWN |
| `0x3022` | MIPI reset/power state | reset-sync bit | LIKELY; upstream symbol is named but public spec was not reviewed |
| `0x3031` | CSI bits per sample | value `10` for RAW10 | CONFIRMED |
| `0x3800..0x3813` | crop/output/offset | explicit when auto-size is disabled; output always written | CONFIRMED |
| `0x380c..0x380f` | line/frame length | HTS/VTS mode and control writes | CONFIRMED |
| `0x3814/0x3815/0x382a/0x382b` | X/Y increments | programmed from mode | CONFIRMED |
| `0x3841..0x3846` | auto-size | auto crop/offset boundaries | LIKELY; source naming only |
| `0x4800..0x4851` | MIPI block | lane selection and timing controls | Mixed: named fields CONFIRMED, unnamed literals UNKNOWN |
| `0x4837` | MIPI PCLK period | hard-coded `0x16` because default caused transmission errors | LIKELY and explicitly uncertain in upstream comment |
| `0x5000..0x5003` | on-sensor ISP enables | BLC/white-balance and related blocks | LIKELY; not the IPU6/Soft ISP |
| `0x5e00` | test pattern | control menu | CONFIRMED |

The driver exposes one source pad, `MEDIA_BUS_FMT_SBGGR10_1X10`, no embedded-metadata pad, and accepts 19.2 or 24 MHz external clock. ACPI bridge data must supply lane count and a 360 MHz link frequency for the current upstream configuration.

## OV5693

### V4L2 controls to I2C writes

| V4L2 control | Driver function | Register(s) and written value | Status | Notes |
| --- | --- | --- | --- | --- |
| `V4L2_CID_EXPOSURE` | `ov5693_s_ctrl()` → `ov5693_exposure_configure()` | 24-bit write at `0x3500`: `(E << 4) & 0x0ffff0` | CONFIRMED | Whole-line V4L2 value converted to 1/16-line representation; range is clamped by V4L2. |
| `V4L2_CID_ANALOGUE_GAIN` | `ov5693_analog_gain_configure()` | 16-bit write at `0x350a`: `(G << 4) & 0x07f0` | CONFIRMED | Control `1..127`; libcamera helper maps real gain as `G/16`. Default code 8 therefore maps to 0.5x, which deserves an actual-register/brightness check even though the conversion is internally consistent. |
| `V4L2_CID_DIGITAL_GAIN` | `ov5693_digital_gain_configure()` | same 12-bit value at `0x3400`, `0x3402`, `0x3404` | CONFIRMED | Control `1..4095`, default `1024`; equal RGB gains. Soft IPA currently adjusts analogue gain, not this control. |
| `V4L2_CID_VBLANK` | `ov5693_vts_configure()` | `VTS=height+VBLANK`, 16-bit write at `0x380e` | CONFIRMED | Exposure maximum changes to `height + VBLANK - 8`. |
| `V4L2_CID_HBLANK` | none (read-only) | no runtime write; mode uses `0x380c=2688` | CONFIRMED | |
| `V4L2_CID_HFLIP` | `ov5693_flip_horz_configure()` | read/modify/write `0x3821`, bits 2 and 1 | CONFIRMED | |
| `V4L2_CID_VFLIP` | `ov5693_flip_vert_configure()` | read/modify/write `0x3820`, bits 6 and 1 | CONFIRMED | |
| `V4L2_CID_TEST_PATTERN` | `ov5693_test_pattern_configure()` | `0x5e00` | CONFIRMED | |
| `V4L2_CID_LINK_FREQ` | read-only | `419200000` Hz | CONFIRMED | Firmware endpoint must contain this value. |
| `V4L2_CID_PIXEL_RATE` | read-only | `167680000` pixels/s | CONFIRMED | Two lanes, RAW10: `419.2M * 2 * 2 / 10`. |

No group-hold write is used. The volatile compatibility reads for `EXPOSURE_ABSOLUTE` and `AUTOGAIN` read sensor state but these are not application-side automatic-control implementations.

### Dynamic mode programming

OV5693 does not use a fixed resolution table. Active crop defaults to `(16,6) 2592×1944` within a 2624×1956 native array. Output is either the crop size or independent 2× binning per axis.

| Register | Programmed value | Status |
| --- | --- | --- |
| `0x3800/0x3802` | crop left/top | CONFIRMED |
| `0x3804/0x3806` | `left+width`, `top+height` | CONFIRMED source behavior; verify end-coordinate convention on hardware |
| `0x3808/0x380a` | output width/height | CONFIRMED |
| `0x380c` | fixed 2688 pixels/line | CONFIRMED |
| `0x380e` | calculated VTS | CONFIRMED |
| `0x3810/0x3812` | zero output offset | CONFIRMED |
| `0x3814/0x3815` | `(odd_increment << 4) | 1` | CONFIRMED |
| `0x3820/0x3821` | vertical/horizontal bin enable | CONFIRMED |

`ov5693_sensor_init()` performs reset, writes the 145-entry global table, programs the current crop/mode, then writes standby. Stream-on in upstream writes only `0x0100=1`. The repository's Surface Go 4 cold-boot validation found that an additional `0x4800=0x2d` immediately before stream-on made frames arrive reliably. This is **CONFIRMED as a repository observation** and **LIKELY Surface-Go-4/IPU6-specific initialization**, but its individual bit meanings remain **UNKNOWN** here.

### Other important OV5693 registers

| Register | Purpose | Linux usage | Status / notes |
| --- | --- | --- | --- |
| `0x0100` | stream | `0x01` on, `0x00` off | CONFIRMED |
| `0x0103` | reset | `0x01` during init | CONFIRMED |
| `0x300a` (16-bit) | chip ID | expected `0x5690` | CONFIRMED; upstream notes datasheet naming |
| `0x3406` | manual WB enable/config | global table `0x01` | LIKELY |
| `0x3503` | manual exposure/gain mode | global table `0x07` | LIKELY |
| `0x481f`, `0x4826`, `0x4837` | MIPI timing | `0x30`, `0x2c`, `0x0a` | LIKELY; exact semantics not established here |
| `0x4800` | MIPI control 00 | absent upstream; experimental `0x2d` before stream-on | Surface result CONFIRMED; bit semantics UNKNOWN |
| `0x5002` | ISP scale enable | defined; no current runtime write | LIKELY |
| `0x5e00` | test pattern | V4L2 menu | CONFIRMED |

The driver supports only two CSI-2 lanes, RAW10 SBGGR, 19.2 MHz external clock, and a 419.2 MHz endpoint link frequency. It has no embedded-metadata pad.

## DW9714 focus actuator

DW9714 is a separate I2C V4L2 subdevice, not part of either sensor register map.

| V4L2 control | Driver function | I2C payload | Status |
| --- | --- | --- | --- |
| `V4L2_CID_FOCUS_ABSOLUTE` (`0..1023`) | `dw9714_set_ctrl()` → `dw9714_t_focus_vcm()` | big-endian 16-bit `(position << 4) | 0` | CONFIRMED |

Power-up enables `vcc`, deasserts optional powerdown GPIO, and waits 12–14 ms. Runtime suspend walks the lens down in steps of 16 before power-off; resume walks back to the cached position. There is no `FOCUS_AUTO` or continuous-AF control in this kernel driver. Automatic focus requires a userspace AF algorithm to drive `FOCUS_ABSOLUTE` through a pipeline handler that exposes the lens.

On the tested Surface Go 4, ACPI SSDB identifies a VCM and `ipu-bridge` creates a `lens-focus` software-node reference. The I2C device binds as `dw9714 4-000c`, but the repository records no `/dev/v4l-subdev*` node for that lens, so libcamera cannot open it.
