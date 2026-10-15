#!/usr/bin/env python3
"""Explicit administrator-only TUN acceptance. Defaults to a read-only dry run.

Only --activate can request sudo authorization or start the shipped helper.
The script never reads, stores, or passes an administrator password.
"""

from __future__ import annotations

import argparse
import contextlib
import ctypes
from dataclasses import dataclass, replace
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
from integration import (  # noqa: E402
    ROOT, TCPServer, Observations, capture_network, compare_network, receive,
    relay, require, socks_address,
)
import socketserver  # noqa: E402


DEFAULT_HELPER = ROOT / "dist/App Proxy.app/Contents/MacOS/AppProxyHelper"
EVIDENCE = ROOT / "dist/privileged-acceptance.json"
CLIENT_TIMEOUT = 10


class ProcBSDInfo(ctypes.Structure):
    """Public Darwin proc_bsdinfo, from <sys/proc_info.h> (PROC_PIDTBSDINFO)."""

    _fields_ = [
        (name, ctypes.c_uint32) for name in (
            "flags", "status", "exit_status", "pid", "ppid", "uid", "gid",
            "real_uid", "real_gid", "saved_uid", "saved_gid", "reserved",
        )
    ] + [
        ("command", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
        ("open_files", ctypes.c_uint32), ("group_id", ctypes.c_uint32),
        ("job_count", ctypes.c_uint32), ("terminal", ctypes.c_uint32),
        ("terminal_group", ctypes.c_uint32), ("nice", ctypes.c_int32),
        ("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64),
    ]


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    ppid: int
    uid: int
    real_uid: int
    executable: str
    start_seconds: int
    start_microseconds: int


@dataclass(frozen=True)
class ProcessObservation:
    identity: ProcessIdentity
    command: str


def native_identity(pid):
    """Read kernel UID/parent/start time and executable, rejecting a torn read."""
    require(type(pid) is int and pid > 1, "invalid process identity request")
    require(ctypes.sizeof(ProcBSDInfo) == 136, "unexpected Darwin proc_bsdinfo ABI")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int

    def bsd_info():
        value = ProcBSDInfo()
        size = ctypes.sizeof(value)
        require(library.proc_pidinfo(pid, 3, 0, ctypes.byref(value), size) == size,
                "could not read complete native process identity")
        require(value.pid == pid and value.start_seconds > 0 and value.start_microseconds < 1_000_000,
                "invalid native process identity")
        return (value.pid, value.ppid, value.uid, value.real_uid, value.start_seconds, value.start_microseconds)

    before = bsd_info()
    path = ctypes.create_string_buffer(4096)
    require(library.proc_pidpath(pid, path, len(path)) > 0, "could not read native executable path")
    after = bsd_info()
    require(before == after, "process identity changed during native inspection")
    return ProcessIdentity(*after[:4], os.fsdecode(path.value), *after[4:])


def observe_process(pid):
    before = native_identity(pid)
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=5)
    require(result.returncode == 0 and result.stdout.strip(), "could not read process arguments")
    after = native_identity(pid)
    require(before == after, "process identity changed while inspecting arguments")
    return ProcessObservation(after, result.stdout.strip())


def observe_parent_chain(pid, launcher_pid, observer=observe_process):
    chain = []
    seen = set()
    for _ in range(8):
        require(pid > 1 and pid not in seen, "process ancestry does not reach this session launcher")
        seen.add(pid)
        observation = observer(pid)
        require(observation.identity.pid == pid, "process ancestry identity differs")
        chain.append(observation)
        if pid == launcher_pid:
            return tuple(chain)
        pid = observation.identity.ppid
    raise RuntimeError("process ancestry exceeds eight hops")


def validate_chain(chain, launcher, helper, helper_command):
    """Pure check: only this launcher's exact helper may parent the staged core."""
    require(2 <= len(chain) <= 8, "invalid session process ancestry length")
    require(len({item.identity.pid for item in chain}) == len(chain), "cyclic session process ancestry")
    for child, parent in zip(chain, chain[1:]):
        require(child.identity.ppid == parent.identity.pid, "session process parent chain differs")
        require((parent.identity.start_seconds, parent.identity.start_microseconds) <=
                (child.identity.start_seconds, child.identity.start_microseconds),
                "session ancestor is newer than its child")
    anchor = chain[-1].identity
    require((anchor.pid, anchor.ppid, anchor.start_seconds, anchor.start_microseconds) ==
            (launcher.pid, launcher.ppid, launcher.start_seconds, launcher.start_microseconds),
            "process ancestry belongs to another or replaced launcher")
    core = chain[0]
    stage = re.fullmatch(r"/private/tmp/app-proxy-runtime\.[A-Za-z0-9]+/sing-box", core.identity.executable)
    require(core.identity.uid == 0 and core.identity.real_uid == 0 and stage is not None,
            "candidate is not a native root staged core")
    expected_core = core.identity.executable + " run -c " + str(Path(core.identity.executable).parent / "config.json")
    require(core.command == expected_core, "staged core arguments differ")
    supervisor = chain[1]
    require(supervisor.identity.uid == 0 and supervisor.identity.real_uid == 0 and
            supervisor.identity.executable == str(helper) and supervisor.command == helper_command,
            "core does not belong to this exact session helper")
    require(all(item.identity.executable == "/usr/bin/sudo" for item in chain[2:]),
            "unexpected process between this helper and its sudo launcher")
    return True


def require_same_observations(before, after):
    require(before == after, "process identity, start time, or arguments changed before signaling")


def signal_guard_self_test(helper):
    helper_command = str(helper) + " run --session /private/session-one --owner 501 --parent 100"
    launcher = ProcessIdentity(500, 100, 0, 501, "/usr/bin/sudo", 1000, 10)
    supervisor = ProcessIdentity(501, 500, 0, 0, str(helper), 1001, 10)
    core = ProcessIdentity(502, 501, 0, 0, "/private/tmp/app-proxy-runtime.ABC123/sing-box", 1002, 10)
    command = core.executable + " run -c /private/tmp/app-proxy-runtime.ABC123/config.json"
    chain = (ProcessObservation(core, command), ProcessObservation(supervisor, helper_command), ProcessObservation(launcher, "sudo acceptance"))
    require(validate_chain(chain, launcher, helper, helper_command), "valid synthetic chain was rejected")

    def rejected(operation):
        try:
            operation()
        except RuntimeError:
            return True
        raise RuntimeError("unsafe synthetic signal target was accepted")

    # The former path/UID-only check would have accepted this unrelated root core.
    other_launcher = replace(launcher, pid=900, ppid=1)
    other_supervisor = replace(supervisor, pid=901, ppid=900)
    other_core = replace(core, pid=902, ppid=901)
    unrelated = (ProcessObservation(other_core, command), ProcessObservation(other_supervisor, helper_command), ProcessObservation(other_launcher, "other sudo"))
    rejected(lambda: validate_chain(unrelated, launcher, helper, helper_command))
    other_session = (chain[0], ProcessObservation(supervisor, helper_command.replace("session-one", "session-two")), chain[2])
    rejected(lambda: validate_chain(other_session, launcher, helper, helper_command))
    changed_birth = (ProcessObservation(replace(core, start_microseconds=11), command), *chain[1:])
    rejected(lambda: require_same_observations(chain, changed_birth))
    replaced_launcher = (*chain[:-1], ProcessObservation(replace(launcher, start_microseconds=11), "sudo acceptance"))
    rejected(lambda: validate_chain(replaced_launcher, launcher, helper, helper_command))
    rejected(lambda: validate_chain((ProcessObservation(replace(core, ppid=999), command), *chain[1:]), launcher, helper, helper_command))
    mapping = {item.identity.pid: item for item in chain}
    require(observe_parent_chain(502, 500, mapping.__getitem__) == chain, "exact synthetic parent walk differs")
    rejected(lambda: observe_parent_chain(902, 500, {item.identity.pid: item for item in unrelated}.__getitem__))

    child = subprocess.Popen(["/bin/sleep", "10"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        actual = observe_parent_chain(child.pid, os.getpid())
        first = actual[0].identity
        require(first.ppid == os.getpid() and first.uid == os.geteuid() and first.real_uid == os.getuid() and
                first.executable == "/bin/sleep" and len(actual) == 2,
                "native current-user child identity or ancestry differs")
        require_same_observations(actual, observe_parent_chain(child.pid, os.getpid()))
    finally:
        child.terminate()
        child.wait(timeout=5)
    return {"exact_parent_chain_accepted": True, "unrelated_root_staged_core_rejected": True,
            "another_session_helper_rejected": True, "changed_birthtime_rejected": True,
            "replaced_launcher_rejected": True, "native_sleep_child_verified": True,
            "privileged_signal_sent": False}


def private_json(path, value):
    temporary = path.parent / (".pending-" + str(uuid.uuid4()))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def clean_environment():
    return {key: value for key, value in os.environ.items() if not key.lower().endswith("_proxy")}


def disposable_application(directory):
    # proc_pidpath resolves /var -> /private/var; rules must use that same path.
    bundle = directory.resolve() / "Selected Curl.app"
    executable = bundle / "Contents/MacOS/IntegrationCurl"
    executable.parent.mkdir(parents=True, mode=0o700)
    # Copy bytes only: copy2 attempts to replicate macOS's restricted system-file
    # flags, which a normal desktop user cannot set on a disposable executable.
    shutil.copyfile("/usr/bin/curl", executable)
    executable.chmod(0o700)
    signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)], capture_output=True, timeout=10)
    require(signed.returncode == 0, "could not ad-hoc sign the disposable curl copy")
    with (bundle / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "local.app-proxy.acceptance", "CFBundleName": "Selected Curl", "CFBundleExecutable": "IntegrationCurl", "CFBundlePackageType": "APPL"}, stream)
    result = subprocess.run([str(executable), "--disable", "--version"], capture_output=True, timeout=5)
    require(result.returncode == 0, "the disposable curl executable could not run")
    require(str(executable) != "/usr/bin/curl", "selected and unmatched executable paths must differ")
    return bundle, executable


class PublicProxy:
    """Authenticated SOCKS5 fixture restricted to one explicitly chosen IP:443."""

    def __init__(self, target_ip):
        self.target = (target_ip, 443)
        self.username = "acceptance-" + secrets.token_hex(6)
        self.password = secrets.token_hex(16)
        self.connections = Observations()
        self.rejected_destinations = Observations()
        self.server = None
        self.thread = None

    def __enter__(self):
        fixture = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                sock = self.request
                sock.settimeout(CLIENT_TIMEOUT)
                version, length = receive(sock, 2)
                methods = receive(sock, length)
                if version != 5 or 2 not in methods:
                    sock.sendall(b"\x05\xff")
                    return
                sock.sendall(b"\x05\x02")
                if receive(sock, 1) != b"\x01":
                    return
                username = receive(sock, receive(sock, 1)[0]).decode()
                password = receive(sock, receive(sock, 1)[0]).decode()
                authenticated = secrets.compare_digest(username, fixture.username) and secrets.compare_digest(password, fixture.password)
                sock.sendall(b"\x01\x00" if authenticated else b"\x01\x01")
                if not authenticated or receive(sock, 3) != b"\x05\x01\x00":
                    return
                destination = socks_address(sock)
                if destination != fixture.target:
                    fixture.rejected_destinations.append(destination)
                    sock.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
                    return
                try:
                    with socket.create_connection(destination, CLIENT_TIMEOUT) as upstream:
                        fixture.connections.append(destination)
                        sock.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                        relay(sock, upstream)
                except OSError:
                    with contextlib.suppress(OSError):
                        sock.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")

        self.server = TCPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        return self

    def close(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
            self.thread.join(5)
            self.server = None

    def __exit__(self, *args):
        self.close()


class HelperSession:
    instances = []

    def __init__(self, helper, bundle, executable, proxy):
        self.helper = helper
        self.owner = os.getuid()
        self.parent = os.getpid()
        self.token = str(uuid.uuid4()).upper() + str(uuid.uuid4()).upper()
        self.proxy_id = str(uuid.uuid4()).upper()
        self.bundle = bundle
        self.executable = executable
        self.proxy = proxy
        self.process = None
        self.launch_identity = None
        self.thread = None
        self.heartbeat_error = None
        self.heartbeat_stop = threading.Event()
        self.root_created = []

    def __enter__(self):
        actual_home = Path(pwd.getpwuid(self.owner).pw_dir)
        root = actual_home / "Library/Application Support/App Proxy/Sessions"
        for ancestor in reversed((root, *root.parents)):
            if not ancestor.exists():
                ancestor.mkdir(mode=0o700)
                self.root_created.append(ancestor)
        self.directory = root / str(uuid.uuid4()).upper()
        self.directory.mkdir(mode=0o700)
        try:
            request = {
                "configuration": {
                    "version": 1,
                    "proxies": [{"id": self.proxy_id, "name": "Disposable acceptance SOCKS5", "kind": "socks5", "host": "127.0.0.1", "port": self.proxy.port, "username": self.proxy.username, "hasPassword": True}],
                    "rules": [{"id": str(uuid.uuid4()).upper(), "name": "Disposable selected curl", "appPath": str(self.bundle), "executablePath": str(self.executable), "proxyID": self.proxy_id, "enabled": True, "includeHelpers": True}],
                },
                "passwords": {self.proxy_id: self.proxy.password},
                "parentPID": self.parent, "ownerUID": self.owner, "token": self.token,
            }
            require(set(request) == {"configuration", "passwords", "parentPID", "ownerUID", "token"}, "request protocol keys differ")
            require(len(self.token) == 72 and self.directory.name == str(uuid.UUID(self.directory.name)).upper(), "session identifiers differ from helper protocol")
            private_json(self.directory / "request.json", request)
            self.heartbeat()
            require(stat.S_IMODE(self.directory.stat().st_mode) == 0o700, "session directory is not private")
            require(stat.S_IMODE((self.directory / "request.json").stat().st_mode) == 0o600, "request file is not private")
            self.thread = threading.Thread(target=self.keep_alive, daemon=True)
            self.thread.start()
            self.instances.append(self)
            return self
        except BaseException:
            shutil.rmtree(self.directory)
            raise

    def heartbeat(self):
        private_json(self.directory / "heartbeat", {"token": self.token, "timestamp": time.time()})

    def keep_alive(self):
        while not self.heartbeat_stop.wait(0.5):
            try:
                self.heartbeat()
            except OSError:
                self.heartbeat_error = True
                return

    def check(self):
        result = subprocess.run([str(self.helper), "check", "--session", str(self.directory)], capture_output=True, timeout=20)
        require(result.returncode == 0, "bundled helper read-only configuration check failed")

    def status(self):
        try:
            descriptor = os.open(self.directory / "status.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            return None
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == self.owner and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size < 524288, "unsafe helper status file")
            return json.load(stream)

    def start(self):
        self.check()
        self.process = subprocess.Popen(["/usr/bin/sudo", "-n", "--", str(self.helper), "run", "--session", str(self.directory), "--owner", str(self.owner), "--parent", str(self.parent)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.launch_identity = native_identity(self.process.pid)
        require(self.launch_identity.ppid == os.getpid(), "sudo launcher is not this acceptance process's child")
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            require(not self.heartbeat_error, "session heartbeat failed")
            status = self.status()
            if status and status.get("phase") == "running":
                return status
            if self.process.poll() is not None or status and status.get("phase") == "failed":
                raise RuntimeError("privileged helper failed before reporting running; inspect application status")
            time.sleep(0.1)
        raise RuntimeError("privileged helper startup timed out")

    def signal_core(self, number):
        require(number in (signal.SIGTERM, signal.SIGKILL), "unsupported core acceptance signal")
        require(self.process is not None and self.process.poll() is None and self.launch_identity is not None,
                "session launcher is no longer alive or was not identified")
        status = self.status()
        pid = status.get("corePID") if status else None
        require(type(pid) is int and pid > 1, "helper did not report a valid core PID")
        helper_command = f"{self.helper} run --session {self.directory} --owner {self.owner} --parent {self.parent}"
        before = observe_parent_chain(pid, self.process.pid)
        validate_chain(before, self.launch_identity, self.helper, helper_command)
        after = observe_parent_chain(pid, self.process.pid)
        validate_chain(after, self.launch_identity, self.helper, helper_command)
        require_same_observations(before, after)
        # Re-read native identity immediately before invoking the fixed signal
        # command: executable, UID, parent, and microsecond birth time must agree.
        require(native_identity(pid) == after[0].identity and
                native_identity(self.process.pid) == after[-1].identity,
                "core or launcher identity changed immediately before signaling")
        current = self.status()
        require(current is not None and current.get("corePID") == pid and self.process.poll() is None,
                "core PID or live session changed before signaling")
        result = subprocess.run(["/usr/bin/sudo", "-n", "--", "/bin/kill", "-" + signal.Signals(number).name.removeprefix("SIG"), str(pid)], capture_output=True, timeout=5)
        require(result.returncode == 0, "signaling the validated session core failed")
        return pid

    def wait_exit(self, timeout):
        if self.process is None:
            return
        self.process.wait(timeout=timeout)

    def stop(self):
        if self.process is None:
            return
        if self.process.poll() is None:
            stop = self.directory / "stop"
            temporary = self.directory / (".pending-" + str(uuid.uuid4()))
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(self.token)
            os.replace(temporary, stop)
            try:
                self.wait_exit(15)
            except subprocess.TimeoutExpired:
                # Keep the heartbeat alive while asking the supervisor to handle
                # its own core's exit. Never kill a helper and orphan its core.
                self.signal_core(signal.SIGTERM)
                try:
                    self.wait_exit(8)
                except subprocess.TimeoutExpired:
                    self.signal_core(signal.SIGKILL)
                    self.wait_exit(8)

    def __exit__(self, *args):
        try:
            self.stop()
        finally:
            self.heartbeat_stop.set()
            if self.thread:
                self.thread.join(2)
            # Preserve a still-active session and its STOP request for recovery.
            if self.process is None or self.process.poll() is not None:
                shutil.rmtree(self.directory)
                for ancestor in reversed(self.root_created):
                    with contextlib.suppress(OSError):
                        ancestor.rmdir()


def curl(executable, host, address):
    command = [str(executable), "--disable", "--ipv4", "--silent", "--show-error", "--fail", "--http1.1", "--max-time", str(CLIENT_TIMEOUT), "--connect-timeout", "5", "--noproxy", "*", "--proxy", "", "--resolve", f"{host}:443:{address}", "--header", "Connection: close", "--output", "/dev/null", "--write-out", "%{http_code}", f"https://{host}/"]
    result = subprocess.run(command, capture_output=True, env=clean_environment(), timeout=CLIENT_TIMEOUT + 2)
    status = result.stdout.decode("ascii", errors="replace").strip()
    return {"ok": result.returncode == 0 and status.isdigit() and 200 <= int(status) < 400, "exit_code": result.returncode, "http_status": status if status.isdigit() else "unavailable"}


def public_address(host, explicit):
    require(re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?", host) is not None and ".." not in host, "test host must be an explicit DNS hostname")
    if explicit:
        addresses = [explicit]
    else:
        lookup = subprocess.run([sys.executable, "-c", "import json,socket,sys; print(json.dumps([v[4][0] for v in socket.getaddrinfo(sys.argv[1],443,socket.AF_INET,socket.SOCK_STREAM)]))", host], capture_output=True, timeout=8)
        require(lookup.returncode == 0, "public test hostname could not be resolved before activation")
        addresses = json.loads(lookup.stdout)
    for address in addresses:
        value = ipaddress.ip_address(address)
        if value.version == 4 and value.is_global:
            return str(value)
    raise RuntimeError("no public IPv4 test address; supply --host and --ip for a reachable TLS endpoint")


def restoration(before):
    deadline = time.monotonic() + 5
    while True:
        comparison = compare_network(before, capture_network())
        if all(item["unchanged"] for item in comparison.values()) or time.monotonic() >= deadline:
            return comparison
        time.sleep(0.25)


def unchanged(comparison):
    return all(item["unchanged"] for item in comparison.values())


def self_test(helper):
    require(helper.is_file(), "build the application bundle before --self-test")
    before = capture_network()
    guard = signal_guard_self_test(helper)
    # Foundation can standardize /private/var aliases differently from Darwin's
    # executable paths. Keep the disposable app under the real repository path.
    (ROOT / "dist").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="acceptance-self-test-", dir=ROOT / "dist") as temporary:
        directory = Path(temporary)
        bundle, executable = disposable_application(directory)
        # The fixture never receives a connection during helper config checks.
        with PublicProxy("93.184.215.14") as fixture:
            with HelperSession(helper, bundle, executable, fixture) as session:
                session.check()
                request = json.loads((session.directory / "request.json").read_text())
                require(request["ownerUID"] == os.getuid() and request["parentPID"] == os.getpid(), "session identity mismatch")
                require(request["configuration"]["rules"][0]["executablePath"] == str(executable), "selected executable differs from request")
                require(fixture.connections.count() == 0, "read-only check contacted public fixture")
            require(not session.directory.exists(), "self-test session was not cleaned")
    state = restoration(before)
    require(unchanged(state), "network state changed during read-only self-test")
    return {"mode": "self-test", "passed": True, "tun_started": False, "sudo_invoked": False, "actual_bundled_helper_check": True, "request_protocol_and_permissions_verified": True, "disposable_executable_runs": True, "core_signal_guard": guard, "network_state": state}


def activate(helper, host, address):
    result = {"mode": "privileged-acceptance", "passed": False, "test_host": host, "test_ipv4": address, "udp_tun": "unverified; separate application fallback acceptance required", "ipv6_tun": "unverified; this test requires public IPv4 TLS", "tun_start_attempted": False}
    before = capture_network()
    try:
        require(os.geteuid() != 0, "run as your normal desktop user; the script invokes sudo only for fixed helper/process actions")
        require(helper.is_file(), "build the application bundle before --activate")
        baseline = curl(Path("/usr/bin/curl"), host, address)
        require(baseline["ok"], "public HTTPS baseline failed before TUN activation")
        result["public_https_baseline"] = baseline
        # Inherit the user's terminal. The sudo executable owns the password prompt.
        authorization = subprocess.run(["/usr/bin/sudo", "-v"], timeout=120)
        require(authorization.returncode == 0, "administrator authorization was canceled or failed")
        with tempfile.TemporaryDirectory(prefix="acceptance-", dir=ROOT / "dist") as temporary:
            directory = Path(temporary)
            bundle, executable = disposable_application(directory)
            with PublicProxy(address) as fixture, HelperSession(helper, bundle, executable, fixture) as session:
                result["tun_start_attempted"] = True
                session.start()
                count = fixture.connections.count()
                selected = curl(executable, host, address)
                delta = fixture.connections.count() - count
                require(selected["ok"] and delta >= 1, "selected executable did not reach HTTPS through the local upstream")
                result["selected_tcp"] = {**selected, "authenticated_upstream_handshakes": delta}
                count = fixture.connections.count()
                unmatched = curl(Path("/usr/bin/curl"), host, address)
                delta = fixture.connections.count() - count
                require(unmatched["ok"] and delta == 0, "unmatched system curl did not remain direct")
                result["unmatched_tcp"] = {**unmatched, "upstream_handshakes": delta}
                fixture.close()
                failure = curl(executable, host, address)
                require(not failure["ok"] and failure["exit_code"] != 0, "selected TCP succeeded after its upstream stopped; possible direct fallback or missing attribution")
                result["upstream_failure"] = {**failure, "no_direct_fallback_observed": True}
                session.stop()
                status = session.status()
                require(status and status.get("phase") == "stopped", "normal STOP did not produce stopped helper status")
                result["normal_stop"] = {"phase": status["phase"], "helper_exited": session.process.poll() is not None}
            result["after_stop_network_state"] = restoration(before)
            require(unchanged(result["after_stop_network_state"]), "network state differs after normal STOP")

            with PublicProxy(address) as fixture, HelperSession(helper, bundle, executable, fixture) as session:
                session.start()
                count = fixture.connections.count()
                selected = curl(executable, host, address)
                require(selected["ok"] and fixture.connections.count() > count, "second TUN session did not proxy selected HTTPS before crash")
                session.signal_core(signal.SIGKILL)
                session.wait_exit(15)
                status = session.status()
                require(status and status.get("phase") == "failed", "supervisor did not report the core crash")
                result["core_sigkill"] = {"helper_exited": session.process.poll() is not None, "helper_phase": status["phase"], "crash_reported": True}
            result["after_core_crash_network_state"] = restoration(before)
            require(unchanged(result["after_core_crash_network_state"]), "network state differs after supervised core SIGKILL")
        result["private_sessions_and_disposable_app_removed"] = not directory.exists()
        result["passed"] = True
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
    finally:
        result["final_network_state"] = restoration(before)
        result["helpers_exited"] = all(session.process is None or session.process.poll() is not None for session in HelperSession.instances)
        result["private_session_directories_removed"] = all(not session.directory.exists() for session in HelperSession.instances)
        if not unchanged(result["final_network_state"]):
            result["passed"] = False
            result["error"] = "network state differs after cleanup; inspect network and application status without replaying old snapshots"
        if not result["helpers_exited"] or not result["private_session_directories_removed"]:
            result["passed"] = False
            result["error"] = "helper cleanup incomplete; a private session and STOP request have been preserved for recovery"
        EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
        private_json(EVIDENCE, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--activate", action="store_true", help="Explicitly authorize live TUN testing with sudo; temporarily changes routing")
    modes.add_argument("--self-test", action="store_true", help="Check actual helper request protocol with no sudo, external connections, or TUN")
    parser.add_argument("--helper", type=Path, default=DEFAULT_HELPER)
    parser.add_argument("--host", default="example.com", help="Explicit public HTTPS test hostname (default example.com)")
    parser.add_argument("--ip", help="Optional public IPv4 address used by TLS-verified curl --resolve")
    arguments = parser.parse_args()

    def interrupted(signum, frame):
        # A non-OSError exception unwinds socket/select retry loops and contexts.
        raise RuntimeError(f"acceptance interrupted by signal {signum}")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        if arguments.self_test:
            result = self_test(arguments.helper.resolve())
        elif arguments.activate:
            address = public_address(arguments.host, arguments.ip)
            result = activate(arguments.helper.resolve(), arguments.host, address)
        else:
            result = {"mode": "dry-run", "status": "not_run", "tun_started": False, "sudo_invoked": False, "activation_command": "python3 scripts/privileged-acceptance.py --activate", "checks": ["public TLS baseline", "copied curl process selection", "system curl direct", "upstream failure without direct fallback", "STOP route/DNS/proxy restoration", "root core SIGKILL and supervised restoration"], "evidence_path": str(EVIDENCE.relative_to(ROOT)), "udp_tun": "unverified", "ipv6_tun": "unverified"}
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("passed", True) else 1
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result = {"passed": False, "error": str(error), "mode": "preflight", "activation_requested": arguments.activate}
        if arguments.activate:
            EVIDENCE.parent.mkdir(parents=True, exist_ok=True)
            private_json(EVIDENCE, result)
        print(json.dumps(result), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
