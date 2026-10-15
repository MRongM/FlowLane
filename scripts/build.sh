#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
native_arch=$(uname -m)
arch=$native_arch
if [ "$#" -eq 2 ] && [ "$1" = --arch ]; then
  arch=$2
elif [ "$#" -ne 0 ]; then
  printf 'Usage: scripts/build.sh [--arch arm64|x86_64]\n' >&2
  exit 2
fi
case "$arch" in
  arm64) core_sha256=28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2 ;;
  x86_64) core_sha256=4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68 ;;
  *) printf 'Unsupported architecture: %s (expected arm64 or x86_64).\n' "$arch" >&2; exit 2 ;;
esac
# Keep the user's global xcode-select setting intact. Cross-builds have their
# own Swift scratch directory and never run the other architecture's binaries.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
core=$("$repo_root/scripts/fetch-core.sh" --arch "$arch")
swift_arguments=(--configuration release --triple "$arch-apple-macosx14.0" --scratch-path "$repo_root/.build/build-$arch")
swift build "${swift_arguments[@]}"
binary_dir=$(swift build "${swift_arguments[@]}" --show-bin-path)
mkdir -p "$repo_root/build" "$repo_root/dist/$arch"
staging=$(mktemp -d "$repo_root/build/bundle-$arch.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/FlowLane.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty"
install -m 0755 "$binary_dir/AppProxy" "$app/Contents/MacOS/AppProxy"
install -m 0755 "$binary_dir/AppProxyHelper" "$app/Contents/MacOS/AppProxyHelper"
install -m 0755 "$core" "$app/Contents/Resources/sing-box"
for executable in "$app/Contents/MacOS/AppProxy" "$app/Contents/MacOS/AppProxyHelper" "$app/Contents/Resources/sing-box"; do
  lipo "$executable" -verify_arch "$arch"
done
cp "$repo_root/Resources/Info.plist" "$app/Contents/Info.plist"
# SwiftPM's development bundle fallback must never be needed by shipped apps.
cp -R "$binary_dir/AppProxy_AppProxyKit.bundle" "$app/Contents/Resources/"
localizations=0
for localization in "$repo_root/Resources/Localizations/"*.lproj; do
  [ -f "$localization/InfoPlist.strings" ] || continue
  cp -R "$localization" "$app/Contents/Resources/"
  localizations=$((localizations + 1))
done
if [ "$localizations" -ne 11 ]; then
  printf 'Expected 11 packaged InfoPlist.strings localizations; found %s.\n' "$localizations" >&2
  exit 1
fi
cp -R "$repo_root/ThirdParty/sing-box" "$app/Contents/Resources/ThirdParty/"
cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_root/LICENSE" "$app/Contents/Resources/COPYING"
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
# arm64 upstream Go binaries have an ad-hoc signature; the upstream Intel core
# is unsigned. Keep both original files byte-for-byte, sealed as app resources.
if [ "$arch" = arm64 ]; then codesign --verify "$app/Contents/Resources/sing-box"; fi
codesign --force --sign - "$app/Contents/MacOS/AppProxyHelper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
actual_core_sha256=$(shasum -a 256 "$app/Contents/Resources/sing-box")
if [ "${actual_core_sha256%% *}" != "$core_sha256" ]; then
  printf 'Packaging changed the pinned core bytes.\n' >&2
  exit 1
fi
if [ "$arch" = "$native_arch" ]; then
  # This exits before creating a UI and asserts resource resolution inside .app.
  "$app/Contents/MacOS/AppProxy" --localization-audit
fi
# Assemble the zip before replacing any successful prior build.
zip_name="FlowLane-macos-$arch.zip"
ditto -c -k --keepParent "$app" "$staging/$zip_name"
destination="$repo_root/dist/$arch/FlowLane.app"
if [ -e "$destination" ]; then rm -rf "$destination"; fi
mv "$app" "$destination"
mv -f "$staging/$zip_name" "$repo_root/dist/$zip_name"
if [ "$arch" = "$native_arch" ]; then
  # Legacy launch paths always point at a native build, even after a cross-build.
  for alias in FlowLane.app 'App Proxy.app'; do
    alias_path="$repo_root/dist/$alias"
    if [ -d "$alias_path" ] && [ ! -L "$alias_path" ]; then
      previous="$repo_root/dist/${alias%.app}.previous.app"
      if [ ! -e "$previous" ]; then mv "$alias_path" "$previous"; else rm -rf "$alias_path"; fi
    fi
    ln -sfn "$arch/FlowLane.app" "$alias_path"
  done
  ln -sfn "$zip_name" "$repo_root/dist/App-Proxy-macos-$arch.zip"
fi
printf 'Built (%s): %s\n' "$arch" "$destination"
shasum -a 256 "$repo_root/dist/$zip_name"
