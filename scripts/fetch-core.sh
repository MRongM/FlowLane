#!/bin/bash
# Download only the pinned official release. No routes, DNS, proxies, or TUNs.
set -euo pipefail
if [ "$#" -ne 0 ]; then
  printf 'Usage: scripts/fetch-core.sh\n' >&2
  exit 2
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  printf 'The pinned core requires macOS on Apple Silicon (darwin arm64).\n' >&2
  exit 1
fi
readonly version=1.14.3
readonly archive_name="sing-box-${version}-darwin-arm64.tar.gz"
readonly archive_sha256=0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5
readonly url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive_name}"
repo_root=$(cd "$(dirname "$0")/.." && pwd)
readonly download_dir="$repo_root/downloaded-binaries"
readonly archive="$download_dir/$archive_name"
mkdir -p "$download_dir"
scratch=$(mktemp -d "$download_dir/.fetch-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [ ! -f "$archive" ]; then
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --retry 3 --connect-timeout 30 --max-time 600 "$url" -o "$scratch/archive.tar.gz"
  actual=$(shasum -a 256 "$scratch/archive.tar.gz")
  actual=${actual%% *}
  if [ "$actual" != "$archive_sha256" ]; then
    printf 'SHA-256 mismatch for downloaded core archive; refusing extraction.\n' >&2
    exit 1
  fi
  mv "$scratch/archive.tar.gz" "$archive"
fi
actual=$(shasum -a 256 "$archive")
actual=${actual%% *}
if [ "$actual" != "$archive_sha256" ]; then
  printf 'SHA-256 mismatch for cached core archive; remove the archive and retry.\n' >&2
  exit 1
fi
# Extract only the expected file after authenticating the complete archive.
tar -xzf "$archive" -C "$scratch" "sing-box-${version}-darwin-arm64/sing-box"
install -m 0755 "$scratch/sing-box-${version}-darwin-arm64/sing-box" "$scratch/sing-box"
# A same-directory rename prevents readers seeing a partially written binary.
mv -f "$scratch/sing-box" "$download_dir/sing-box"
printf '%s\n' "$download_dir/sing-box"
