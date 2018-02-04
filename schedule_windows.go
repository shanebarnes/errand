// +build windows

package main

import (
	"context"
	"os/exec"
	"time"
)

func RunErrand(errand CronEntry, idx int, timeout time.Duration) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// Todo: Allow for a graceful shutdown (e.g., SIGINT or SIGTERM instead
	//       of SIGKILL).
	return exec.CommandContext(ctx, errand.CommandName, errand.CommandPermutation[idx]...).CombinedOutput()
}
