#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <marketing_version> <build_version>" >&2
  exit 1
fi

MARKETING_VERSION="$1"
BUILD_VERSION="$2"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/Config/Version.xcconfig"

if [ ! -f "$VERSION_FILE" ]; then
  echo "version file not found: $VERSION_FILE" >&2
  exit 1
fi

python3 - "$VERSION_FILE" "$MARKETING_VERSION" "$BUILD_VERSION" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
marketing = sys.argv[2]
build = sys.argv[3]
text = path.read_text(encoding="utf-8")

patterns = {
    r"^APP_MARKETING_VERSION = .*$": f"APP_MARKETING_VERSION = {marketing}",
    r"^APP_BUILD_VERSION = .*$": f"APP_BUILD_VERSION = {build}",
}

for pattern, replacement in patterns.items():
    text, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"failed to update pattern: {pattern}")

path.write_text(text, encoding="utf-8")
PY

echo "Updated version file:"
echo "  Marketing version: $MARKETING_VERSION"
echo "  Build version: $BUILD_VERSION"
echo "  File: $VERSION_FILE"
