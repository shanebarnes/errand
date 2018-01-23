package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/shanebarnes/goto/logger"
)

const version = "0.2.0"

func sigHandler(ch *chan os.Signal) {
	sig := <-*ch
	logger.PrintlnInfo("Captured sig " + sig.String())
	os.Exit(3)
}

func main() {
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs,
		syscall.SIGHUP,
		syscall.SIGINT,
		syscall.SIGQUIT,
		syscall.SIGABRT,
		syscall.SIGKILL,
		syscall.SIGSEGV,
		syscall.SIGTERM,
		syscall.SIGSTOP)

	go sigHandler(&sigs)

	action := flag.String("service", "run", "[install | uninstall | run | start | stop]")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "version %s\n", version)
		fmt.Fprintln(os.Stderr, "usage:")
		flag.PrintDefaults()
	}
	flag.Parse()

	runService(*action)
}
