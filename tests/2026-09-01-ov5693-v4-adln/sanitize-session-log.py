#!/usr/bin/env python3
"""Create a public-safe copy of the full Surface Go 4 OV5693/IPU6 test session log.

Usage:
    python3 sanitize-session-log.py INPUT.txt [OUTPUT.txt]

The source file is never modified.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def sanitize(text: str) -> str:
    had_final_newline = text.endswith("\n")

    # Shell prompt and local identity.
    text = re.sub(r"ko@ko-Surface-Go-4(?::[^\n$]*)?\$ ?", "$ ", text)
    text = text.replace("/home/ko/", "$HOME/")
    text = text.replace("/home/ko", "$HOME")
    text = text.replace("ko-Surface-Go-4", "<surface-go-4>")

    # Public-key hashes / certificate fingerprints are not secrets, but they
    # unnecessarily fingerprint the test machine and enrolled local MOK.
    text = re.sub(
        r"(?m)^([0-9a-f]{64})\s+-\s*$",
        "<redacted-public-key-sha256>",
        text,
        flags=re.I,
    )
    text = re.sub(
        r"(?m)^sha256 Fingerprint=[0-9A-F:]+$",
        "sha256 Fingerprint=<redacted>",
        text,
    )
    text = text.replace(
        "ec2c57d83eb0128eba3eaa8551eec2462c99183a3c57fd259f5bce7c13e26d64",
        "<redacted-public-key-sha256>",
    )
    text = text.replace(
        "83:50:8F:3E:4B:96:68:7C:7B:2B:DC:0F:5B:33:7C:5D:30:2C:C0:5E:87:5C:DC:2A:D6:C5:D4:84:25:6A:EF:D4",
        "<redacted>",
    )

    # Local MOK entries from the machine trust store. Vendor certificates are
    # intentionally preserved because they describe the normal Secure Boot
    # environment rather than a user-specific local key.
    text = re.sub(
        r"(?m)^.*integrity: Loaded X\.509 cert '(?:ko[^']*|localhost\.localdomain[^']*|Surface Go 4 ov5693 local test[^']*)'.*$",
        "<redacted-local-MOK-certificate-entry>",
        text,
    )
    text = re.sub(
        r"(?m)^.*Loaded X\.509 cert 'Surface Go 4 ov5693 local test:[^']*'.*$",
        "<redacted-local-test-certificate-entry>",
        text,
    )

    # sig_key is public metadata but is not required to reproduce this test.
    text = re.sub(r"(?m)^(sig_key:\s*).+$", r"\1<redacted>", text)

    # Physical EFI addresses vary per boot and add machine-specific noise.
    lines: list[str] = []
    for line in text.splitlines():
        if (
            "efi:" in line
            or "ACPI=" in line
            or "SMBIOS=" in line
            or "TPMFinalLog=" in line
        ):
            line = re.sub(r"0x[0-9a-fA-F]+", "<addr>", line)
        lines.append(line)

    text = "\n".join(lines)
    if had_final_newline:
        text += "\n"

    header = (
        "# Sanitized session log\n"
        "# Source: local Surface Go 4 OV5693/IPU6 v4 + ADL-N validation session\n"
        "# Redactions: local username/hostname, home path, local MOK fingerprints/public-key hashes,\n"
        "# local MOK certificate-list entries, module sig_key values, and EFI physical addresses.\n"
        "# No private-key contents, passwords, API tokens, or SSH private keys were present in the source log.\n\n"
    )
    return header + text


def safety_check(text: str) -> list[str]:
    checks = {
        "private key PEM": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "GitHub token": r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b",
        "AWS access key": r"\bAKIA[0-9A-Z]{16}\b",
        "Bearer credential": r"(?i)authorization:\s*bearer\s+\S+",
        "password/token/secret assignment": r"(?i)\b(?:password|passwd|token|secret)\s*[=:]\s*[^\s]+",
        "raw /home/ko path": r"/home/ko(?:/|\b)",
        "raw local shell prompt": r"ko@ko-Surface-Go-4",
    }
    return [name for name, pattern in checks.items() if re.search(pattern, text)]


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"Usage: {Path(sys.argv[0]).name} INPUT.txt [OUTPUT.txt]", file=sys.stderr)
        return 2

    src = Path(sys.argv[1]).expanduser()
    if len(sys.argv) == 3:
        dst = Path(sys.argv[2]).expanduser()
    else:
        dst = src.with_name(src.stem + "-sanitized" + src.suffix)

    if not src.is_file():
        print(f"ERROR: source log not found: {src}", file=sys.stderr)
        return 1

    sanitized = sanitize(src.read_text(errors="replace"))
    findings = safety_check(sanitized)
    if findings:
        print("ERROR: safety check still found:", file=sys.stderr)
        for finding in findings:
            print(f"  - {finding}", file=sys.stderr)
        return 1

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(sanitized)
    print(f"Sanitized log: {dst}")
    print(f"Lines: {len(sanitized.splitlines())}")
    print("Safety check: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
