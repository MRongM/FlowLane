## FlowLane 0.3.0 — multilingual preview

Native macOS per-application proxy utility, with separate Apple Silicon (arm64) and Intel (x86_64) builds for macOS14+.

- 11 interface languages: English, Simplified/Traditional Chinese, Japanese, Korean, French, German, Spanish, Brazilian Portuguese, Russian and Arabic.
- Settings includes Follow system and persistent manual selection, immediate app-text updates, RTL layout, localized validation/status/restoration, and bundled offline language resources.
- Choose apps before adding a proxy; unassigned rules persist disabled. Existing configuration and Keychain credentials remain compatible.
- Existing SOCKS5/HTTP CONNECT upstreams, ordered app/helper rules, explicit administrator-approved TUN startup, bounded/redacted logs and controlled supervisor lifecycle.
- Native ARM and Intel CI, pinned core checksums, GPL/source notices and SHA256SUMS for both ZIP files.

### Preview limits

Full administrator-authorized TUN interception/recovery, live IPv6 and TUN UDP/QUIC acceptance are still separate verification steps. Unknown/shared processes default direct; matching UDP is rejected; DNS port53 is direct. No TLS decryption or leak-prevention guarantee. Builds are ad-hoc signed and not notarized. Some macOS-native menu/dialog text updates after restarting the app; core/system diagnostics retain their original language.

Choose FlowLane-macos-arm64.zip for Apple Silicon or FlowLane-macos-x86_64.zip for Intel, unzip and move FlowLane.app to Applications. Verify against SHA256SUMS. Opening the app never activates networking.

See README.md / README.zh-CN.md, docs/verification.md and the GitHub Pages introduction for usage, build and acceptance instructions.
