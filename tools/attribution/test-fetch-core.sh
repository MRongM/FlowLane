#!/bin/bash
# Exercise fixed-download verification with a real, already verified release archive.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
archive="$repo_root/downloaded-binaries/sing-box-1.14.3-darwin-arm64.tar.gz"
if [ ! -f "$archive" ]; then
  printf 'Run scripts/fetch-core.sh once before this test.\n' >&2
  exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/scripts" "$scratch/downloaded-binaries" "$scratch/bin"
cp "$repo_root/scripts/fetch-core.sh" "$scratch/scripts/fetch-core.sh"
cp "$archive" "$scratch/downloaded-binaries/$(basename "$archive")"
# A verified cache must permit an entirely offline run.
cat > "$scratch/bin/curl" <<'CURL'
#!/bin/bash
printf 'Unexpected network request\n' >&2
exit 91
CURL
chmod +x "$scratch/bin/curl"
PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" >/dev/null
"$scratch/downloaded-binaries/sing-box" version | /usr/bin/grep -q '^sing-box version 1.14.3$'
# A modified installed executable must be replaced from authenticated bytes.
printf 'tampered executable' > "$scratch/downloaded-binaries/sing-box"
PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" >/dev/null
"$scratch/downloaded-binaries/sing-box" version | /usr/bin/grep -q '^sing-box version 1.14.3$'
printf 'tampered cache' > "$scratch/downloaded-binaries/$(basename "$archive")"
rm "$scratch/downloaded-binaries/sing-box"
if PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" >"$scratch/output" 2>&1; then
  printf 'FAIL: tampered archive accepted\n' >&2
  exit 1
fi
/usr/bin/grep -q 'SHA-256 mismatch' "$scratch/output"
[ ! -e "$scratch/downloaded-binaries/sing-box" ]
# Also exercise the initial download branch with intentionally corrupt bytes.
rm "$scratch/downloaded-binaries/$(basename "$archive")"
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
if PATH="$scratch/bin:$PATH" bash "$scratch/scripts/fetch-core.sh" >"$scratch/output" 2>&1; then
  printf 'FAIL: corrupt download accepted\n' >&2
  exit 1
fi
/usr/bin/grep -q 'SHA-256 mismatch' "$scratch/output"
[ ! -e "$scratch/downloaded-binaries/sing-box" ]
[ ! -e "$scratch/downloaded-binaries/$(basename "$archive")" ]
printf 'PASS: verified offline cache installs fixed version; modified executable replaced; corrupt cached/downloaded archives rejected.\n'
