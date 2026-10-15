# Project context

This project is a macOS utility for selecting applications and assigning proxy connections to their traffic.

The user does not have an Apple Developer account. Evaluate an existing open-source networking core before relying on signed Network Extensions.

The repository currently contains initialization documents only. Do not describe the proxy functionality as implemented until it has been built and verified.

## Development guidance

- Keep app selection, proxy profiles, routing rules, and runtime control separate.
- Default unmatched traffic to direct connections.
- Account for helper processes used by selected applications.
- Keep credentials out of source control and logs; use Keychain for stored secrets.
- Keep generated runtime configurations and downloaded binaries out of Git.
- Do not change system routing, DNS, or proxy settings during builds or ordinary tests.
- Make network activation explicit, and verify that stopping restores the state changed by the application.
- Document any limits of process attribution, DNS handling, and UDP routing.
