#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$ROOT/01-v4-unmodified/stack-build"
KVER="$(uname -r)"
KBUILD="/lib/modules/$KVER/build"
SRC="$HOME/sg4-ov5693-v4-ubuntu-$KVER/source/linux-source-7.0.0"
WORK="$HOME/sg4-ov5693-v4-stack-$KVER"
STACK="$WORK/stack"
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
[ -d "$SRC/drivers/media/pci/intel/ipu6" ] || fail "IPU6 source directory missing"
[ -f "$MOK_PRIV" ] || fail "MOK private key missing"
[ -f "$MOK_DER" ] || fail "MOK certificate missing"
[ -x "$SIGN_FILE" ] || fail "sign-file missing"

if [ -e "$WORK" ]; then
    fail "work directory already exists: $WORK (move/remove deliberately before rerunning)"
fi

mkdir -p "$STACK/ipu6" "$STACK/include/media"

# Inputs: v4-patched bridge + sensor, stock Ubuntu IPU6 sources from the exact
# 7.0.0-30.30 source package, and the v4-patched bridge header.
cp "$SRC/drivers/media/i2c/ov5693.c" "$STACK/ov5693.c"
cp "$SRC/drivers/media/pci/intel/ipu-bridge.c" "$STACK/ipu-bridge.c"
cp -a "$SRC/drivers/media/pci/intel/ipu6/." "$STACK/ipu6/"
cp "$SRC/include/media/ipu-bridge.h" "$STACK/include/media/ipu-bridge.h"
cp "$SRC/include/media/ipu6-pci-table.h" "$STACK/include/media/ipu6-pci-table.h"

cat > "$STACK/Makefile" <<'EOF'
# Unified external-module build for the Surface Go 4 OV5693 v4 test.
# Force the v4 ipu-bridge header before the packaged kernel header so all
# modules are generated with one CONFIG_MODVERSIONS view.
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
    echo "Purpose: unified build of the v4-unmodified negative-control camera stack"
    echo "Kernel: $KVER"
    echo "Kernel package: $(dpkg-query -W -f='${Version}' linux-image-$KVER 2>/dev/null || true)"
    echo "Source package: $(dpkg-query -W -f='${Version}' linux-source-7.0.0 2>/dev/null || true)"
    echo "Patched source: $SRC"
    echo "Build tree: $STACK"
    echo "No modules are installed or loaded by this script."
} > "$STAGE/00-metadata.txt"

{
    echo "===== key build inputs ====="
    sha256sum \
        "$STACK/ov5693.c" \
        "$STACK/ipu-bridge.c" \
        "$STACK/include/media/ipu-bridge.h" \
        "$STACK/include/media/ipu6-pci-table.h" \
        "$STACK/Makefile"
    echo
    echo "===== IPU6 source tree hash list ====="
    find "$STACK/ipu6" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum
} > "$STAGE/01-input-sha256.txt"

{
    echo '$ make -C '"$KBUILD"' M='"$STACK"' modules -j'"$(nproc)"
    make -C "$KBUILD" M="$STACK" modules -j"$(nproc)"
} > "$STAGE/02-build.txt" 2>&1

for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
    [ -f "$STACK/$mod" ] || fail "$mod was not produced"
done

# Prove the v4 header was injected into all compilation units.
{
    echo "===== forced v4 header evidence ====="
    grep -Rho -- '-include [^ ]*include/media/ipu-bridge.h' "$STACK"/.*.cmd "$STACK"/ipu6/.*.cmd 2>/dev/null | sort -u || true
    echo
    echo "===== v4-only definitions present ====="
    grep -nE 'IPU_SENSOR_CONFIG_MATCH_FL|IPU_BR_FL_CSI2_CLK_NONCONTINUOUS|pci_id|flags' "$STACK/include/media/ipu-bridge.h" || true
} > "$STAGE/03-header-proof.txt"

# The single Module.symvers is important: bridge exports and IPU6 imports were
# resolved by the same modpost run.
{
    echo "===== unified Module.symvers: bridge symbols ====="
    grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$STACK/Module.symvers" || true
    echo
    echo "===== stock kernel Module.symvers: bridge symbols ====="
    grep -E '[[:space:]]ipu_bridge_(init|parse_ssdb|instantiate_vcm)[[:space:]]' "$KBUILD/Module.symvers" || true
    echo
    echo "===== unified IPU6 exported symbols ====="
    grep -E '[[:space:]]intel_ipu6' "$STACK/Module.symvers" | head -n 120 || true
} > "$STAGE/04-unified-symbols.txt"

# Sign all modules from the same unified build.
for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
    "$SIGN_FILE" sha256 "$MOK_PRIV" "$MOK_DER" "$STACK/$mod"
done

{
    for mod in ov5693.ko ipu-bridge.ko intel-ipu6.ko intel-ipu6-isys.ko; do
        echo "===== $mod ====="
        modinfo "$STACK/$mod"
        echo
    done
} > "$STAGE/05-modinfo-signed.txt"

{
    echo "===== signed artifact hashes ====="
    sha256sum "$STACK/ov5693.ko" "$STACK/ipu-bridge.ko" "$STACK/intel-ipu6.ko" "$STACK/intel-ipu6-isys.ko"
    echo
    echo "===== certificate ====="
    openssl x509 -inform DER -in "$MOK_DER" -noout -subject -fingerprint -sha256
    echo
    echo "===== enrollment ====="
    mokutil --test-key "$MOK_DER" || true
} > "$STAGE/06-signature-and-hashes.txt" 2>&1

{
    echo "===== imported bridge symbols in intel-ipu6 ====="
    nm -u "$STACK/intel-ipu6.ko" 2>/dev/null | grep -E 'ipu_bridge_' || true
    echo
    echo "===== imported intel_ipu6 symbols in intel-ipu6-isys ====="
    nm -u "$STACK/intel-ipu6-isys.ko" 2>/dev/null | grep -E 'ipu6|intel_ipu6' | head -n 200 || true
} > "$STAGE/07-imported-symbols.txt"

{
    echo "===== current installed paths ====="
    for mod in ov5693 ipu_bridge intel_ipu6 intel_ipu6_isys; do
        printf '%s=' "$mod"
        modinfo -n "$mod" 2>/dev/null || true
    done
    echo
    echo "===== currently loaded ====="
    lsmod | grep -E '^(ov5693|ipu_bridge|intel_ipu6|intel_ipu6_isys)[[:space:]]' || true
} > "$STAGE/08-current-system-state.txt"

cat > "$STAGE/README.md" <<EOF
# Unified v4 negative-control stack build

The following four modules were built in one external Kbuild/modpost run so their CONFIG_MODVERSIONS symbol CRCs are internally consistent:

- ov5693.ko
- ipu-bridge.ko
- intel-ipu6.ko
- intel-ipu6-isys.ko

The bridge and OV5693 contain the upstream v4 semantics (with the documented Ubuntu context-only backport for patch 2). The IPU6 sources are otherwise the stock Ubuntu 7.0.0-30.30 sources. All four modules are signed with the already-enrolled Surface Go 4 local MOK.

This script does not install, load, unload, or copy modules into /lib/modules and does not update initramfs.
EOF

echo "Unified stack build and signing complete; nothing was installed."
echo "Logs: $STAGE"
echo "Artifacts: $STACK/{ov5693.ko,ipu-bridge.ko,intel-ipu6.ko,intel-ipu6-isys.ko}"
echo "Next: inspect 02-build.txt, 03-header-proof.txt, 04-unified-symbols.txt, and 05-modinfo-signed.txt."
