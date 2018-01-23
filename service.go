package main

import (
	"log"

	"github.com/kardianos/service"
)

var sysLogger service.Logger

type program struct{}

func runService(action string) {
	conf := &service.Config{
		Name:        "errand",
		DisplayName: "errand service",
		Description: "errand service",
	}

	p := &program{}
	s, err := service.New(p, conf)
	if err != nil {
		log.Fatal(err)
	}

	sysLogger, err = s.Logger(nil)
	if err != nil {
		log.Fatal(err)
	}

	switch action {
	case "install":
		err = s.Install()
	case "uninstall":
		err = s.Uninstall()
	case "restart":
		err = s.Restart()
	case "run":
		err = s.Run()
	case "start":
		err = s.Start()
	case "stop":
		err = s.Stop()
	default:
		log.Fatal("Invalid action:" + action)
	}

	if err != nil {
		log.Fatal(err)
	}
}

func (p *program) Start(s service.Service) error {
	// Start should not block. Do the actual work in a go-routine.
	go p.run()
	return nil
}

func (p *program) run() {
	runErrands()
}

func (p *program) Stop(s service.Service) error {
	// Stop should not block. Return within a few seconds.
	return nil
}
