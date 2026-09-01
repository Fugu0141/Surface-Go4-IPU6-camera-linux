#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/build"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
WORK="$HOME/sg4-ov5693-v4-build-$KVER"
OV_BUILD="$WORK/ov5693"
IPU_BUILD="$WORK/ipu-bridge"
MOK_PRIV="$HOME/sg4-ov5693-test/mok/MOK.priv"
MOK_DER="$HOME/sg4-ov5693-test/mok/MOK.der"
SIGN_FILE="/usr/src/linux-headers-$KVER/scripts/sign-file"

fail() {
    echo "ERROR: $*" | tee "$STAGE/99-error-resume.txt" >&2
    exit 1
}

[ -f "$OV_BUILD/ov5693.ko" ] || fail "existing ov5693.ko missing: $OV_BUILD/ov5693.ko"
[ -f "$IPU_BUILD/ipu-bridge.c" ] || fail "ipu-bridge.c missing"
[ -f "$IPU_BUILD/include/media/ipu-bridge.h" ] || fail "patched local ipu-bridge.h missing"
[ -f "$MOK_PRIV" ] || fail "MOK private key missing"
[ -f "$MOK_DER" ] || fail "MOK certificate missing"
[ -x "$SIGN_FILE" ] || fail "sign-file helper missing"

# Force-include the patched local header before the Ubuntu packaged header.
# The header guard then prevents the older packaged ipu-bridge.h from replacing it.
cat > "$IPU_BUILD/Makefile" <<'EOF'
ccflags-y += -include $(src)/include/media/ipu-bridge.h
obj-m += ipu-bridge.o
EOF

{
    echo "Reason for resume: the first external ipu-bridge build picked the packaged Ubuntu ipu-bridge.h instead of the v4-patched local header."
    echo "Fix: force-include the local patched header via ccflags-y."
    echo
    echo "===== Makefile ====="
    cat "$IPU_BUILD/Makefile"
    echo
    echo "===== patched header v4 definitions ====="
    grep -nE 'IPU_SENSOR_CONFIG_MATCH_FL|CSI2_CLK_NONCONTINUOUS|IPU_NEXT_EP_PROPERTY|IPU_SENSOR_EP_BUS_TYPE|pci_id|flags' \
        "$IPU_BUILD/include/media/ipu-bridge.h" || true
} > "$STAGE/03a-header-fix.txt"

# Remove only generated files from the failed ipu-bridge external build.
make -C "$KBUILD" M="$IPU_BUILD" clean > "$STAGE/03b-clean-ipu-bridge.txt" 2>&1

{
    echo '$ make -C '"$KBUILD"' M='"$IPU_BUILD"' modules -j'"$(nproc)"
    make -C "$KBUILD" M="$IPU_BUILD" modules -j"$(nproc)"
} > "$STAGE/03c-build-ipu-bridge-forced-header.txt" 2>&1

[ -f "$IPU_BUILD/ipu-bridge.ko" ] || fail "ipu-bridge.ko was not produced after header fix"

{
    echo "===== compile command proof ====="
    CMD_FILE="$IPU_BUILD/.ipu-bridge.o.cmd"
    if [ -f "$CMD_FILE" ]; then
        grep -o -- '-include [^ ]*ipu-bridge.h' "$CMD_FILE" || true
    else
        echo "MISSING: $CMD_FILE"
    fi
} > "$STAGE/03d-compile-header-proof.txt"

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

The first ipu-bridge external-module attempt accidentally included Ubuntu's packaged pre-v4 \`ipu-bridge.h\`. The resumed build force-includes the local v4-patched header before the packaged header; this is recorded in \`03a-header-fix.txt\` and \`03d-compile-header-proof.txt\`.

Artifacts:

- \`$OV_BUILD/ov5693.ko\`
- \`$IPU_BUILD/ipu-bridge.ko\`

Both are signed using the already-enrolled Surface Go 4 MOK. Nothing is installed or loaded by this script.
EOF

echo "Resume build complete; nothing was installed."
echo "Logs: $STAGE"
echo "Artifacts:"
echo "  $OV_BUILD/ov5693.ko"
echo "  $IPU_BUILD/ipu-bridge.ko"
echo "Next: inspect 03d-compile-header-proof.txt, 05-modinfo-signed.txt, and 09-crc-comparison.txt."
