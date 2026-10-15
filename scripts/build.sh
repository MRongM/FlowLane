#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
# Keep the user's global xcode-select setting intact.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
"$repo_root/scripts/fetch-core.sh"
swift build --configuration release
binary_dir=$(swift build --configuration release --show-bin-path)
mkdir -p "$repo_root/build" "$repo_root/dist"
staging=$(mktemp -d "$repo_root/build/bundle.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/FlowLane.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
install -m 0755 "$binary_dir/AppProxy" "$app/Contents/MacOS/AppProxy"
install -m 0755 "$binary_dir/AppProxyHelper" "$app/Contents/MacOS/AppProxyHelper"
install -m 0755 "$repo_root/downloaded-binaries/sing-box" "$app/Contents/Resources/sing-box"
cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
cp -R "$repo_root/ThirdParty/sing-box" "$app/Contents/Resources/ThirdParty/"
cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_root/README.md" "$app/Contents/Resources/README.md"
cp -R "$repo_root/docs" "$app/Contents/Resources/"
cp "$repo_root/Resources/Brand/FlowLane.png" "$app/Contents/Resources/FlowLane.png"
iconset="$staging/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$repo_root/Resources/Brand/FlowLane.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$repo_root/Resources/Brand/FlowLane.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
# Preserve the pinned upstream core bytes; it already carries its Go ad-hoc signature.
codesign --verify "$app/Contents/Resources/sing-box"
codesign --force --sign - "$app/Contents/MacOS/AppProxyHelper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
destination="$repo_root/dist/FlowLane.app"
if [ -e "$destination" ]; then rm -rf "$destination"; fi
mv "$app" "$destination"
app="$destination"
ditto -c -k --keepParent "$app" "$repo_root/dist/FlowLane-macos-arm64.zip"
# Keep earlier local launch commands pointing at the fixed application.
legacy="$repo_root/dist/App Proxy.app"
if [ -d "$legacy" ] && [ ! -L "$legacy" ]; then
  if [ ! -e "$repo_root/dist/App Proxy.previous.app" ]; then
    mv "$legacy" "$repo_root/dist/App Proxy.previous.app"
  else
    rm -rf "$legacy"
  fi
fi
ln -sfn FlowLane.app "$legacy"
ln -sfn FlowLane-macos-arm64.zip "$repo_root/dist/App-Proxy-macos-arm64.zip"
printf 'Built: %s\n' "$app"
shasum -a 256 "$repo_root/dist/FlowLane-macos-arm64.zip"
