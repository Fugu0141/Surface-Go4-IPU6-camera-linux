#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/07-v5-binning-build"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SRC="$HOME/sg4-ov5693-v5-binning-ubuntu-$KVER/source/linux-source-7.0.0"
WORK="$HOME/sg4-ov5693-v5-binning-stack-$KVER"
STACK="$WORK/stack"
MOK_PRIV="$HOME/sg4-ov5693-test/mok/MOK.priv"
MOK_DER="$HOME/sg4-ov5693-test/mok/MOK.der"
SIGN_FILE="/usr/src/linux-headers-$KVER/scripts/sign-file"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ "$KVER" = "7.0.0-30-generic" ] || fail "unexpected running kernel: $KVER"
[ -d "$KBUILD" ] || fail "kernel build directory missing: $KBUILD"
[ -f "$SRC/drivers/media/i2c/ov5693.c" ] || fail "prepared v5+binning OV5693 source missing; run prepare-v5-binning.sh first"
[ -f "$SRC/drivers/media/pci/intel/ipu-bridge.c" ] || fail "prepared ipu-bridge source missing"
[ -f "$SRC/include/media/ipu-bridge.h" ] || fail "prepared ipu-bridge header missing"
[ -f "$SRC/include/media/ipu6-pci-table.h" ] || fail "IPU6 PCI table header missing"
[ -d "$SRC/drivers/media/pci/intel/ipu6" ] || fail "IPU6 source directory missing"
[ -f "$MOK_PRIV" ] || fail "MOK private key missing"
[ -f "$MOK_DER" ] || fail "MOK certificate missing"
[ -x "$SIGN_FILE" ] || fail "sign-file missing"

if [ -e "$WORK" ]; then
    fail "work directory already exists: $WORK (move/remove it deliberately before rerunning)"
fi

mkdir -p "$STACK/ipu6" "$STACK/include/media"

cp "$SRC/drivers/media/i2c/ov5693.c" "$STACK/ov5693.c"
cp "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$STACK/ipu-bridge.c"
cp -a "$SRC/drivers/media/pci/intel/ipu6/." "$STACK/ipu6/"
cp "$SRC/include/media/ipu-bridge.h" "$STACK/include/media/ipu-bridge.h"
cp "$SRC/include/media/ipu6-pci-table.h" "$STACK/include/media/ipu6-pci-table.h"

cat > "$STACK/Makefile" <<'EOF'
# Unified external-module build for Surface Go 4 OV5693 v5 + 2x2-binning test.
# Build the bridge and IPU6 modules together because v5 changes bridge symbols
# and CONFIG_MODVERSIONS is enabled on Ubuntu's kernel.
ccflags-y += -I$(src)/include
ccflags-y += -include $(src)/include/media/ipu-bridge.h

obj-m += ov5693.o
obj-m += ipu-bridge.o

intel-ipu6-y := \
	ipu6/ipu6.o \
	ipu6/ipu6-bus.o \
	ipu6/ipu6-dma.o \
	ipu6/ipu6-mmu.o \
	ipu6/ipu6-buttress.o \
	ipu6/ipu6-cpd.o \
	ipu6/ipu6-fw-com.o
obj-m += intel-ipu6.o

intel-ipu6-isys-y := \
	ipu6/ipu6-isys.o \
	ipu6/ipu6-isys-csi2.o \
	ipu6/ipu6-fw-isys.o \
	ipu6/ipu6-isys-video.o \
	ipu6/ipu6-isys-queue.o \
	ipu6/ipu6-isys-subdev.o \
	ipu6/ipu6-isys-mcd-phy.o \
	ipu6/ipu6-isys-jsl-phy.o \
	ipu6/ipu6-isys-dwc-phy.o
obj-m += intel-ipu6-isys.o
EOF

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: unified external-module build for Fernando v5 + D. Manresa no-MIPI_CTRL binning patch"
    echo "Kernel: $KVER"
    echo "Kernel package: $(dpkg-query -W -f='${Version}' linux-image-$KVER 2>/dev/null || true)"
    echo "Source package: $(dpkg-query -W -f='${Version}' linux-source-7.0.0 2>/dev/null || true)"
    echo "Prepared source: $SRC"
    echo "Build tree: $STACK"
    echo "No modules are installed or loaded by this script."
} > "$STAGE/00-metadata.txt"

{
    echo "===== expected source features ====="
    grep -n -E 'binned_y_offset|ov5693_mode_binned_regs|MIPI_CTRL00|NONCONTINUOUS_CLOCK' "$STACK/ov5693.c" || true
    echo
    echo "===== ADL-N bridge entry ====="
    grep -n -A4 -B3 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' "$STACK/ipu-bridge.c" || true
    echo
    echo "===== clock-noncontinuous property ====="
    grep -n -A3 -B3 'clock-noncontinuous' "$STACK/ipu-bridge.c" || true
} > "$STAGE/01-source-proof.txt"

python3 - "$STACK/ov5693.c" "$STACK/ipu-bridge.c" <<'PY' > "$STAGE/02-prebuild-checks.txt"
from pathlib import Path
import sys
ov = Path(sys.argv[1]).read_text()
br = Path(sys.argv[2]).read_text()
checks = {
    'binned_y_offset parameter source': 'binned_y_offset' in ov,
    'binned register table': 'ov5693_mode_binned_regs' in ov,
    'MIPI non-continuous gate logic': 'NONCONTINUOUS_CLOCK' in ov and 'MIPI_CTRL00' in ov,
    'ADL-N bridge match': 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' in br,
    'clock-noncontinuous property': 'clock-noncontinuous' in br,
}
for name, ok in checks.items():
    print(f'{name}: {"PASS" if ok else "FAIL"}')
if not all(checks.values()):
    raise SystemExit(1)
PY

{
    echo "===== build inputs ====="
    sha256sum \
        "$STACK/ov5693.c" \
        "$STACK/ipu-bridge.c" \
        "$STACK/include/media/ipu-bridge.h" \
        "$STACK/include/media/ipu6-pci-table.h" \
        "$STACK/Makefile"
} > "$STAGE/03-input-sha256.txt"

{
    echo '$ make -C '"$KBUILD"' M='"$STACK"' modules -j'"$(nproc)"
    make -C "$KBUILD" M="$STACK" modules -j"$(nproc)"
} > "$STAGE/04-build.txt" 2>&1

for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
    [ -f "$STACK/$mod" ] || fail "$mod was not produced"
done

for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$STACK/$mod"
done

{
    echo "===== unified Module.symvers bridge symbols ====="
    grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$STACK/Module.symvers" || true
    echo
    echo "===== forced local ipu-bridge header evidence ====="
    grep -Rho -- '-include [^ ]*include/media/ipu-bridge.h' "$STACK"/.*.cmd "$STACK"/ipu6/.*.cmd 2>/dev/null | sort -u || true
} > "$STAGE/05-unified-proof.txt"

{
    for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
        echo "===== $mod ====="
        modinfo "$STACK/$mod"
        echo
    done
} > "$STAGE/06-modinfo-signed.txt"

{
    echo "===== OV5693 module parameters ====="
    modinfo -p "$STACK/ov5693.ko" || true
    echo
    echo "Expected: binned_y_offset should be present."
} > "$STAGE/07-ov5693-params.txt"

if ! grep -q 'binned_y_offset' "$STAGE/07-ov5693-params.txt"; then
    fail "built ov5693.ko does not expose binned_y_offset"
fi

{
    echo "===== signed artifact hashes ====="
    sha256sum "$STACK/ov5693.ko" "$STACK/ipu-bridge.ko" "$STACK/intel-ipu6.ko" "$STACK/intel-ipu6-isys.ko"
    echo
    echo "===== certificate ====="
    openssl x509 -inform DER -in "$MOK_DER" -noout -subject -fingerprint -sha256
    echo
    echo "===== enrollment ====="
    mokutil --test-key "$MOK_DER" || true
} > "$STAGE/08-signature-and-hashes.txt" 2>&1

cat > "$STAGE/README.md" <<EOF
# v5 + 2x2-binning unified stack build

Built together for Ubuntu \`$KVER\`:

- \`ov5693.ko\` — Fernando v5 clock gate + D. Manresa 2x2-binning patch
- \`ipu-bridge.ko\` — Fernando v5 including the Alder Lake-N OV5693 match
- \`intel-ipu6.ko\`
- \`intel-ipu6-isys.ko\`

All four modules were built in one Kbuild/modpost run and signed with the
already enrolled local test MOK. This script does **not** install or load them.

Artifacts:

\`$STACK/\`

Review \`04-build.txt\`, \`06-modinfo-signed.txt\`, \`07-ov5693-params.txt\`, and
\`08-signature-and-hashes.txt\` before installation.
EOF

echo "v5 + binning unified build and signing complete."
echo "Logs: $STAGE"
echo "Artifacts: $STACK/{ov5693.ko,ipu-bridge.ko,intel-ipu6.ko,intel-ipu6-isys.ko}"
echo "Nothing was installed or loaded."
