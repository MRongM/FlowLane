# sing-box 1.14.3

This project uses the unmodified official **darwin arm64** release executable from [SagerNet/sing-box v1.14.3](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3). It is downloaded during development/build; the executable and archive are excluded from Git.

- Release asset: [sing-box-1.14.3-darwin-arm64.tar.gz](https://github.com/SagerNet/sing-box/releases/download/v1.14.3/sing-box-1.14.3-darwin-arm64.tar.gz)
- Published archive SHA-256: `0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5`
- Extracted executable SHA-256: `28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`
- Exact source revision: [`7054cac5124465ffdb145870d7c01885566711b1`](https://github.com/SagerNet/sing-box/tree/7054cac5124465ffdb145870d7c01885566711b1)
- Matching source archive: [source at the exact revision](https://github.com/SagerNet/sing-box/archive/7054cac5124465ffdb145870d7c01885566711b1.tar.gz)
- Build entry points: [Makefile](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/Makefile), [release configuration](https://github.com/SagerNet/sing-box/tree/7054cac5124465ffdb145870d7c01885566711b1/release), [build workflow](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/.github/workflows/build.yml)
- Dependency versions and checksums: [go.mod](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/go.mod), [go.sum](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/go.sum).

`LICENSE` is the verbatim upstream notice, including its naming condition. `GPL-3.0.txt` supplies the complete GNU GPL version 3 text. Both accompany the packaged executable. Upstream source contains dependency notices; the diagnostic resolves its dependencies through Go modules with `go.sum` verification. There are no local modifications to the bundled sing-box executable.

`release.json` records release metadata read using `gh api repos/SagerNet/sing-box/releases/tags/v1.14.3` and `gh api repos/SagerNet/sing-box/git/ref/tags/v1.14.3` on 2026-10-15, plus hashes computed locally after authenticating the archive. Downloading and checking the core does not launch a TUN or change networking settings.
