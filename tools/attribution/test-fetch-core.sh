#!/bin/bash
# Verify archive authentication and architecture isolation in a temporary repo.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
arch=$(uname -m)
if [ "$#" -eq 2 ] && [ "$1" = --arch ]; then
  arch=$2
elif [ "$#" -ne 0 ]; then
  printf 'Usage: tools/attribution/test-fetch-core.sh [--arch arm64|x86_64]\n' >&2
  exit 2
fi
case "$arch" in
  arm64) upstream_arch=arm64; executable_sha256=28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2; other_arch=x86_64 ;;
  x86_64) upstream_arch=amd64; executable_sha256=4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68; other_arch=arm64 ;;
  *) printf 'Unsupported architecture: %s\n' "$arch" >&2; exit 2 ;;
esac
archive_name="sing-box-1.14.3-darwin-$upstream_arch.tar.gz"
archive="$repo_root/downloaded-binaries/$archive_name"
if [ ! -f "$archive" ]; then
  printf 'Run scripts/fetch-core.sh --arch %s before this test.\n' "$arch" >&2
  exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/scripts" "$scratch/downloaded-binaries/$other_arch" "$scratch/bin"
cp "$repo_root/scripts/fetch-core.sh" "$scratch/scripts/fetch-core.sh"
cp "$archive" "$scratch/downloaded-binaries/$archive_name"
printf 'native sentinel' > "$scratch/downloaded-binaries/sing-box"
printf 'other architecture sentinel' > "$scratch/downloaded-binaries/$other_arch/sing-box"
cat > "$scratch/bin/curl" <<'CURL'
#!/bin/bash
printf 'Unexpected network request\n' >&2
exit 91
CURL
chmod +x "$scratch/bin/curl"
executable="$scratch/downloaded-binaries/$arch/sing-box"
actual_path=$(PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" --arch "$arch")
[ "$actual_path" = "$executable" ]
[ "$(cat "$scratch/downloaded-binaries/sing-box")" = 'native sentinel' ]
[ "$(cat "$scratch/downloaded-binaries/$other_arch/sing-box")" = 'other architecture sentinel' ]
actual_sha256=$(shasum -a 256 "$executable")
[ "${actual_sha256%% *}" = "$executable_sha256" ]
lipo "$executable" -verify_arch "$arch"
if [ "$arch" = "$(uname -m)" ]; then
  "$executable" version | /usr/bin/grep -q '^sing-box version 1.14.3$'
  native_path=$(PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh")
  [ "$native_path" = "$scratch/downloaded-binaries/sing-box" ]
  native_sha256=$(shasum -a 256 "$native_path")
  [ "${native_sha256%% *}" = "$executable_sha256" ]
fi
printf 'tampered executable' > "$executable"
PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" --arch "$arch" >/dev/null
actual_sha256=$(shasum -a 256 "$executable")
[ "${actual_sha256%% *}" = "$executable_sha256" ]
printf 'tampered cache' > "$scratch/downloaded-binaries/$archive_name"
rm "$executable"
if PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" --arch "$arch" >"$scratch/output" 2>&1; then
  printf 'FAIL: tampered archive accepted\n' >&2
  exit 1
fi
/usr/bin/grep -q 'SHA-256 mismatch' "$scratch/output"
[ ! -e "$executable" ]
rm "$scratch/downloaded-binaries/$archive_name"
cat > "$scratch/bin/curl" <<'CURL'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    printf 'corrupt download' > "$2"
    exit 0
  fi
  shift
done
exit 92
CURL
if PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" --arch "$arch" >"$scratch/output" 2>&1; then
  printf 'FAIL: corrupt download accepted\n' >&2
  exit 1
fi
/usr/bin/grep -q 'SHA-256 mismatch' "$scratch/output"
[ ! -e "$executable" ]
[ ! -e "$scratch/downloaded-binaries/$archive_name" ]
if bash "$scratch/scripts/fetch-core.sh" --arch ppc >"$scratch/output" 2>&1; then
  printf 'FAIL: unsupported architecture accepted\n' >&2
  exit 1
fi
printf 'PASS (%s): authenticated cache; isolated architectures; native compatibility; modified executable replacement; corrupt cached/downloaded archives rejected.\n' "$arch"
