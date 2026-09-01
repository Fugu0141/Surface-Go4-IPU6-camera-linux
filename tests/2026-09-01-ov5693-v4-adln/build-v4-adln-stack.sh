#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/02-v4-adln/stack-build-r2"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SRC="$HOME/sg4-ov5693-v4-ubuntu-$KVER/source/linux-source-7.0.0"
WORK="$HOME/sg4-ov5693-v4-adln-stack-r2-$KVER"
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
[ -f "$SRC/drivers/media/i2c/ov5693.c" ] || fail "v4 OV5693 source missing"
[ -f "$SRC/drivers/media/pci/intel/ipu-bridge.c" ] || fail "v4 ipu-bridge source missing"
[ -f "$SRC/include/media/ipu-bridge.h" ] || fail "v4 ipu-bridge header missing"
[ -f "$SRC/include/media/ipu6-pci-table.h" ] || fail "IPU6 PCI table header missing"
[ -d "$SRC/drivers/media/pci/intel/ipu6" ] || fail "IPU6 source directory missing"
[ -f "$MOK_PRIV" ] || fail "MOK private key missing"
[ -f "$MOK_DER" ] || fail "MOK certificate missing"
[ -x "$SIGN_FILE" ] || fail "sign-file missing"

if [ -e "$WORK" ]; then
    fail "r2 work directory already exists: $WORK (move/remove deliberately before rerunning)"
fi

mkdir -p "$STACK/ipu6" "$STACK/include/media"

# Start from the exact v4 semantic-backport source used for the negative control.
# Modify only the copied ipu-bridge.c; the preserved v4 source tree is untouched.
cp "$SRC/drivers/media/i2c/ov5693.c" "$STACK/ov5693.c"
cp "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$STACK/ipu-bridge.c"
cp -a "$SRC/drivers/media/pci/intel/ipu6/." "$STACK/ipu6/"
cp "$SRC/include/media/ipu-bridge.h" "$STACK/include/media/ipu-bridge.h"
cp "$SRC/include/media/ipu6-pci-table.h" "$STACK/include/media/ipu6-pci-table.h"
cp "$STACK/ipu-bridge.c" "$STAGE/ipu-bridge.before.c"

# Insert exactly one Surface Go 4 / Alder Lake-N match immediately after the
# existing INT33BE Alder Lake-P match. Horizontal whitespace is deliberately
# used for indentation matching; \s would also consume newlines in Python.
python3 - "$STACK/ipu-bridge.c" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

adln_re = re.compile(
    r'IPU_SENSOR_CONFIG_MATCH_FL\(\s*"INT33BE"\s*,\s*'
    r'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN\s*,\s*'
    r'CSI2_CLK_NONCONTINUOUS\s*,\s*1\s*,\s*419200000\s*\),'
)
if adln_re.search(text):
    raise SystemExit('ADL-N INT33BE match already exists; refusing duplicate insertion')

pattern = re.compile(
    r'(?m)^([ \t]*)IPU_SENSOR_CONFIG_MATCH_FL\(\s*"INT33BE"\s*,\s*'
    r'PCI_DEVICE_ID_INTEL_IPU6EP_ADLP\s*,\s*'
    r'CSI2_CLK_NONCONTINUOUS\s*,\s*1\s*,\s*419200000\s*\),'
)

matches = list(pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(f'expected exactly one INT33BE ADLP v4 match, found {len(matches)}')

m = matches[0]
indent = m.group(1)
addition = (
    '\n'
    f'{indent}IPU_SENSOR_CONFIG_MATCH_FL("INT33BE", PCI_DEVICE_ID_INTEL_IPU6EP_ADLN,\n'
    f'{indent}\t\t\t   CSI2_CLK_NONCONTINUOUS, 1, 419200000),'
)
text = text[:m.end()] + addition + text[m.end():]
path.write_text(text)

# Semantic validation is whitespace-insensitive, but values must match exactly.
matches = adln_re.findall(text)
if len(matches) != 1:
    raise SystemExit(f'expected one exact ADL-N semantic match after insertion, found {len(matches)}')
PY

# Prove the intended delta before building.
python3 - "$STAGE/ipu-bridge.before.c" "$STACK/ipu-bridge.c" > "$STAGE/00-source-delta.diff" <<'PY'
from pathlib import Path
import difflib
import sys

before = Path(sys.argv[1]).read_text().splitlines(keepends=True)
after = Path(sys.argv[2]).read_text().splitlines(keepends=True)
sys.stdout.writelines(difflib.unified_diff(before, after, fromfile='ipu-bridge.v4-unmodified.c', tofile='ipu-bridge.v4-adln.c'))
PY

# Independently prove that the only semantic ADL-N INT33BE entry has the exact
# requested flag, lane count and link frequency. Do not depend on line wrapping.
python3 - "$STACK/ipu-bridge.c" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
exact = re.compile(
    r'IPU_SENSOR_CONFIG_MATCH_FL\(\s*"INT33BE"\s*,\s*'
    r'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN\s*,\s*'
    r'CSI2_CLK_NONCONTINUOUS\s*,\s*1\s*,\s*419200000\s*\),'
)
all_adln = re.findall(
    r'IPU_SENSOR_CONFIG_MATCH_FL\(\s*"INT33BE"\s*,\s*PCI_DEVICE_ID_INTEL_IPU6EP_ADLN\b',
    text,
)
if len(all_adln) != 1:
    raise SystemExit(f'expected exactly one INT33BE ADL-N entry, found {len(all_adln)}')
if len(exact.findall(text)) != 1:
    raise SystemExit('ADL-N match has unexpected flags/lanes/link-frequency')
PY

cat > "$STACK/Makefile" <<'EOF'
# Unified external-module build for Surface Go 4 OV5693 v4 + ADL-N match test.
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
    echo "Purpose: build v4 semantics plus exactly one INT33BE Alder Lake-N bridge match"
    echo "Kernel: $KVER"
    echo "Kernel package: $(dpkg-query -W -f='${Version}' linux-image-$KVER 2>/dev/null || true)"
    echo "Source package: $(dpkg-query -W -f='${Version}' linux-source-7.0.0 2>/dev/null || true)"
    echo "Preserved v4 source: $SRC"
    echo "Isolated build tree: $STACK"
    echo "Functional delta: INT33BE + PCI_DEVICE_ID_INTEL_IPU6EP_ADLN + CSI2_CLK_NONCONTINUOUS + 1 lane + 419200000"
    echo "No modules are installed or loaded by this script."
} > "$STAGE/01-metadata.txt"

{
    echo "===== exact ADL-N entry ====="
    grep -n -A2 -B2 -F 'IPU_SENSOR_CONFIG_MATCH_FL("INT33BE", PCI_DEVICE_ID_INTEL_IPU6EP_ADLN,' "$STACK/ipu-bridge.c"
    echo
    echo "===== nearby INT33BE entries ====="
    grep -n -A2 -B1 'INT33BE' "$STACK/ipu-bridge.c" || true
    echo
    echo "===== PCI ID definition ====="
    grep -n 'PCI_DEVICE_ID_INTEL_IPU6EP_ADLN' "$STACK/include/media/ipu6-pci-table.h" || true
} > "$STAGE/02-adln-proof.txt"

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

# Sign every module in this unified stack using the already enrolled test MOK.
for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$STACK/$mod"
done

{
    echo "===== unified Module.symvers: bridge symbols ====="
    grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$STACK/Module.symvers" || true
    echo
    echo "===== forced v4 header evidence ====="
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
    echo "===== signed artifact hashes ====="
    sha256sum "$STACK/ov5693.ko" "$STACK/ipu-bridge.ko" "$STACK/intel-ipu6.ko" "$STACK/intel-ipu6-isys.ko"
    echo
    echo "===== certificate ====="
    openssl x509 -inform DER -in "$MOK_DER" -noout -subject -fingerprint -sha256
    echo
    echo "===== enrollment ====="
    mokutil --test-key "$MOK_DER" || true
} > "$STAGE/07-signature-and-hashes.txt" 2>&1

cat > "$STAGE/README.md" <<EOF
# v4 + Alder Lake-N isolated stack build (r2)

This build starts from the exact v4 semantic-backport source used by the negative control and changes only a copied \`ipu-bridge.c\` by adding:

\`IPU_SENSOR_CONFIG_MATCH_FL("INT33BE", PCI_DEVICE_ID_INTEL_IPU6EP_ADLN, CSI2_CLK_NONCONTINUOUS, 1, 419200000)\`

The preserved v4 source tree is not modified. All four modules are rebuilt together and signed, but this script does not install or load them.
EOF

echo "v4 + ADL-N stack build and signing complete; nothing was installed."
echo "Logs: $STAGE"
echo "Artifacts: $STACK/{ov5693.ko,ipu-bridge.ko,intel-ipu6.ko,intel-ipu6-isys.ko}"
echo "Inspect 00-source-delta.diff, 02-adln-proof.txt, 04-build.txt, and 06-modinfo-signed.txt before installation."
