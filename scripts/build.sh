#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
# Keep the user's global xcode-select setting intact.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$repo_root/scripts/fetch-core.sh"
swift build --configuration release
binary_dir=$(swift build --configuration release --show-bin-path)
app="$repo_root/dist/App Proxy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
install -m 0755 "$binary_dir/AppProxy" "$app/Contents/MacOS/AppProxy"
install -m 0755 "$binary_dir/AppProxyHelper" "$app/Contents/MacOS/AppProxyHelper"
install -m 0755 "$repo_root/downloaded-binaries/sing-box" "$app/Contents/Resources/sing-box"
cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
cp -R "$repo_root/ThirdParty/sing-box" "$app/Contents/Resources/ThirdParty/"
cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_root/README.md" "$app/Contents/Resources/README.md"
cp -R "$repo_root/docs" "$app/Contents/Resources/"
# Preserve the pinned upstream core bytes; it already carries its Go ad-hoc signature.
codesign --verify "$app/Contents/Resources/sing-box"
codesign --force --sign - "$app/Contents/MacOS/AppProxyHelper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$repo_root/dist/App-Proxy-macos-arm64.zip"
printf 'Built: %s\n' "$app"
shasum -a 256 "$repo_root/dist/App-Proxy-macos-arm64.zip"
