#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="$ROOT/build-v5-binning-stack-r2.sh"
TMP_SCRIPT="$ROOT/.build-v5-binning-stack-r2-fixed.sh"

[ -f "$SRC_SCRIPT" ] || { echo "ERROR: missing $SRC_SCRIPT" >&2; exit 1; }

python3 - "$SRC_SCRIPT" "$TMP_SCRIPT" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text()
old = "    'safe PROPERTY_ENTRY_BOOL': bool(re.search(r'PROPERTY_ENTRY_BOOL\\s*\\(\\s*sensor->prop_names\\.clock_noncontinuous\\s*\\)', br)),\n"
new = "    'safe PROPERTY_ENTRY_BOOL': (\n        bool(re.search(r'struct\\s+ipu_property_names\\s+\\*names\\s*=\\s*&sensor->prop_names\\s*;', br))\n        and bool(re.search(r'PROPERTY_ENTRY_BOOL\\s*\\(\\s*names->clock_noncontinuous\\s*\\)', br))\n    ),\n"
count = text.count(old)
if count != 1:
    raise SystemExit(f'expected exactly one old semantic check, found {count}')
dst.write_text(text.replace(old, new, 1))
PY

chmod +x "$TMP_SCRIPT"
trap 'rm -f "$TMP_SCRIPT"' EXIT
bash "$TMP_SCRIPT"
