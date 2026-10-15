#!/usr/bin/env python3
"""Unprivileged, loopback-only integration checks for the pinned sing-box core.

No TUN is started. Network state is observed using read-only system commands.
Temporary configurations contain synthetic credentials and are never printed.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import ctypes
import hashlib
import http.server
import ipaddress
import json
import os
from pathlib import Path
import platform
import secrets
import select
import signal
import shutil
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 4


def receive(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("unexpected socket EOF")
        data += chunk
    return data


def socks_address(sock):
    kind = receive(sock, 1)[0]
    if kind == 1:
        host = socket.inet_ntop(socket.AF_INET, receive(sock, 4))
    elif kind == 4:
        host = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    elif kind == 3:
        host = receive(sock, receive(sock, 1)[0]).decode("ascii")
    else:
        raise ValueError("unsupported SOCKS address")
    return host, struct.unpack("!H", receive(sock, 2))[0]


def socks_command(sock, command, port):
    sock.sendall(b"\x05\x01\x00")
    if receive(sock, 2) != b"\x05\x00":
        raise ConnectionError("SOCKS greeting rejected")
    sock.sendall(b"\x05" + bytes([command]) + b"\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", port))
    reply = receive(sock, 3)
    if reply[:2] != b"\x05\x00":
        raise ConnectionError("SOCKS command rejected")
    return socks_address(sock)


def python_client(inbound_port, target_port, request_path):
    with socket.create_connection(("127.0.0.1", inbound_port), TIMEOUT) as sock:
        sock.settimeout(TIMEOUT)
        socks_command(sock, 1, target_port)
        sock.sendall(f"GET {request_path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
        result = bytearray()
        while chunk := sock.recv(65536):
            result.extend(chunk)
        body = bytes(result).split(b"\r\n\r\n", 1)[-1]
        return body == f"loopback-ok:{request_path}".encode()


class Observations:
    def __init__(self):
        self.lock = threading.Lock()
        self.items = []

    def append(self, value):
        with self.lock:
            self.items.append(value)

    def count(self):
        with self.lock:
            return len(self.items)

    def destinations(self):
        with self.lock:
            return [list(value) for value in self.items]


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False

    def handle_error(self, request, client_address):
        # Deliberately broken upstreams/closed clients are expected in these tests.
        pass


class UDPServer(socketserver.ThreadingUDPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


def relay(left, right):
    deadline = time.monotonic() + TIMEOUT
    peers = {left: right, right: left}
    while peers and time.monotonic() < deadline:
        ready, _, _ = select.select(list(peers), [], [], 0.2)
        for source in ready:
            destination = peers[source]
            data = source.recv(65536)
            if not data:
                with contextlib.suppress(OSError):
                    destination.shutdown(socket.SHUT_WR)
                del peers[source]
                continue
            destination.sendall(data)
            deadline = time.monotonic() + TIMEOUT


class Fixtures:
    def __init__(self):
        self.username = "local-test-" + secrets.token_hex(6)
        self.password = secrets.token_hex(16)
        self.http_requests = Observations()
        self.udp_requests = Observations()
        self.socks_connections = Observations()
        self.connect_connections = Observations()
        self.servers = []
        self.threads = []

    def serve(self, handler, udp=False):
        server = (UDPServer if udp else TCPServer)(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.servers.append(server)
        self.threads.append(thread)
        return server.server_address[1]

    def __enter__(self):
        fixtures = self

        class HTTP(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                fixtures.http_requests.append(self.path)
                body = f"loopback-ok:{self.path}".encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                fixtures.udp_requests.append(len(data))
                sock.sendto(data, self.client_address)

        self.target_port = self.serve(HTTP)
        self.udp_port = self.serve(Echo, udp=True)

        class SOCKS(socketserver.BaseRequestHandler):
            def handle(self):
                sock = self.request
                sock.settimeout(TIMEOUT)
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
                authenticated = secrets.compare_digest(username, fixtures.username) and secrets.compare_digest(password, fixtures.password)
                sock.sendall(b"\x01\x00" if authenticated else b"\x01\x01")
                if not authenticated:
                    return
                if receive(sock, 3) != b"\x05\x01\x00":
                    return
                destination = socks_address(sock)
                if destination != ("127.0.0.1", fixtures.target_port):
                    return
                with socket.create_connection(destination, TIMEOUT) as upstream:
                    fixtures.socks_connections.append(destination)
                    sock.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                    relay(sock, upstream)

        class CONNECT(socketserver.BaseRequestHandler):
            def handle(self):
                sock = self.request
                sock.settimeout(TIMEOUT)
                head = bytearray()
                while not head.endswith(b"\r\n\r\n"):
                    head.extend(receive(sock, 1))
                    if len(head) > 16384:
                        return
                lines = head.decode("ascii").split("\r\n")
                words = lines[0].split()
                authorization = next((line.split(":", 1)[1].strip() for line in lines[1:] if line.lower().startswith("proxy-authorization:")), "")
                expected = "Basic " + base64.b64encode(f"{fixtures.username}:{fixtures.password}".encode()).decode()
                if not secrets.compare_digest(authorization, expected):
                    sock.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
                    return
                destination = ("127.0.0.1", fixtures.target_port)
                if len(words) != 3 or words[0] != "CONNECT" or words[1] != f"127.0.0.1:{fixtures.target_port}":
                    return
                with socket.create_connection(destination, TIMEOUT) as upstream:
                    fixtures.connect_connections.append(destination)
                    sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                    relay(sock, upstream)

        self.socks_port = self.serve(SOCKS)
        self.connect_port = self.serve(CONNECT)
        return self

    def __exit__(self, *args):
        for server in self.servers:
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(TIMEOUT)


def executable_path():
    buffer = ctypes.create_string_buffer(4096)
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    if library.proc_pidpath(os.getpid(), buffer, len(buffer)) <= 0:
        raise RuntimeError("cannot determine Python executable path")
    return os.fsdecode(buffer.value)


def capture_network():
    """Exclude only link-layer neighbor caches and volatile route expiry/counters."""
    components = {}
    for family in ("inet", "inet6"):
        output = subprocess.run(["/usr/sbin/netstat", "-rn", "-f", family], capture_output=True, text=True, check=True, timeout=TIMEOUT).stdout
        routes = []
        headers = None
        for line in output.splitlines():
            fields = line.split()
            if fields and fields[0] == "Destination":
                headers = fields
            elif headers and len(fields) >= 4:
                record = dict(zip(headers, fields))
                if "L" in record.get("Flags", ""):
                    continue
                routes.append([record.get(key, "") for key in ("Destination", "Gateway", "Flags", "Netif")])
        components["routes_" + family] = sorted(routes)
    for name, flag in (("dns", "--dns"), ("system_proxy", "--proxy")):
        components[name] = subprocess.run(["/usr/sbin/scutil", flag], capture_output=True, text=True, check=True, timeout=TIMEOUT).stdout.strip()
    return components


def compare_network(before, after):
    return {
        key: {
            "unchanged": before[key] == after[key],
            "before_sha256": hashlib.sha256(json.dumps(before[key], sort_keys=True).encode()).hexdigest(),
            "after_sha256": hashlib.sha256(json.dumps(after[key], sort_keys=True).encode()).hexdigest(),
        }
        for key in before
    }


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Core:
    started_processes = []

    def __init__(self, binary, directory, config, name):
        self.binary = binary
        self.directory = directory
        self.config = config
        self.name = name
        self.process = None
        self.log = None

    def check(self):
        path = self.directory / (self.name + ".json")
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(self.config, stream)
        if path.stat().st_mode & 0o777 != 0o600:
            raise RuntimeError("runtime config permissions are not private")
        result = subprocess.run([str(self.binary), "check", "-c", str(path)], capture_output=True, timeout=TIMEOUT)
        if result.returncode:
            # Never print raw core output: it may contain runtime configuration.
            raise RuntimeError(f"core config check failed ({self.name}, exit {result.returncode})")
        self.path = path
        return True

    def __enter__(self):
        for inbound in self.config.get("inbounds", []):
            if inbound.get("type") not in {"socks", "mixed"} or inbound.get("listen") != "127.0.0.1":
                raise RuntimeError("refusing to start a non-loopback or TUN inbound")
        self.check()
        descriptor = os.open(self.directory / (self.name + ".log"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        self.log = os.fdopen(descriptor, "wb")
        try:
            self.process = subprocess.Popen([str(self.binary), "run", "-c", str(self.path)], stdout=self.log, stderr=self.log)
        except BaseException:
            self.log.close()
            raise
        self.started_processes.append(self.process)
        try:
            deadline = time.monotonic() + TIMEOUT
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"core exited during loopback startup ({self.name})")
                try:
                    with socket.create_connection(("127.0.0.1", self.config["inbounds"][0]["listen_port"]), 0.1):
                        return self
                except OSError:
                    time.sleep(0.02)
            raise RuntimeError("core loopback listener startup timed out")
        except BaseException:
            self.__exit__()
            raise

    def __exit__(self, *args):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(TIMEOUT)
        if self.log:
            self.log.close()


def configuration(fixtures, inbound_port, rules, upstream_port=None):
    return {
        "log": {"disabled": True},
        "inbounds": [{"type": "socks", "tag": "local-test", "listen": "127.0.0.1", "listen_port": inbound_port}],
        "outbounds": [
            {"type": "direct", "tag": "direct"},
            {"type": "socks", "tag": "socks-upstream", "server": "127.0.0.1", "server_port": upstream_port or fixtures.socks_port, "version": "5", "username": fixtures.username, "password": fixtures.password},
            {"type": "http", "tag": "connect-upstream", "server": "127.0.0.1", "server_port": fixtures.connect_port, "username": fixtures.username, "password": fixtures.password},
        ],
        "route": {"rules": rules, "final": "direct", "find_process": True},
    }


def client(kind, inbound_port, target_port, path):
    environment = {key: value for key, value in os.environ.items() if not key.lower().endswith("_proxy")}
    if kind == "curl":
        command = ["/usr/bin/curl", "--disable", "--silent", "--show-error", "--fail", "--max-time", str(TIMEOUT), "--connect-timeout", "2", "--noproxy", "", "--proxy", f"socks5h://127.0.0.1:{inbound_port}", f"http://127.0.0.1:{target_port}{path}"]
    else:
        command = [sys.executable, str(Path(__file__).resolve()), "--tcp-client", str(inbound_port), str(target_port), path]
    result = subprocess.run(command, capture_output=True, timeout=TIMEOUT + 2, env=environment)
    expected = f"loopback-ok:{path}".encode()
    return {"ok": result.returncode == 0 and result.stdout == expected, "exit_code": result.returncode}


def udp_client(inbound_port, target_port):
    with socket.create_connection(("127.0.0.1", inbound_port), TIMEOUT) as control:
        control.settimeout(TIMEOUT)
        host, port = socks_command(control, 3, 0)
        if host == "0.0.0.0":
            host = "127.0.0.1"
        if not ipaddress.ip_address(host).is_loopback:
            raise RuntimeError("core returned a non-loopback UDP endpoint")
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as datagram:
            datagram.bind(("127.0.0.1", 0))
            datagram.settimeout(0.7)
            payload = b"\x00\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", target_port) + b"loopback-udp-proof"
            datagram.sendto(payload, (host, port))
            try:
                response = datagram.recv(2048)
                return response.endswith(b"loopback-udp-proof")
            except socket.timeout:
                return False


def require(condition, label):
    if not condition:
        raise RuntimeError(label)


def check_product_compiler(helper, fixtures):
    """Exercise bundled Swift compiler + pinned core CHECK, never helper run."""
    session_root = Path.home() / "Library/Application Support/App Proxy/Sessions"
    created = []
    for ancestor in reversed((session_root, *session_root.parents)):
        if not ancestor.exists():
            ancestor.mkdir(mode=0o700)
            created.append(ancestor)
    session = session_root / str(uuid.uuid4()).upper()
    session.mkdir(mode=0o700)
    try:
        proxies = []
        rules = []
        passwords = {}
        for kind, port in (("socks5", fixtures.socks_port), ("http", fixtures.connect_port)):
            identifier = str(uuid.uuid4()).upper()
            proxies.append({"id": identifier, "name": "Local integration " + kind, "kind": kind, "host": "127.0.0.1", "port": port, "username": fixtures.username, "hasPassword": True})
            bundle = "/Applications/Integration " + kind + ".app"
            rules.append({"id": str(uuid.uuid4()).upper(), "name": "Integration " + kind, "appPath": bundle, "executablePath": bundle + "/Contents/MacOS/Fixture", "proxyID": identifier, "enabled": True, "includeHelpers": kind == "socks5"})
            passwords[identifier] = fixtures.password
        request = {"configuration": {"version": 1, "proxies": proxies, "rules": rules}, "passwords": passwords, "parentPID": os.getpid(), "ownerUID": os.getuid(), "token": str(uuid.uuid4()).upper() + str(uuid.uuid4()).upper()}
        descriptor = os.open(session / "request.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            json.dump(request, stream)
        result = subprocess.run([str(helper), "check", "--session", str(session)], capture_output=True, timeout=20)
        require(result.returncode == 0, "bundled helper product compiler check failed (captured output withheld)")
        return {"passed": True, "command": "AppProxyHelper check --session <private-session>", "profiles": ["socks5", "http"], "rules": ["bundle_helpers", "exact_executable"], "tun_started": False}
    finally:
        shutil.rmtree(session)
        for ancestor in reversed(created):
            with contextlib.suppress(OSError):
                ancestor.rmdir()


def run(binary, helper=None):
    require(platform.system() == "Darwin", "this harness requires macOS network snapshot commands")
    version = subprocess.run([str(binary), "version"], capture_output=True, text=True, check=True, timeout=TIMEOUT).stdout
    require(version.splitlines()[0].strip() == "sing-box version 1.14.3", "expected pinned sing-box 1.14.3")
    summary = {"core_version": "1.14.3", "mode": "no-root-loopback-only", "tun_started": False}
    before = capture_network()
    directory = None
    try:
        with tempfile.TemporaryDirectory(prefix="app-proxy-integration-") as temporary, Fixtures() as fixtures:
            directory = Path(temporary)
            os.chmod(directory, 0o700)
            summary["temporary_permissions"] = {"directory": "0700", "configs_and_logs": "0600"}
            python_path = executable_path()
            summary["clients"] = {"curl": "/usr/bin/curl", "python": python_path}
            attribution = []
            for selected, unmatched, outbound, observations in (
                ("curl", "python", "socks-upstream", fixtures.socks_connections),
                ("python", "curl", "connect-upstream", fixtures.connect_connections),
            ):
                port = unused_port()
                selected_path = "/usr/bin/curl" if selected == "curl" else python_path
                config = configuration(fixtures, port, [{"process_path": [selected_path], "network": "tcp", "action": "route", "outbound": outbound}])
                with Core(binary, directory, config, "process-" + selected):
                    selected_trials = []
                    unmatched_trials = []
                    for trial in range(3):
                        count = observations.count()
                        selected_result = client(selected, port, fixtures.target_port, f"/selected-{selected}-{trial}")
                        selected_trials.append(observations.count() - count)
                        count = observations.count()
                        unmatched_result = client(unmatched, port, fixtures.target_port, f"/unmatched-{unmatched}-{trial}")
                        unmatched_trials.append(observations.count() - count)
                        require(selected_result["ok"] and unmatched_result["ok"], "process selection TCP requests failed")
                    require(unmatched_trials == [0, 0, 0], "unmatched process unexpectedly used upstream")
                    attribution.append({"selected": selected, "unmatched": unmatched, "selected_upstream_handshakes_by_trial": selected_trials, "unmatched_upstream_handshakes_by_trial": unmatched_trials, "process_path_routing_observed": selected_trials == [1, 1, 1], "both_clients_received_target_body": True})
            summary["process_path_trials"] = attribution

            transport = []
            for protocol, outbound, observations in (
                ("socks5", "socks-upstream", fixtures.socks_connections),
                ("http_connect", "connect-upstream", fixtures.connect_connections),
            ):
                port = unused_port()
                config = configuration(fixtures, port, [{"network": "tcp", "action": "route", "outbound": outbound}])
                with Core(binary, directory, config, "forward-" + protocol):
                    count = observations.count()
                    result = client("curl", port, fixtures.target_port, "/forward-" + protocol)
                    delta = observations.count() - count
                    require(result["ok"] and delta == 1, protocol + " forwarding was not observed")
                    transport.append({"protocol": protocol, "authenticated_handshakes": delta, "destination": ["127.0.0.1", fixtures.target_port], "target_body_verified": True})
            summary["upstream_forwarding"] = transport

            with socket.socket() as reserved:
                # Bound but not listening: deterministic local connection refusal.
                reserved.bind(("127.0.0.1", 0))
                port = unused_port()
                config = configuration(fixtures, port, [{"network": "tcp", "action": "route", "outbound": "socks-upstream"}], reserved.getsockname()[1])
                with Core(binary, directory, config, "upstream-failure"):
                    count = fixtures.http_requests.count()
                    result = client("curl", port, fixtures.target_port, "/must-not-arrive")
                    received = fixtures.http_requests.count() - count
                    require(not result["ok"] and result["exit_code"] != 0 and received == 0, "failed upstream leaked to direct target")
                    summary["upstream_failure"] = {"client_failed": True, "client_exit_code": result["exit_code"], "target_requests": received, "no_direct_fallback_observed": True}

            port = unused_port()
            with Core(binary, directory, configuration(fixtures, port, [{"process_path": ["/usr/bin/curl"], "network": "udp", "action": "reject"}]), "udp-control"):
                count = fixtures.udp_requests.count()
                received = udp_client(port, fixtures.udp_port)
                require(received and fixtures.udp_requests.count() - count == 1, "SOCKS UDP direct positive control failed")
            port = unused_port()
            with Core(binary, directory, configuration(fixtures, port, [{"process_path": [python_path], "network": "udp", "action": "reject"}]), "udp-reject"):
                count = fixtures.udp_requests.count()
                received = udp_client(port, fixtures.udp_port)
                delta = fixtures.udp_requests.count() - count
                require(not received and delta == 0, "UDP reject rule did not block target")
                summary["udp"] = {"direct_control_echo_received": True, "control_reject_rule_process": "curl", "reject_rule_process": "python", "reject_rule_echo_received": received, "reject_rule_target_datagrams": delta}

            # This config is CHECKED only; Core.__enter__ explicitly forbids TUN.
            tun_config = configuration(fixtures, unused_port(), [
                {"port": 53, "action": "route", "outbound": "direct"},
                {"process_path": [str(binary)], "action": "route", "outbound": "direct"},
                {"process_path": ["/usr/bin/curl"], "network": "udp", "action": "reject"},
                {"process_path": ["/usr/bin/curl"], "network": "tcp", "action": "route", "outbound": "socks-upstream"},
            ])
            tun_config["inbounds"] = [{"type": "tun", "tag": "app-tun", "address": ["172.30.83.1/30", "fdfe:dcba:9876::1/126"], "mtu": 1500, "auto_route": True, "strict_route": False, "stack": "system", "dns_mode": "disabled"}]
            tun_config["route"]["auto_detect_interface"] = True
            summary["dual_stack_tun_config_check"] = Core(binary, directory, tun_config, "tun-check-only").check()
            summary["product_compiler_check"] = check_product_compiler(helper, fixtures) if helper else {"run": False, "reason": "pass --helper with the built bundled AppProxyHelper to check the Swift product compiler"}
            summary["runtime_config_count"] = len(list(directory.glob("*.json")))
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        summary["error"] = str(error)
    finally:
        summary["temporary_directory_removed"] = directory is None or not directory.exists()
        summary["core_processes_stopped"] = all(process.poll() is not None for process in Core.started_processes)
        summary["network_state"] = compare_network(before, capture_network())
    if not all(value["unchanged"] for value in summary["network_state"].values()):
        summary["error"] = "network snapshot changed; investigate unrelated activity before accepting"
    if not summary["core_processes_stopped"] or not summary["temporary_directory_removed"]:
        summary["error"] = "integration cleanup incomplete"
    summary["passed"] = "error" not in summary
    return summary


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--tcp-client":
        try:
            inbound, target = map(int, sys.argv[2:4])
            path = sys.argv[4]
            if python_client(inbound, target, path):
                sys.stdout.write("loopback-ok:" + path)
                return 0
        except (OSError, ValueError, ConnectionError):
            pass
        return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=Path, default=ROOT / "downloaded-binaries" / "sing-box")
    parser.add_argument("--helper", type=Path, help="Optional bundled AppProxyHelper: checks actual Swift-generated TUN config without starting it")
    arguments = parser.parse_args()
    def interrupted(signum, frame):
        # OSError/InterruptedError is retried inside Python selectors and socket
        # helpers; a distinct exception reliably unwinds every context manager.
        raise RuntimeError(f"integration interrupted by signal {signum}")

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)
    try:
        result = run(arguments.core.resolve(), arguments.helper.resolve() if arguments.helper else None)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["passed"] else 1
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        # Exception messages are constructed by this harness or standard OS calls;
        # core config/stdout/stderr and fixture credentials are never included.
        print(json.dumps({"passed": False, "error": str(error), "tun_started": False}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
