# Project context

FlowLane is a macOS utility for selecting applications and assigning proxy connections to their traffic. The GitHub repository is `MRongM/FlowLane`.

The user does not have an Apple Developer account. Evaluate an existing open-source networking core before relying on signed Network Extensions.

The repository contains the SwiftUI app, a controlled sing-box helper, and local verification scripts. Unprivileged loopback forwarding and process attribution have been verified. Full administrator-authorized TUN interception and recovery, live IPv6, and TUN UDP/QUIC acceptance remain unverified; see `docs/verification.md`.

## Naming and compatibility

- Keep the `FlowLane` package/product name, `CFBundleExecutable`, build scripts, CI launch paths, and `FlowLane_AppProxyKit.bundle` resource lookup aligned.
- Internal modules and the helper retain their `AppProxy` names. Preserve the existing bundle identifier, configuration directory, and Keychain service so upgrades can read existing data; see `docs/branding.md`.
- Use semantic version numbers for release names. Keep verification limits explicit in documentation.
- Keep build caches, downloaded cores, diagnostics, and local scratch files out of Git. Preserve source assets, user-provided reference screenshots, and final delivery artifacts during routine cleanup. An installed `/Applications/FlowLane.app` is self-contained.

## Development guidance

- Keep app selection, proxy profiles, routing rules, and runtime control separate.
- Default unmatched traffic to direct connections.
- Account for helper processes used by selected applications.
- Keep credentials out of source control and logs; use Keychain for stored secrets.
- Keep generated runtime configurations and downloaded binaries out of Git.
- Do not change system routing, DNS, or proxy settings during builds or ordinary tests.
- Make network activation explicit, and verify that stopping restores the state changed by the application.
- Document any limits of process attribution, DNS handling, and UDP routing.
