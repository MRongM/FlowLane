//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("APP_PROXY_ATTRIBUTION_SOCKET_CLIENT") == "1" {
		if err := runSocketClient(os.Stdin, os.Stdout); err != nil {
			os.Exit(2)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// Exercise real kernel sockets and the actual pinned upstream lookup, with two
// executable paths. An unavailable owner is evidence, while a wrong owner fails.
func TestTwoExecutablesHoldTCPAndUDPSockets(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	report, err := runDiagnostic(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(report.Observations) != 4 {
		t.Fatalf("got %d observations, want 4", len(report.Observations))
	}
	paths := map[string]map[string]bool{}
	for _, observation := range report.Observations {
		if observation.ExpectedPID <= 0 || !observation.PIDPathMatches {
			t.Fatalf("child PID was not independently checked: %+v", observation)
		}
		if observation.Status != "matched" && observation.Status != "unknown" {
			t.Fatalf("wrong process attribution: %+v", observation)
		}
		if paths[observation.ExpectedPath] == nil {
			paths[observation.ExpectedPath] = map[string]bool{}
		}
		paths[observation.ExpectedPath][observation.Network] = true
	}
	if len(paths) != 2 {
		t.Fatalf("got %d executable paths, want 2", len(paths))
	}
	for path, networks := range paths {
		if !networks["tcp"] || !networks["udp"] {
			t.Fatalf("missing protocol for %s", path)
		}
	}
	if report.UnknownTCP.Status != "unknown" || report.UnknownUDP.Status != "unknown" {
		t.Fatalf("unowned tuple must stay unknown: %+v %+v", report.UnknownTCP, report.UnknownUDP)
	}
	if _, err := json.Marshal(report); err != nil {
		t.Fatal(err)
	}
}

func TestNativePIDPathUsesCStringTerminator(t *testing.T) {
	expected, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	expected, err = filepath.EvalSymlinks(expected)
	if err != nil {
		t.Fatal(err)
	}
	actual, err := execPathForPID(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	if actual != expected {
		t.Fatalf("native PID path differs: got %d bytes, want %d; NUL index %d", len(actual), len(expected), strings.IndexByte(actual, 0))
	}
}
