# Native attribution evidence — 2026-10-15

The **actual sing-box v1.14.3 Darwin lookup** identified four held sockets from two different executable paths, as an ordinary user. This validates the tested IPv4 loopback attribution case; it does not validate TUN interception or UDP proxying.

## Reproducible commands

From the repository root:

```sh
scripts/fetch-core.sh
tools/attribution/test-fetch-core.sh
cd tools/attribution
go test -v -count=1 ./...
go run .
go test -count=5 ./...
go vet ./...
go mod verify
```

All commands above ran successfully on macOS 26.6 / Darwin 25.6.0, arm64, with the diagnostic's Go 1.25.5 toolchain. No `sudo`, TUN, route, DNS or system proxy operation is part of the diagnostic or download verification. Only parent/child loopback listeners, TCP connections and connected UDP sockets are created. The process table is not dumped; only the diagnostic's own children are printed, and temporary paths are normalized to `$TEMP`.

## Upstream source and fixed core

`tools/attribution/go.mod` imports `github.com/sagernet/sing-box/common/process` at **v1.14.3** directly. It uses the unmodified [Darwin searcher](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/common/process/searcher_darwin.go) and [Darwin socket parser/matcher](https://github.com/SagerNet/sing-box/blob/7054cac5124465ffdb145870d7c01885566711b1/common/process/searcher_darwin_shared.go).

The committed Go module content checksum is `h1:cBg8TP5SPWoMAlWqTqbSNdHGKPUciZisjQbLtqFlMZA=`. `go mod verify` reported `all modules verified`.

The [official release](https://github.com/SagerNet/sing-box/releases/tag/v1.14.3) metadata, queried using GitHub CLI on 2026-10-15, supplied the archive digest. The downloaded 29,163,190-byte archive matched SHA-256 `0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5`. Its extracted executable matched `28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`; `version` reported **1.14.3**, revision `7054cac5124465ffdb145870d7c01885566711b1`. The ignored executable is `downloaded-binaries/sing-box`. The matching source links, upstream notice and complete GPL text are in `ThirdParty/sing-box/`.

The download-verification test reported:

```text
PASS: verified offline cache installs fixed version; modified executable replaced; corrupt cached/downloaded archives rejected.
```

## Observed process identities

Two copies of the diagnostic executable were launched at distinct temporary filesystem paths. Both processes stayed alive, each holding one TCP and one connected UDP socket at the same time. Each sent a byte, observed by the parent loopback listener. Source/destination tuples came from these real sockets and were checked against the listener's observed peers before lookup.

The recorded `go run .` execution produced:

| Executable path | Launched PID | Protocol | Upstream observed path | Native PID path check | UID match | Result |
| --- | ---: | --- | --- | --- | --- | --- |
| `$TEMP/client-a` | 98035 | TCP | `$TEMP/client-a` | true | true | matched |
| `$TEMP/client-a` | 98035 | UDP | `$TEMP/client-a` | true | true | matched |
| `$TEMP/client-b` | 98036 | TCP | `$TEMP/client-b` | true | true | matched |
| `$TEMP/client-b` | 98036 | UDP | `$TEMP/client-b` | true | true | matched |

The report contained `"elevated": false` and `"all_matched": true`. Both unknown probes returned `"status": "unknown", "detail": "process not found"`. Those probes used documentation address `192.0.2.1` with a nonzero port reserved by the parent's loopback UDP listener. They performed lookups only; no traffic was sent to that address.

The upstream public `ConnectionOwner` does **not** expose the matched socket PID. The PIDs above are independently known from launched process handles, agree with the children's reported PIDs, and have their executable paths read using Darwin `proc_pidpath`. The returned upstream path agrees with that native path and the unique expected executable path. This is path-correlated PID evidence, not a claim that the public lookup returned these PID numbers.

The real-socket test and native C-string PID-path check passed. Five further repetitions of the test suite passed; `go vet ./...` completed without diagnostics.

## Limits and unknown handling

- Upstream reads Darwin `net.inet.tcp.pcblist_n` / `net.inet.udp.pcblist_n` snapshots. It caches snapshots for 200 ms and refreshes some cached misses/fallbacks. Socket closure, process exit, PID reuse, permissions and OS structure changes can still make attribution unavailable; these held, same-user sockets avoid those timing conditions.
- TCP matching uses the tuple. UDP can fall back to a local address/port or wildcard-bound socket when no exact destination match exists. During development, an address/port-zero UDP probe returned an owner; it was therefore unsuitable as evidence of an unowned tuple. The recorded unknown probes use an already-reserved, nonzero loopback port and a different source address. UDP attribution does not prove that a particular destination belongs uniquely to an application.
- If lookup fails or returns an empty executable path, the diagnostic reports **unknown**. It never invents an application. The application design sends unknown/unmatched traffic direct, so this policy is not a guarantee against direct connections when attribution is missing.
- A bundled helper is attributed by its own executable path; matching it to an application requires the separate bundle-path rule logic. A shared service outside the application bundle cannot reliably be assigned to the initiating application by this lookup alone.
- DNS may be owned by a shared resolver process. This diagnostic does not establish per-application DNS ownership; the application design leaves DNS direct.
- IPv6 attribution, other-user processes, burst/short-lived traffic, TUN-observed tuples and administrator-only capture/restoration are **not verified here**. Successful UDP ownership lookup does not implement UDP proxy routing; the product's selected UDP policy remains explicit rejection.
