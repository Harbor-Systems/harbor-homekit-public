// Command bridge-launcher is the main executable of "Harbor HomeKit
// Bridge.app". macOS attributes Local Network permission to the app bundle
// of the process a LaunchAgent starts; bash and go2rtc alone carry no bundle
// identity, so their mDNS multicast is silently dropped. The launcher only
// supervises run-native.sh — every bridge process it spawns inherits the
// bundle's TCC identity, which makes the permission prompt show the Harbor
// brand and lets the grant persist for the background service.
package main

import (
	"errors"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("bridge-launcher: ")

	dir := os.Getenv("HARBOR_BRIDGE_DIR")
	if dir == "" {
		var err error
		dir, err = os.Getwd()
		if err != nil {
			log.Fatal(err)
		}
	}
	script := filepath.Join(dir, "run-native.sh")
	if _, err := os.Stat(script); err != nil {
		log.Fatalf("cannot find the bridge runner: %v", err)
	}

	cmd := exec.Command("/bin/bash", script)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Fatal(err)
	}

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigs
		_ = cmd.Process.Signal(sig)
	}()

	err := cmd.Wait()
	if err == nil {
		return
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		os.Exit(exitErr.ExitCode())
	}
	log.Fatal(err)
}
