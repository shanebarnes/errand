package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/kardianos/service"
	"github.com/robfig/cron"
	"github.com/shanebarnes/goto/logger"
)

const version = "0.2.0"

type Set struct {
	Variable string   `json:"variable"`
	Objects  []string `json:"objects"`
}

var sysLogger service.Logger

type program struct{}

type CronEntry struct {
	CommandArgs        []string   `json:"command_args"`
	CommandName        string     `json:"command_name"`
	CommandPermutation [][]string `json:"-"`
	CommandSets        []Set      `json:"command_sets"`
	CommandTimeoutSec  int64      `json:"command_timeout_sec"`
	Cron               *cron.Cron `json:"-"`
	JobName            string     `json:"job_name"`
	Id                 int        `json:"-"`
	Interval           string     `json:"interval"`
	Iteration          int64      `json:"-"`
	MaxIterations      int64      `json:"max_iterations"`
}

type CronTable struct {
	Job []CronEntry `json:"job"`
}

func sigHandler(ch *chan os.Signal) {
	sig := <-*ch
	logger.PrintlnInfo("Captured sig " + sig.String())
	os.Exit(3)
}

func getCommandPermutation(sets [][]string) [][]string {
	ret := [][]string{}

	if len(sets) == 1 {
		for _, s := range sets[0] {
			ret = append(ret, []string{s})
		}
	} else if len(sets) > 1 {
		perm := getCommandPermutation(sets[1:])
		for _, s := range sets[0] {
			for _, p := range perm {
				tmp := append([]string{s}, p...)
				ret = append(ret, tmp)
			}
		}
	}

	return ret
}

func runErrand() {
	dir, _ := filepath.Abs(filepath.Dir(os.Args[0]))
	file, _ := os.OpenFile(dir+"/errand.log", os.O_APPEND|os.O_CREATE|os.O_RDWR, 0644)
	defer file.Close()

	logger.Init(log.Ldate|log.Ltime|log.Lmicroseconds, logger.Info, file)
	logger.PrintlnInfo("Starting errand", version)

	table := loadCronTable(dir + "/errand.json")

	var wg sync.WaitGroup

	for i := range table.Job {
		if table.Job[i].MaxIterations != 0 {
			logger.PrintlnInfo("Cron table entry", i, table.Job[i])
			table.Job[i].Cron = cron.New()
			table.Job[i].Id = i

			for _, set := range table.Job[i].CommandSets {
				table.Job[i].CommandPermutation = append(table.Job[i].CommandPermutation, set.Objects)
			}

			permutation := getCommandPermutation(table.Job[i].CommandPermutation)
			logger.PrintlnInfo("Permutation:", permutation)

			if len(permutation) == 0 {
				table.Job[i].CommandPermutation = append(table.Job[i].CommandPermutation, table.Job[i].CommandArgs)
			} else {
				table.Job[i].CommandPermutation = table.Job[i].CommandPermutation[:0]
				table.Job[i].CommandPermutation = make([][]string, len(permutation))

				for x := range permutation {
					table.Job[i].CommandPermutation[x] = make([]string, len(table.Job[i].CommandArgs))
					copy(table.Job[i].CommandPermutation[x], table.Job[i].CommandArgs)

					// Search and replace
					for y := range table.Job[i].CommandPermutation[x] {
						for z := range table.Job[i].CommandSets {
							table.Job[i].CommandPermutation[x][y] = strings.Replace(table.Job[i].CommandPermutation[x][y], table.Job[i].CommandSets[z].Variable, permutation[x][z], -1)
						}
					}
				}
			}

			errand := table.Job[i]

			wg.Add(1)

			table.Job[i].Cron.AddFunc(table.Job[i].Interval, func() {
				if errand.MaxIterations < 0 || errand.Iteration < errand.MaxIterations {
					errand.Iteration = errand.Iteration + 1
					logger.PrintlnInfo("Errand", errand.Id, "| Running '"+errand.JobName+"'", "| iteration", errand.Iteration)

					var timeoutMsec int64 = errand.CommandTimeoutSec * 1000

					for i := range errand.CommandPermutation {
						logger.PrintlnInfo("Errand", errand.Id, "| Running", errand.CommandName, errand.CommandPermutation[i], "| permutation", i+1, "| timeout", timeoutMsec, "ms")

						cmd := exec.Command(errand.CommandName, errand.CommandPermutation[i]...)
						cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
						time.AfterFunc(time.Duration(timeoutMsec)*time.Millisecond, func() {
							syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
						})

						start := time.Now()
						buffer, err := cmd.CombinedOutput()
						elapsed := time.Since(start)
						timeoutMsec = timeoutMsec - int64(elapsed/time.Millisecond)

						logger.PrintlnInfo("Errand", errand.Id, "completed in", int64(elapsed/time.Millisecond), "msec")

						if err != nil {
							logger.PrintlnError("Errand", errand.Id, "failed:", err)
						}

						logger.PrintlnInfo("Errand", errand.Id, "Output:", string(buffer))
					}

					if errand.MaxIterations > 0 && errand.Iteration >= errand.MaxIterations {
						errand.Cron.Stop()
						logger.PrintlnInfo("Errand", errand.Id, "| Stopping '"+errand.JobName+"'")
						wg.Done()
					}
				}
			})
			table.Job[i].Cron.Start()
		}
	}

	wg.Wait()
	logger.PrintlnInfo("Stopping errand", version)
}

func loadCronTable(file string) CronTable {
	var err error = nil
	var f *os.File = nil
	var table CronTable

	if f, err = os.Open(file); err == nil {
		defer f.Close()
		decoder := json.NewDecoder(f)
		err = decoder.Decode(&table)
	}

	if err != nil {
		logger.PrintlnError(err)
	}

	return table
}

func (p *program) Start(s service.Service) error {
	// Start should not block. Do the actual work in a go-routine.
	go p.run()
	return nil
}
func (p *program) run() {
	runErrand()
}
func (p *program) Stop(s service.Service) error {
	// Stop should not block. Return within a few seconds.
	return nil
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

	conf := &service.Config{
		Name:        "errand",
		DisplayName: "errand service",
		Description: "errand service",
	}

	action := flag.String("action", "run", "[install | uninstall | run | start | stop]")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "version %s\n", version)
		fmt.Fprintln(os.Stderr, "usage:")
		flag.PrintDefaults()
	}
	flag.Parse()

	p := &program{}
	s, err := service.New(p, conf)
	if err != nil {
		log.Fatal(err)
	}

	sysLogger, err = s.Logger(nil)
	if err != nil {
		log.Fatal(err)
	}

	// systemctl daemon-reexec

	switch *action {
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
		log.Fatal("Invalid action:" + *action)
	}

	if err != nil {
		log.Fatal(err)
	}
}
