#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$repo_root/scripts/fetch-core.sh"
swift test
python3 "$repo_root/scripts/integration.py"
(cd "$repo_root/tools/attribution" && go test ./... && go run .)
