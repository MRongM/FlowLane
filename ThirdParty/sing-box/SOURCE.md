# sing-box 1.14.3

This project uses the unmodified official **darwin arm64 and darwin amd64** release executables from [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3). The architecture-matched executable is downloaded during development/build; executables and archives are excluded from Git.

| Build architecture | Official release asset | Archive SHA-256 | Original executable SHA-256 |
| --- | --- | --- | --- |
| `arm64` | [darwin-arm64](https://github.com/SagerNet/sing-box/releases/download/v1.14.3/sing-box-1.14.3-darwin-arm64.tar.gz) | `0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5` | `28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2` |
| `x86_64` | [darwin-amd64](https://github.com/SagerNet/sing-box/releases/download/v1.14.3/sing-box-1.14.3-darwin-amd64.tar.gz) | `6d002b74d03b478547349cc10af89e007868596e5aa931816d45da9f544715a9` | `4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68` |

- Exact source revision: [`7054cac5124465ffdb145870d7c01885566711b1`](https://github.com/SagerNet/sing-box/tree/7054cac5124465ffdb145870d7c01885566711b1)
- Matching source archive: [source at the exact revision](https://github.com/SagerNet/sing-box/archive/7054cac5124465ffdb145870d7c01885566711b1.tar.gz)
- Build entry points: [Makefile](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/Makefile), [release configuration](https://github.com/SagerNet/sing-box/tree/7054cac5124465ffdb145870d7c01885566711b1/release), [build workflow](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/.github/workflows/build.yml)
- Dependency versions and checksums: [go.mod](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/go.mod), [go.sum](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/go.sum).

`LICENSE` is the verbatim upstream notice, including its naming condition. `GPL-3.0.txt` supplies the complete GNU GPL version 3 text. Both accompany the packaged executable. Upstream source contains dependency notices; the diagnostic resolves its dependencies through Go modules with `go.sum` verification. There are no local modifications to the bundled sing-box executable.

`release.json` records release metadata read using `gh api repos/SagerNet/sing-box/releases/tags/v1.14.3` and `gh api repos/SagerNet/sing-box/git/ref/tags/v1.14.3` on 2026-10-15, plus hashes computed locally after authenticating the archive. Downloading and checking the core does not launch a TUN or change networking settings.

## Architecture selection and packaging

`scripts/fetch-core.sh` defaults to the current native architecture and maintains `downloaded-binaries/sing-box` for native tests. `scripts/fetch-core.sh --arch arm64` and `--arch x86_64` install separate copies under `downloaded-binaries/<architecture>/sing-box` without changing that native test path. Archives have distinct, pinned filenames and checksums. Both the complete archive and extracted executable are authenticated before installation.

`scripts/build.sh --arch arm64|x86_64` uses separate Swift scratch and application directories and emits `dist/FlowLane-macos-<architecture>.zip`. Cross-compilation validates binary architecture and packaging without running the other architecture's code. Native GitHub runner tests are required to establish runtime support for each architecture.

The upstream arm64 executable has a Go ad-hoc code signature. The upstream amd64 executable is unsigned. Packaging preserves both original executable hashes. The Intel core is sealed as a resource by the outer application signature; it is not independently re-signed. An outer-bundle ad-hoc signing and deep/strict verification experiment succeeded while preserving the original Intel hash. This verifies packaging integrity, not Apple notarization or Intel runtime behavior.
