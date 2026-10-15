//go:build darwin

// This diagnostic imports the actual, version-pinned sing-box process lookup.
// It opens loopback sockets only and never activates the networking core.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/sagernet/sing-box/common/process"
)

const upstreamSource = "https://github.com/SagerNet/sing-box/tree/v1.14.3/common/process"

type observation struct {
	Client           string `json:"client"`
	Network          string `json:"network"`
	ExpectedPID      int    `json:"expected_pid"`
	ExpectedPath     string `json:"expected_path"`
	KernelPathForPID string `json:"kernel_path_for_pid"`
	PIDPathMatches   bool   `json:"pid_path_matches"`
	ObservedPath     string `json:"observed_path,omitempty"`
	UIDMatches       bool   `json:"uid_matches"`
	Status           string `json:"status"`
	Detail           string `json:"detail,omitempty"`
}

type unknownObservation struct {
	Status string `json:"status"`
	Detail string `json:"detail,omitempty"`
}

type diagnosticReport struct {
	CoreVersion        string             `json:"core_version"`
	Source             string             `json:"source"`
	Elevated           bool               `json:"elevated"`
	Transport          string             `json:"transport"`
	Observations       []observation      `json:"observations"`
	UnknownTCP         unknownObservation `json:"unknown_tcp"`
	UnknownUDP         unknownObservation `json:"unknown_udp"`
	AllMatched         bool               `json:"all_matched"`
	temporaryDirectory string
}

type clientTargets struct {
	TCP string `json:"tcp"`
	UDP string `json:"udp"`
}

type clientSockets struct {
	PID            int    `json:"pid"`
	Path           string `json:"path"`
	TCPSource      string `json:"tcp_source"`
	TCPDestination string `json:"tcp_destination"`
	UDPSource      string `json:"udp_source"`
	UDPDestination string `json:"udp_destination"`
}

type heldClient struct {
	command *exec.Cmd
	input   io.WriteCloser
	sockets clientSockets
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--socket-client" {
		if err := runSocketClient(os.Stdin, os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		return
	}
	if len(os.Args) != 1 {
		fmt.Fprintln(os.Stderr, "Usage: go run .")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	report, err := runDiagnostic(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// Only paths to our own temporary executables appear in the report. Replace
	// the random temporary prefix before printing so output can be shared.
	encoded, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(strings.ReplaceAll(string(encoded), report.temporaryDirectory, "$TEMP"))
	for _, item := range report.Observations {
		if item.Status == "mismatched" {
			os.Exit(1)
		}
	}
	if report.UnknownTCP.Status != "unknown" || report.UnknownUDP.Status != "unknown" {
		os.Exit(1)
	}
	if !report.AllMatched {
		os.Exit(3)
	}
}

func runSocketClient(input io.Reader, output io.Writer) error {
	var targets clientTargets
	if err := json.NewDecoder(input).Decode(&targets); err != nil {
		return err
	}
	tcp, err := net.Dial("tcp4", targets.TCP)
	if err != nil {
		return err
	}
	defer tcp.Close()
	udp, err := net.Dial("udp4", targets.UDP)
	if err != nil {
		return err
	}
	defer udp.Close()
	// Real writes ensure these are live client sockets, not unconnected plans.
	if _, err = tcp.Write([]byte{1}); err != nil {
		return err
	}
	if _, err = udp.Write([]byte{1}); err != nil {
		return err
	}
	path, err := os.Executable()
	if err != nil {
		return err
	}
	path, err = filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	hello := clientSockets{
		PID: os.Getpid(), Path: path,
		TCPSource: tcp.LocalAddr().String(), TCPDestination: tcp.RemoteAddr().String(),
		UDPSource: udp.LocalAddr().String(), UDPDestination: udp.RemoteAddr().String(),
	}
	if err := json.NewEncoder(output).Encode(hello); err != nil {
		return err
	}
	// Parent holds stdin open until every lookup is complete.
	_, err = io.Copy(io.Discard, input)
	return err
}

func startClient(ctx context.Context, path string, targets clientTargets) (*heldClient, error) {
	command := exec.CommandContext(ctx, path, "--socket-client")
	// TestMain uses this to run the same real client mode inside a test binary.
	command.Env = append(os.Environ(), "APP_PROXY_ATTRIBUTION_SOCKET_CLIENT=1")
	input, err := command.StdinPipe()
	if err != nil {
		return nil, err
	}
	output, err := command.StdoutPipe()
	if err != nil {
		input.Close()
		return nil, err
	}
	if err := command.Start(); err != nil {
		input.Close()
		return nil, err
	}
	client := &heldClient{command: command, input: input}
	if err := json.NewEncoder(input).Encode(targets); err != nil {
		client.close()
		return nil, err
	}
	if err := json.NewDecoder(output).Decode(&client.sockets); err != nil {
		client.close()
		return nil, fmt.Errorf("client startup: %w", err)
	}
	if client.sockets.PID != command.Process.Pid || client.sockets.Path != path {
		client.close()
		return nil, fmt.Errorf("client identity differs from launched executable")
	}
	return client, nil
}

func (client *heldClient) close() {
	client.input.Close()
	// Closing stdin normally exits the child; context bounds unexpected hangs.
	_ = client.command.Wait()
}

func copyExecutable(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func runDiagnostic(ctx context.Context) (diagnosticReport, error) {
	result := diagnosticReport{
		CoreVersion: "1.14.3", Source: upstreamSource,
		Elevated: os.Geteuid() == 0, Transport: "IPv4 loopback only", AllMatched: true,
	}
	if result.Elevated {
		return result, fmt.Errorf("run this diagnostic as an ordinary user; do not use sudo")
	}
	scratch, err := os.MkdirTemp("", "app-proxy-attribution-")
	if err != nil {
		return result, err
	}
	defer os.RemoveAll(scratch)
	scratch, err = filepath.EvalSymlinks(scratch)
	if err != nil {
		return result, err
	}
	result.temporaryDirectory = scratch
	executable, err := os.Executable()
	if err != nil {
		return result, err
	}
	tcpListener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return result, err
	}
	defer tcpListener.Close()
	udpListener, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return result, err
	}
	defer udpListener.Close()
	deadline, _ := ctx.Deadline()
	if deadline.IsZero() {
		deadline = time.Now().Add(20 * time.Second)
	}
	_ = tcpListener.SetDeadline(deadline)
	_ = udpListener.SetDeadline(deadline)
	targets := clientTargets{TCP: tcpListener.Addr().String(), UDP: udpListener.LocalAddr().String()}
	var clients []*heldClient
	for _, label := range []string{"client-a", "client-b"} {
		path := filepath.Join(scratch, label)
		if err := copyExecutable(executable, path); err != nil {
			return result, err
		}
		client, err := startClient(ctx, path, targets)
		if err != nil {
			return result, err
		}
		defer client.close()
		clients = append(clients, client)
		accepted, err := tcpListener.AcceptTCP()
		if err != nil {
			return result, err
		}
		defer accepted.Close()
		_ = accepted.SetReadDeadline(deadline)
		var byteBuffer [1]byte
		if _, err := io.ReadFull(accepted, byteBuffer[:]); err != nil {
			return result, err
		}
		if accepted.RemoteAddr().String() != client.sockets.TCPSource {
			return result, fmt.Errorf("TCP peer mismatch")
		}
		_, udpPeer, err := udpListener.ReadFromUDP(byteBuffer[:])
		if err != nil {
			return result, err
		}
		if udpPeer.String() != client.sockets.UDPSource {
			return result, fmt.Errorf("UDP peer mismatch")
		}
	}
	searcher, err := process.NewSearcher(process.Config{})
	if err != nil {
		return result, err
	}
	defer searcher.Close()
	// Both different executables remain alive with both sockets throughout.
	for index, client := range clients {
		kernelPath, err := execPathForPID(uint32(client.command.Process.Pid))
		if err != nil {
			return result, fmt.Errorf("read own child PID path: %w", err)
		}
		for _, network := range []string{"tcp", "udp"} {
			item := observation{
				Client: fmt.Sprintf("client-%c", 'a'+index), Network: network,
				ExpectedPID: client.command.Process.Pid, ExpectedPath: client.sockets.Path,
				KernelPathForPID: kernelPath, PIDPathMatches: kernelPath == client.sockets.Path,
				Status: "unknown",
			}
			source, destination := client.sockets.TCPSource, client.sockets.TCPDestination
			if network == "udp" {
				source, destination = client.sockets.UDPSource, client.sockets.UDPDestination
			}
			searcher.ResetCache()
			owner, err := searcher.FindProcessInfo(ctx, network, netip.MustParseAddrPort(source), netip.MustParseAddrPort(destination))
			if err != nil {
				item.Detail = err.Error()
			} else if owner.ProcessPath == "" {
				item.Detail = "lookup returned no executable path"
			} else {
				item.ObservedPath = owner.ProcessPath
				item.UIDMatches = owner.UserId == int32(os.Getuid())
				item.Status = "mismatched"
				if item.ObservedPath == item.ExpectedPath && item.PIDPathMatches && item.UIDMatches {
					item.Status = "matched"
				}
			}
			if item.Status != "matched" {
				result.AllMatched = false
			}
			result.Observations = append(result.Observations, item)
		}
	}
	// Use a documentation-only source address and the already-held nonzero
	// loopback UDP listener port. No socket is bound to that address; this is
	// a lookup only. Port zero is unsuitable because UDP wildcard entries can
	// produce a local-port fallback even without a destination match.
	unowned := netip.AddrPortFrom(netip.MustParseAddr("192.0.2.1"), uint16(udpListener.LocalAddr().(*net.UDPAddr).Port))
	for _, network := range []string{"tcp", "udp"} {
		searcher.ResetCache()
		owner, lookupErr := searcher.FindProcessInfo(ctx, network, unowned, netip.AddrPort{})
		item := unknownObservation{Status: "unexpected_owner"}
		if lookupErr != nil {
			item.Status = "unknown"
			item.Detail = lookupErr.Error()
		} else if owner.ProcessPath == "" {
			item.Status = "unknown"
			item.Detail = "lookup returned no executable path"
		}
		if network == "tcp" {
			result.UnknownTCP = item
		} else {
			result.UnknownUDP = item
		}
	}
	return result, nil
}

// The upstream public ConnectionOwner omits socket PID. Independently resolve
// each known child PID with the same Darwin proc_pidpath syscall used upstream;
// this correlates the returned executable path without inventing a socket PID.
func execPathForPID(pid uint32) (string, error) {
	const procPIDPathInfo = 0xb
	const procCallNumPIDInfo = 0x2
	buffer := make([]byte, 1024)
	_, _, errno := syscall.Syscall6(syscall.SYS_PROC_INFO, procCallNumPIDInfo,
		uintptr(pid), procPIDPathInfo, 0, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if errno != 0 {
		return "", errno
	}
	if terminator := bytes.IndexByte(buffer, 0); terminator >= 0 {
		buffer = buffer[:terminator]
	}
	return string(buffer), nil
}
