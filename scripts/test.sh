#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
if [ "$#" -ne 0 ]; then
  printf 'Usage: scripts/test.sh (native architecture only)\n' >&2
  exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$repo_root/scripts/fetch-core.sh"
"$repo_root/tools/attribution/test-fetch-core.sh"
# Make subprocess tests exercise the helper rather than taking their missing-build skip.
swift build --product AppProxyHelper
swift test
python3 -m unittest discover -s scripts -p test_integration.py
python3 "$repo_root/scripts/integration.py"
(cd "$repo_root/tools/attribution" && go test -count=1 ./... && go run .)
