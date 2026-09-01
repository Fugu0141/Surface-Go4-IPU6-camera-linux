#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/00-baseline/23-mok-preflight.txt"
MOK_DIR="$HOME/sg4-ov5693-mok"
MOK_PRIV="$MOK_DIR/MOK.priv"
MOK_DER="$MOK_DIR/MOK.der"
SIGN_FILE="/usr/src/linux-headers-$(uname -r)/scripts/sign-file"

mkdir -p "$(dirname "$OUT")"

{
    echo "Collected: $(date --iso-8601=seconds)"
    echo "Purpose: Verify whether the previously-created Surface Go 4 MOK can be reused for v4 module signing"
    echo

    echo "===== Secure Boot ====="
    if command -v mokutil >/dev/null 2>&1; then
        mokutil --sb-state || true
    else
        echo "mokutil not installed"
    fi
    echo

    echo "===== Expected MOK paths (contents are NOT printed) ====="
    printf 'MOK_DIR=%s\n' "$MOK_DIR"
    for f in "$MOK_PRIV" "$MOK_DER"; do
        if [ -e "$f" ]; then
            stat -c '%A %U:%G %s bytes %n' "$f" || true
        else
            echo "MISSING: $f"
        fi
    done
    echo

    echo "===== Certificate metadata ====="
    if [ -f "$MOK_DER" ] && command -v openssl >/dev/null 2>&1; then
        openssl x509 -inform DER -in "$MOK_DER" -noout \
            -subject -issuer -serial -dates -fingerprint -sha256 || true
    else
        echo "Certificate or openssl unavailable"
    fi
    echo

    echo "===== Enrollment test ====="
    if [ -f "$MOK_DER" ] && command -v mokutil >/dev/null 2>&1; then
        mokutil --test-key "$MOK_DER" || true
    else
        echo "Cannot run mokutil --test-key"
    fi
    echo

    echo "===== Private key / certificate public-key match ====="
    if [ -f "$MOK_PRIV" ] && [ -f "$MOK_DER" ] && command -v openssl >/dev/null 2>&1; then
        echo -n "private-key public part sha256: "
        openssl pkey -in "$MOK_PRIV" -pubout -outform DER 2>/dev/null | sha256sum || true
        echo -n "certificate public key sha256:  "
        openssl x509 -inform DER -in "$MOK_DER" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum || true
        echo "(The two hashes should match.)"
    else
        echo "Cannot compare key pair"
    fi
    echo

    echo "===== Kernel sign-file helper ====="
    if [ -x "$SIGN_FILE" ]; then
        echo "FOUND executable: $SIGN_FILE"
    elif [ -e "$SIGN_FILE" ]; then
        echo "FOUND but not executable: $SIGN_FILE"
    else
        echo "MISSING: $SIGN_FILE"
    fi
    echo

    echo "===== Current OV5693 module signature ====="
    modinfo ov5693 2>&1 | grep -E '^(filename|srcversion|vermagic|sig_id|signer|sig_key|sig_hashalgo):' || true
    echo

    echo "===== Boot log evidence for old local certificate ====="
    if dmesg -T >/tmp/sg4-mok-dmesg.$$ 2>/dev/null; then
        grep -i -E 'Surface Go 4 ov5693 local test|X\.509|MOK' /tmp/sg4-mok-dmesg.$$ || true
        rm -f /tmp/sg4-mok-dmesg.$$
    else
        sudo dmesg -T 2>/dev/null | grep -i -E 'Surface Go 4 ov5693 local test|X\.509|MOK' || true
    fi
    echo

    echo "===== Result hints ====="
    echo "Reusable without MOK re-enrollment if all are true:"
    echo "- MOK.priv exists"
    echo "- MOK.der exists"
    echo "- mokutil --test-key reports that the key is already enrolled"
    echo "- the two public-key hashes match"
    echo "- sign-file exists"
} >"$OUT" 2>&1

echo "MOK preflight log written to: $OUT"
echo "Do NOT upload MOK.priv or any private key file to GitHub."
