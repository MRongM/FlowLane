# FlowLane · 流径

**A native macOS app that chooses a proxy connection for each application.**

[简体中文](README.zh-CN.md) · [Website](https://gh.328064.xyz/FlowLane/) · [Downloads](https://github.com/MRongM/FlowLane/releases/latest) · [Verification](docs/verification.md)

![CI](https://github.com/MRongM/FlowLane/actions/workflows/ci.yml/badge.svg)

Select `.app` bundles, assign your existing SOCKS5 or HTTP CONNECT proxies, and keep unmatched traffic direct. FlowLane uses SwiftUI and a pinned open-source sing-box TUN core, without requiring an Apple Developer account.

**Verification status:** local TCP forwarding, process attribution, configuration, language switching and controlled runtime boundaries are tested. Full administrator-authorized TUN routing, IPv6 traffic and recovery acceptance remain separate checks. Unknown/shared processes can connect directly; FlowLane is not a leak-prevention guarantee.

## Download

Requires **macOS 14 or later**. Choose the build matching your Mac:

| Mac | Download |
| --- | --- |
| Apple Silicon (M1/M2/M3/M4 and newer) | [FlowLane-macos-arm64.zip](https://github.com/MRongM/FlowLane/releases/latest/download/FlowLane-macos-arm64.zip) |
| Intel | [FlowLane-macos-x86_64.zip](https://github.com/MRongM/FlowLane/releases/latest/download/FlowLane-macos-x86_64.zip) |

Unzip and move `FlowLane.app` to Applications. Builds are **ad-hoc signed, not notarized**. If macOS blocks the download, follow [Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/guide/mac-help/mh40616/mac). No SIP changes or developer subscription are needed. Releases include `SHA256SUMS`.

## Use

1. **Choose apps.** You can add applications before creating a proxy. Unassigned rules are saved disabled.
2. **Add and assign proxies.** Enter an existing SOCKS5 or HTTP CONNECT host/port and optional credentials. Passwords go to macOS Keychain. Rules match from top to bottom; in-bundle helpers/XPC can be included.
3. **Start explicitly.** Click **Start network routing**, then approve the macOS administrator prompt. Opening the app never starts interception. Stop before editing rules; stopping disconnects existing connections handled by the core.

TUN receives traffic according to system routes, then selects proxy or direct. Unselected applications can also pass through the core. Identified matching TCP connections fail when the selected upstream fails; they do not automatically fall back to direct. Verified local upstream processes/app bundles are explicitly exempted to prevent loops, and owner changes stop the session.

## 11 interface languages

Open **Settings → Interface language**, or **FlowLane → Settings…** (`⌘,`). Choose **Follow system** or a language manually. App text updates immediately and the preference survives restart; changing languages preserves rules, credentials and running connections.

| Language | Language | Language |
| --- | --- | --- |
| English | 简体中文 | 繁體中文 |
| 日本語 | 한국어 | Français |
| Deutsch | Español | Português (Brasil) |
| Русский | العربية (RTL) | |

System matching understands regional variants and Chinese scripts; unsupported languages fall back to English. Arabic mirrors the layout while paths, endpoints and core logs remain left-to-right. Some macOS-native menus/dialog controls adopt an app language after restart; the system administrator dialog follows macOS. Raw core logs and system diagnostic details retain their original language.

Translations use standard `.lproj` / `.strings` resources. UI, validation, runtime and restoration messages carry stable keys and safe placeholders. Tests check every language’s keys and placeholders. See [localization design](docs/superpowers/specs/2026-10-15-localization-design.md).

## Network scope

| Traffic | Policy |
| --- | --- |
| TCP / HTTPS / IMAP / SMTP | SOCKS5 or HTTP CONNECT by process path; local forwarding tested without reading/sending user email |
| In-bundle Helper / XPC | Anchored, escaped bundle-path match; shared services outside the bundle are not automatically attributable |
| Unknown / unmatched process | Direct by default |
| UDP / QUIC | Matching app traffic is rejected; unmatched traffic is direct; live TUN acceptance remains pending |
| DNS | Port 53 direct, `dns_mode: disabled`; no system DNS changes, per-app DNS or DNS privacy |
| IPv6 | Included in TUN configuration; live IPv6 interception still requires suitable-network acceptance |
| TLS content | No decryption, root certificate installation, full HTTPS URLs, headers or bodies |

Loopback, local links, explicitly bound interfaces and higher-priority VPN routes can bypass TUN. Ownership comes from socket-table snapshots and can race or belong to a shared system process. See [known limits and evidence](docs/verification.md).

## Build and test

Xcode and its command-line tools are required. Swift packages have no external dependencies; Go is only needed for the native attribution diagnostic, and Python 3 for integration/site checks.

```sh
./scripts/build.sh                    # native architecture
./scripts/build.sh --arch arm64
./scripts/build.sh --arch x86_64
open "dist/FlowLane.app"               # native compatibility link
```

Packages: `dist/FlowLane-macos-arm64.zip` and `dist/FlowLane-macos-x86_64.zip`; separate apps live under `dist/<arch>/FlowLane.app`. Cross-compilation checks architecture and signatures; CI runs tests on native ARM and Intel macOS runners. Build commands use a command-local `DEVELOPER_DIR`, preserving the global Xcode selection.

```sh
./scripts/test.sh
"dist/$(uname -m)/FlowLane.app/Contents/MacOS/FlowLane" --localization-audit
python3 scripts/integration.py --core "$PWD/dist/FlowLane.app/Contents/Resources/sing-box" --helper "$PWD/dist/FlowLane.app/Contents/MacOS/AppProxyHelper"
open -n -W -a "$PWD/dist/FlowLane.app" --args --smoke-test
python3 scripts/privileged-acceptance.py --self-test
```

Ordinary tests and builds never enable TUN or modify routing, DNS or system proxy settings. Explicit live acceptance, requiring your own administrator approval, is `python3 scripts/privileged-acceptance.py --activate`; its IPv4 result is saved to ignored `dist/privileged-acceptance.json`. IPv6/UDP require separate acceptance.

## Data and privilege boundary

Normal configuration stays at `~/Library/Application Support/App Proxy/configuration.json` (0600); the stable directory and Keychain service remain compatible with earlier App Proxy builds. Language preferences are app-local UserDefaults. Passwords are read from Keychain only when needed, transported in private 0700/0600 sessions, then consumed and removed. Root-only runtime files are cleaned after normal stop/failure. Logs are bounded and redact credentials.

The helper accepts fixed operations and typed models, verifies owner/parent/file permissions, rejects links, generates an allowlisted configuration and checks the copied core SHA-256. It does not expose arbitrary shell execution or install a permanent privileged daemon. UI exit/heartbeat loss and core failure trigger supervision. Stop compares routing/DNS/proxy state without overwriting another tool’s changes. Helper SIGKILL or machine crashes have additional limits; see [helper protocol](docs/helper-protocol.md).

## Releases, website and source

- [CI](.github/workflows/ci.yml) tests/builds both native architectures.
- [Release](.github/workflows/release.yml) validates a `v*` tag against the app version and publishes only after both native builds pass, with two ZIPs and checksums. Manual dispatch defaults to build-only.
- [Pages](.github/workflows/pages.yml) builds and publishes the [11-language introduction site](https://gh.328064.xyz/FlowLane/). Local preview: `python3 scripts/build-site.py` then serve `build/site`.

FlowLane is GPL-3.0-or-later: [LICENSE](LICENSE). Pinned **sing-box 1.14.3**, architecture hashes, upstream license and matching source links are in [ThirdParty/sing-box](ThirdParty/sing-box/SOURCE.md). Downloaded executables, runtime credentials/configurations and built applications stay out of Git. [Brand assets and image-generation prompt](docs/branding.md).
