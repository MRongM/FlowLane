#!/bin/bash
# Download only pinned official releases. No routes, DNS, proxies, or TUNs.
set -euo pipefail
native_arch=$(uname -m)
arch=$native_arch
explicit_arch=false
if [ "$#" -eq 2 ] && [ "$1" = --arch ]; then
  arch=$2
  explicit_arch=true
elif [ "$#" -ne 0 ]; then
  printf 'Usage: scripts/fetch-core.sh [--arch arm64|x86_64]\n' >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
  printf 'The pinned core requires macOS.\n' >&2
  exit 1
fi
case "$arch" in
  arm64)
    upstream_arch=arm64
    archive_sha256=0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5
    executable_sha256=28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2
    ;;
  x86_64)
    upstream_arch=amd64
    archive_sha256=6d002b74d03b478547349cc10af89e007868596e5aa931816d45da9f544715a9
    executable_sha256=4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68
    ;;
  *) printf 'Unsupported architecture: %s (expected arm64 or x86_64).\n' "$arch" >&2; exit 2 ;;
esac
readonly version=1.14.3
readonly archive_name="sing-box-${version}-darwin-${upstream_arch}.tar.gz"
readonly url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive_name}"
repo_root=$(cd "$(dirname "$0")/.." && pwd)
readonly download_dir="$repo_root/downloaded-binaries"
readonly archive="$download_dir/$archive_name"
readonly architecture_dir="$download_dir/$arch"
mkdir -p "$architecture_dir"
scratch=$(mktemp -d "$download_dir/.fetch-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
verify_sha256() {
  local actual
  actual=$(shasum -a 256 "$1")
  actual=${actual%% *}
  if [ "$actual" != "$2" ]; then
    printf 'SHA-256 mismatch for %s; refusing to install the core.\n' "$3" >&2
    return 1
  fi
}
if [ ! -f "$archive" ]; then
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 30 --max-time 600 "$url" -o "$scratch/archive.tar.gz"
  verify_sha256 "$scratch/archive.tar.gz" "$archive_sha256" 'downloaded archive'
  mv "$scratch/archive.tar.gz" "$archive"
fi
verify_sha256 "$archive" "$archive_sha256" 'cached archive (remove it and retry)'
# Extract only the expected member after authenticating the complete archive.
tar -xzf "$archive" -C "$scratch" "sing-box-${version}-darwin-${upstream_arch}/sing-box"
install -m 0755 "$scratch/sing-box-${version}-darwin-${upstream_arch}/sing-box" "$scratch/sing-box"
verify_sha256 "$scratch/sing-box" "$executable_sha256" 'extracted executable'
# Each target has a separate executable. Never execute a cross-target binary.
mv -f "$scratch/sing-box" "$architecture_dir/sing-box"
if [ "$explicit_arch" = false ]; then
  # Preserve the default native path used by ordinary integration tests.
  install -m 0755 "$architecture_dir/sing-box" "$scratch/native-core"
  mv -f "$scratch/native-core" "$download_dir/sing-box"
  printf '%s\n' "$download_dir/sing-box"
else
  printf '%s\n' "$architecture_dir/sing-box"
fi
