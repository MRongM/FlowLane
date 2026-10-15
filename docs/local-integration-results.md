# Local core integration evidence

Run on 2026-10-15, macOS 26.6 (25G72), arm64, without administrator
authorization. Command from the repository root:

```sh
python3 scripts/integration.py
```

The command exited 0 and emitted `passed: true`. It ran sing-box 1.14.3 from
`downloaded-binaries/sing-box`; executable SHA-256:
`28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2`.
The official release/archive pin is recorded in
[the third-party manifest](../ThirdParty/sing-box/release.json).

## Observed results

The fixtures are independent Python standard-library servers, listening only on
IPv4 loopback. They implement SOCKS5 username/password authentication and HTTP
CONNECT Basic authentication, restrict forwarding to the local HTTP target, and
count completed authenticated upstream handshakes. Each successful client must
receive a request-specific body from the HTTP target; successful socket creation
alone does not pass a test. Credentials are newly generated synthetic test values
and never printed or retained.

| Check | Actual observation |
| --- | --- |
| Select `/usr/bin/curl` using core `process_path` | Three requests: SOCKS5 upstream handshake counts `[1, 1, 1]`; Python requests under the same rule: `[0, 0, 0]`; every response body verified. |
| Select Python using core `process_path` | Three requests: HTTP CONNECT upstream handshake counts `[1, 1, 1]`; curl requests under the same rule: `[0, 0, 0]`; every response body verified. |
| Independent SOCKS5 transport check | One authenticated handshake; observed destination `127.0.0.1:<HTTP fixture port>`; response body verified. |
| Independent HTTP CONNECT transport check | One authenticated CONNECT; observed the same local destination; response body verified. |
| Explicit unavailable SOCKS5 upstream | A reserved, non-listening loopback port produced client failure (curl exit 28 within its four-second deadline); the HTTP target received zero requests. No direct fallback was observed. |
| Unmatched UDP control | Python sent a SOCKS5 UDP datagram with a curl-only UDP rejection rule. The local UDP echo fixture received one datagram, and Python received its echo through the core's final direct outbound. |
| Matched UDP rejection | Changing that rejection rule to the actual Python executable yielded no reply and zero datagrams at the same UDP fixture. |
| Representative IPv4 and IPv6 TUN configuration | The real core's `check -c` accepted a harness-generated TUN inbound containing both addresses, automatic interface detection, explicit `dns_mode: disabled`, DNS port 53 direct, selected UDP reject, selected TCP proxy, and final direct. This configuration was never started. This row does not claim validation of the Swift product compiler. |
| Actual Swift product compiler | `integration.py --helper .../AppProxyHelper` exited 0 with `product_compiler_check.passed: true`. The bundled helper compiled authenticated SOCKS5 and HTTP profiles with helper-inclusive and exact-path rules, copied and digest-verified its core, and the real core accepted that generated dual-family TUN configuration. No TUN was started. |
| Normal cleanup | All seven started core processes had exited, and the private directory containing all eight generated configs and the logs was removed. |

Darwin's `proc_pidpath` identified the interpreter as
`/Users/longjiang/miniforge3/bin/python3.12`; process rules used that executable
path, rather than the script path. Python 3.12.10 and system curl 8.7.1 were used.
The two reversed selection trials provide actual core routing evidence for both
executables, including direct behavior of the other executable under each rule.

The optional bundled-product check is separate:

```sh
python3 scripts/integration.py \
  --helper "$PWD/dist/App Proxy.app/Contents/MacOS/AppProxyHelper"
```

This command was also run successfully. It passes a private synthetic structured session request to `AppProxyHelper
check`, which runs the actual Swift configuration compiler and checks the result
with its copied, SHA-256-verified bundled core. The request covers authenticated
SOCKS5/HTTP profiles and both bundle-helper and exact-executable rule generation.
It uses the helper's fixed `check` verb; no TUN is started. Without this option,
the summary explicitly reports that the product compiler check was not run.

A separate temporary log probe confirmed that INFO level emits the discovered
executable (`router: found process path: /usr/bin/curl`) and the chosen outbound
(`outbound/socks[socks-upstream]`) with a shared connection ID. DEBUG additionally
emits the exact rule index and matcher (`match[0] network=tcp
process_path=/usr/bin/curl => route(socks-upstream)`). Neither log contained the
synthetic fixture username or password. The probe logs were removed. INFO is
sufficient for showing the identified process and selected outbound; exact rule
index diagnostics require DEBUG.

## Network state and cleanup

Before starting fixtures or the core, and after all contexts stopped, the harness
read IPv4/IPv6 routes with `netstat -rn -f inet` and `inet6`, DNS with
`scutil --dns`, and system proxy configuration with `scutil --proxy`. No route,
DNS, proxy, or network service mutation commands are present in the harness.
Its runtime guard permits only `socks` or `mixed` inbounds with an explicit
`127.0.0.1` listen address, and refuses to start a TUN inbound.

Route comparison sorts and retains destination, gateway, flags, and interface.
It omits expiry/counter columns and entries containing the `L` link-layer-info
flag (ARP/neighbor cache state), which can change as unrelated applications
communicate. DNS and system proxy output are compared exactly, apart from
leading/trailing whitespace. These comparisons retain pre-existing interfaces,
including those belonging to other networking tools; the harness never attempts
to restore a whole old snapshot over another application's state.

The following SHA-256 values were identical before and after the successful run
(route hashes encode the sorted normalized rows as JSON; DNS/proxy hashes encode
the normalized strings as JSON):

| State | Matching before/after SHA-256 |
| --- | --- |
| IPv4 routes | `159805868c7bd77c46fbdac407094282d1c48253bb2737c67c84838a01ac3224` |
| IPv6 routes | `66e97d37e69c6418dbd14fc55e6f866b2e628a14eb01e03c9835dbfb6b61b8d1` |
| DNS | `eee9cf88daf6c25c313a545c947efebf3876e3222e9ae875a7286c9cb8d1cc6f` |
| System proxy | `8b44ad487d95d2136691650034ae477ffb4949fab881c01e19629035fa58fcd1` |

Temporary directories are mode 0700, and configs/core log files are created with
mode 0600. Core logging is disabled. The harness prints neither runtime config
nor captured core output. Core startup, clients, fixture relays, and process
shutdown all have deadlines; core shutdown escalates from terminate to kill.
Fixtures are closed and private files removed on an exception as well as success.

Additional interruption checks sent SIGTERM to the harness 0.4 seconds and 1.0
seconds after launch, exercising interruption during startup and active work.
Both returned failure JSON with the signal recorded, all core processes stopped,
the private directory removed, and all four network comparisons unchanged.
SIGINT, SIGTERM, and SIGHUP use the same cleanup path. SIGKILL cannot execute
Python cleanup and is outside this claim.

## Limits of this evidence

- This proves local IPv4 forwarding and Darwin executable attribution through
  explicit loopback SOCKS connections on this host. It does not prove transparent
  TUN interception, helper/XPC ownership coverage, short-lived socket attribution,
  cross-user attribution, or behavior on other macOS versions.
- The IPv6 TUN configuration was accepted by the real core parser. No IPv6 TCP
  forwarding or administrator-authorized TUN operation was exercised.
- The UDP check proves a selected-process rejection rule and unmatched direct
  behavior through SOCKS UDP. It does not implement or claim UDP proxying through
  SOCKS5/HTTP CONNECT upstreams, or verify QUIC-to-TCP fallback in applications.
- Numeric loopback targets avoid DNS. Runtime DNS is designed to stay direct;
  these tests verify unchanged system DNS, without demonstrating DNS privacy or
  per-application resolver ownership. Shared system resolvers cannot reliably be
  assigned to an initiating app by its bundle path.
- The upstream failure observation covers a refused local SOCKS5 upstream during
  a bounded request. Broader upstream failures, physical-network changes, TUN
  stop/crash route removal, and recovery still require the explicit privileged
  acceptance procedure.
- Network snapshots can detect concurrent changes and fail the command, but
  cannot establish which application caused a concurrent external change. Neighbor
  cache entries excluded above are outside the snapshot equality assertion.

## Explicit administrator acceptance still pending

The following commands were run successfully without authorization or TUN:

```sh
python3 scripts/privileged-acceptance.py
python3 scripts/privileged-acceptance.py --self-test
```

The dry run reports `status: not_run`. The self-test reported `passed: true`,
`sudo_invoked: false`, `tun_started: false`, and matching network hashes. It
created a disposable `.app` containing a byte-only copy of system curl, ad-hoc
signed that copy, verified it runs, created the actual private helper session
request/heartbeat protocol, and invoked the shipped helper's read-only check.
The local fixture accepted zero external forwarding connections. The copied
application and session were then removed. No developer account is required for
that ad-hoc signature.

The remaining user command is:

```sh
python3 scripts/privileged-acceptance.py --activate
```

**This command has not been run.** It explicitly requests `sudo -v` using the
user's terminal; the script never accepts or handles a password. It can
temporarily change routing by starting the shipped helper's TUN session. It uses
an explicitly chosen public IPv4 address for `https://example.com/`, TLS
verification and curl `--resolve`, so the target is outside loopback/local-route
bypasses and the test does not depend on transparent DNS interception. An
alternative reachable TLS endpoint can be supplied with `--host HOST --ip IPV4`.
Only public IPv4 addresses are accepted, and its authenticated local SOCKS fixture
will forward only to that one address on port 443.

The live sequence checks copied-curl selection, unmatched system-curl direct
behavior, selected TCP failure after stopping the upstream, STOP and network
snapshot equality, then a fresh session in which the root core receives SIGKILL
and the supervisor must exit and restore its changed state. Before signaling a
core, it validates the reported PID against the root-owned, staged
`/private/tmp/app-proxy-runtime.*/sing-box run -c .../config.json` command. It
maintains the owner/session heartbeat through normal cleanup and sends the
session STOP token on failure. It does not replay captured routes, DNS, or proxy
settings. A session that cannot be stopped is preserved with its STOP request for
recovery and reported as a failure.

The live command saves sanitized success/failure evidence to ignored
`dist/privileged-acceptance.json`; credentials, raw runtime configs, and raw
network snapshots are excluded. Its public IPv4 TCP scope is explicit: it reports
TUN IPv6 and application UDP/QUIC fallback acceptance as unverified. The
administrator lifecycle path itself remains unverified until that command runs.
