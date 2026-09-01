#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/build"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SRC="$HOME/sg4-ov5693-v4-ubuntu-$KVER/source/linux-source-7.0.0"
WORK="$HOME/sg4-ov5693-v4-build-$KVER"
OV_BUILD="$WORK/ov5693"
IPU_BUILD="$WORK/ipu-bridge"
MOK_PRIV="$HOME/sg4-ov5693-test/mok/MOK.priv"
MOK_DER="$HOME/sg4-ov5693-test/mok/MOK.der"
SIGN_FILE="/usr/src/linux-headers-$KVER/scripts/sign-file"

mkdir -p "$STAGE"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error.txt" >&2
    exit 1
}

[ -d "$KBUILD" ] || fail "kernel build directory missing: $KBUILD"
[ -f "$SRC/drivers/media/i2c/ov5693.c" ] || fail "patched ov5693 source missing"
[ -f "$SRC/drivers/media/pci/intel/ipu-bridge.c" ] || fail "patched ipu-bridge source missing"
[ -f "$SRC/include/media/ipu-bridge.h" ] || fail "patched ipu-bridge header missing"
[ -f "$SRC/include/media/ipu6-pci-table.h" ] || fail "ipu6 PCI table header missing"
[ -f "$MOK_PRIV" ] || fail "MOK private key missing: $MOK_PRIV"
[ -f "$MOK_DER" ] || fail "MOK certificate missing: $MOK_DER"
[ -x "$SIGN_FILE" ] || fail "kernel sign-file helper missing: $SIGN_FILE"

if [ -e "$WORK" ]; then
    fail "build work directory already exists: $WORK (move/remove it deliberately before rerunning)"
fi

mkdir -p "$OV_BUILD" "$IPU_BUILD/include/media"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Build and sign the Surface Go 4 v4-unmodified negative-control modules without installing them"
    echo "Kernel: $KVER"
    echo "Kernel build: $KBUILD"
    echo "Patched source: $SRC"
    echo "Build work: $WORK"
} > "$STAGE/00-metadata.txt"

# Keep the build inputs auditable.
cp "$SRC/drivers/media/i2c/ov5693.c" "$OV_BUILD/ov5693.c"
printf 'obj-m += ov5693.o\n' > "$OV_BUILD/Makefile"

cp "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$IPU_BUILD/ipu-bridge.c"
cp "$SRC/include/media/ipu-bridge.h" "$IPU_BUILD/include/media/ipu-bridge.h"
cp "$SRC/include/media/ipu6-pci-table.h" "$IPU_BUILD/include/media/ipu6-pci-table.h"
cat > "$IPU_BUILD/Makefile" <<'EOF'
ccflags-y += -I$(src)/include
obj-m += ipu-bridge.o
EOF

{
    echo "===== ov5693 input ====="
    sha256sum "$OV_BUILD/ov5693.c" "$OV_BUILD/Makefile"
    echo
    echo "===== ipu_bridge inputs ====="
    sha256sum \
        "$IPU_BUILD/ipu-bridge.c" \
        "$IPU_BUILD/include/media/ipu-bridge.h" \
        "$IPU_BUILD/include/media/ipu6-pci-table.h" \
        "$IPU_BUILD/Makefile"
} > "$STAGE/01-build-input-sha256.txt"

{
    echo '$ make -C '"$KBUILD"' M='"$OV_BUILD"' modules -j'"$(nproc)"
    make -C "$KBUILD" M="$OV_BUILD" modules -j"$(nproc)"
} > "$STAGE/02-build-ov5693.txt" 2>&1

{
    echo '$ make -C '"$KBUILD"' M='"$IPU_BUILD"' modules -j'"$(nproc)"
    make -C "$KBUILD" M="$IPU_BUILD" modules -j"$(nproc)"
} > "$STAGE/03-build-ipu-bridge.txt" 2>&1

[ -f "$OV_BUILD/ov5693.ko" ] || fail "ov5693.ko was not produced"
[ -f "$IPU_BUILD/ipu-bridge.ko" ] || fail "ipu-bridge.ko was not produced"

# Compare exported-symbol CRCs against the stock kernel Module.symvers.
# If these change, already-built intel_ipu6 may reject the new bridge under CONFIG_MODVERSIONS.
{
    echo "===== stock kernel CRCs ====="
    if [ -f "$KBUILD/Module.symvers" ]; then
        grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$KBUILD/Module.symvers" || true
    else
        echo "MISSING: $KBUILD/Module.symvers"
    fi
    echo
    echo "===== rebuilt ipu_bridge CRCs ====="
    if [ -f "$IPU_BUILD/Module.symvers" ]; then
        grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$IPU_BUILD/Module.symvers" || true
    else
        echo "MISSING: $IPU_BUILD/Module.symvers"
    fi
} > "$STAGE/04-symbol-crcs.txt"

# Sign only the local build artifacts; nothing is installed by this script.
"$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$OV_BUILD/ov5693.ko"
"$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$IPU_BUILD/ipu-bridge.ko"

{
    echo "===== ov5693 ====="
    modinfo "$OV_BUILD/ov5693.ko"
    echo
    echo "===== ipu_bridge ====="
    modinfo "$IPU_BUILD/ipu-bridge.ko"
} > "$STAGE/05-modinfo-signed.txt"

{
    echo "===== build artifact hashes ====="
    sha256sum "$OV_BUILD/ov5693.ko" "$IPU_BUILD/ipu-bridge.ko"
    echo
    echo "===== expected signer ====="
    openssl x509 -inform DER -in "$MOK_DER" -noout -subject -fingerprint -sha256
    echo
    echo "===== MOK enrollment ====="
    mokutil --test-key "$MOK_DER" || true
} > "$STAGE/06-signature-and-hashes.txt" 2>&1

{
    echo "===== unresolved/imported symbols: ov5693 ====="
    nm -u "$OV_BUILD/ov5693.ko" 2>/dev/null || true
    echo
    echo "===== unresolved/imported symbols: ipu_bridge ====="
    nm -u "$IPU_BUILD/ipu-bridge.ko" 2>/dev/null || true
} > "$STAGE/07-imported-symbols.txt"

{
    echo "===== current installed module resolution ====="
    echo "ov5693=$(modinfo -n ov5693 2>/dev/null || true)"
    echo "ipu_bridge=$(modinfo -n ipu_bridge 2>/dev/null || true)"
    echo "intel_ipu6=$(modinfo -n intel_ipu6 2>/dev/null || true)"
    echo
    echo "===== currently loaded ====="
    lsmod | grep -E '^(ov5693|ipu_bridge|intel_ipu6|intel_ipu6_isys)[[:space:]]' || true
} > "$STAGE/08-current-system-state.txt"

# Machine-readable summary. Do not claim CRC compatibility unless both sets can be compared.
python3 - "$KBUILD/Module.symvers" "$IPU_BUILD/Module.symvers" "$STAGE/09-crc-comparison.txt" <<'PY'
import sys
from pathlib import Path

stock_path, new_path, out_path = map(Path, sys.argv[1:])
names = {"ipu_bridge_init", "ipu_bridge_parse_ssdb", "ipu_bridge_instantiate_vcm"}

def read(path):
    result = {}
    if not path.exists():
        return result
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] in names:
            result[parts[1]] = parts[0]
    return result

stock = read(stock_path)
new = read(new_path)
with out_path.open("w") as f:
    f.write("symbol\tstock\trebuilt\tmatch\n")
    all_ok = True
    comparable = False
    for name in sorted(names):
        s = stock.get(name, "MISSING")
        n = new.get(name, "MISSING")
        match = s != "MISSING" and n != "MISSING" and s == n
        if s != "MISSING" and n != "MISSING":
            comparable = True
        if s != "MISSING" and n != "MISSING" and not match:
            all_ok = False
        f.write(f"{name}\t{s}\t{n}\t{'YES' if match else 'NO'}\n")
    f.write("\n")
    if not comparable:
        f.write("RESULT=INCONCLUSIVE\n")
    elif all_ok:
        f.write("RESULT=CRC_MATCH_FOR_COMPARABLE_SYMBOLS\n")
    else:
        f.write("RESULT=CRC_MISMATCH_REBUILD_IPU6_REQUIRED\n")
PY

cat > "$STAGE/README.md" <<EOF
# v4 unmodified module build

Build-only stage for the Surface Go 4 negative-control test.

Built from the Ubuntu 7.0.0-30.30 source tree carrying the v4 semantics and the documented minimal Ubuntu context backport for patch 2.

Artifacts:

- \`$OV_BUILD/ov5693.ko\`
- \`$IPU_BUILD/ipu-bridge.ko\`

Both artifacts are signed with the already-enrolled local Surface Go 4 MOK key. This script does **not** install, load, replace, or copy anything into \`/lib/modules\`, and it does not modify initramfs.

Before installation, inspect \`09-crc-comparison.txt\`. A CRC mismatch means the existing \`intel_ipu6\` module must not be mixed with this bridge build and the IPU6 side must be rebuilt consistently.
EOF

echo "Build and signing complete; nothing was installed."
echo "Logs: $STAGE"
echo "Artifacts:"
echo "  $OV_BUILD/ov5693.ko"
echo "  $IPU_BUILD/ipu-bridge.ko"
echo "Next: inspect 04-symbol-crcs.txt, 05-modinfo-signed.txt, and 09-crc-comparison.txt."
