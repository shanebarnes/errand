package main

import (
    "encoding/json"
    "log"
    "os"
    "os/exec"
    "os/signal"
    "sync"
    "syscall"

    "github.com/robfig/cron"
    "github.com/shanebarnes/goto/logger"
)

const version = "0.1.0"

type CronEntry struct {
    Command        string    `json:"command"`
    Cron          *cron.Cron `json:"-"`
    Id             int       `json:"-"`
    Interval       string    `json:"interval"`
    Iteration      int64     `json:"-"`
    MaxIterations  int64     `json:"max_iterations"`
    Name           string    `json:"name"`
}

type CronTable struct {
    Job []CronEntry `json:"job"`
}

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

    file, _ := os.OpenFile("errand.log", os.O_APPEND | os.O_CREATE | os.O_RDWR, 0644)
    defer file.Close()

    logger.Init(log.Ldate | log.Ltime | log.Lmicroseconds, logger.Info, file)
    logger.PrintlnInfo("Starting errand", version)

    table := loadCronTable("errand.json")

    var wg sync.WaitGroup

    for i := range table.Job {
        if table.Job[i].MaxIterations != 0 {
            logger.PrintlnInfo("Cron table entry", i, table.Job[i])
            table.Job[i].Cron = cron.New()
            table.Job[i].Id = i
            errand := table.Job[i]

            wg.Add(1)
            table.Job[i].Cron.AddFunc(table.Job[i].Interval, func() {
                errand.Iteration = errand.Iteration + 1
                logger.PrintlnInfo("Errand", errand.Id, "| Running '" + errand.Name + "'", "| iteration", errand.Iteration)

                if buffer, err := exec.Command("bash", "-c", errand.Command).Output(); err == nil {
                    logger.PrintlnInfo("Errand", errand.Id, "Output:", string(buffer))
                }

                if errand.MaxIterations > 0 && errand.Iteration >= errand.MaxIterations {
                    errand.Cron.Stop()
                    logger.PrintlnInfo("Errand", errand.Id, "| Stopping '" + errand.Name + "'")
                    wg.Done()
                }
            })
            table.Job[i].Cron.Start()
        }
    }

    wg.Wait()
    logger.PrintlnInfo("Stopping errand", version)
}

func loadCronTable(fileName string) CronTable {
    var err error = nil
    var f *os.File = nil
    var table CronTable

    if f, err = os.Open(fileName); err == nil {
        defer f.Close()
        decoder := json.NewDecoder(f)
        err = decoder.Decode(&table)
    }

    if err != nil {
        logger.PrintlnError(err)
    }

    return table
}
