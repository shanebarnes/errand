// +build !windows

package main

import (
	"os/exec"
	"syscall"
	"time"
)

func RunErrand(errand CronEntry, idx int, timeout time.Duration) ([]byte, error) {
	cmd := exec.Command(errand.CommandName, errand.CommandPermutation[idx]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	time.AfterFunc(timeout, func() {
		// Allow for a graceful shutdown by sending TERM signal instead
		// of KILL signal.
		syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	})

	return cmd.CombinedOutput()
}
