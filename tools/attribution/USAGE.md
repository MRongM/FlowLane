# Native process attribution diagnostic

Run as your ordinary macOS user, without `sudo`:

```sh
cd tools/attribution
go test -count=1 ./...
go run .
```

Go 1.25.5+ is required by the upstream module; Go's normal toolchain auto-download can supply it. The dependency is **the actual** `github.com/sagernet/sing-box/common/process` package from `v1.14.3`, verified by the committed `go.sum`.

The diagnostic makes two executable copies of itself at separate temporary paths, launches them as independent processes, and keeps their real TCP and connected UDP sockets alive concurrently. Each client sends one byte to a parent-owned IPv4 loopback listener. The parent verifies each connection's source endpoint, then calls the upstream lookup on those exact local/remote tuples. It independently asks Darwin `proc_pidpath` for each launched PID and compares that path to the upstream result and expected executable. Temporary files, children and sockets are cleaned up on return.

The upstream public `ConnectionOwner` contains a path and UID, **not a socket PID**. `expected_pid` is the PID returned by the launched child process and checked against the process handle. `kernel_path_for_pid` independently resolves that known PID; it is not presented as a PID returned by the upstream socket lookup. The two unique executable paths make the correlation unambiguous for these held sockets.

Output contains only the controlled child processes. Random temporary directory names are replaced with `$TEMP`; no usernames, hostnames, unrelated socket tables or network settings are printed. An unknown probe uses a documentation-only source address and a nonzero port already held by the parent; it performs a lookup without sending packets to that address. Exit code 0 means all four held sockets matched and both unknown probes remained unknown, 3 means at least one owner was unavailable, and 1 means a wrong owner, unexpected unknown-probe owner or execution error. With `go run`, the Go launcher reports nonzero program exit codes through its own exit status.

This exercises **IPv4 loopback** attribution. It does not validate TUN capture, IPv6, attribution of another user's processes, short-lived sockets, helper grouping, DNS ownership or UDP proxy transport. Inspect `docs/attribution-results.md` for the observed run and upstream fallback/cache limits.

The fixed core download verifier has a separate test:

```sh
scripts/fetch-core.sh
tools/attribution/test-fetch-core.sh
```

That test uses an isolated temporary repository and the authenticated local archive. It verifies an offline cache install, replacement of a modified installed executable, rejection of a modified archive and rejection of corrupt downloaded bytes. It does not activate the core or alter network settings.
