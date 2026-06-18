package main

import (
	"bufio"
	"fmt"
	"net/http"
	"sync"
	"time"
)

func runWorkers(client *http.Client, cfg seedConfig, done map[string]bool, w *bufio.Writer) int64 {
	jobs := make(chan string)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var c counters
	start := time.Now()
	for i := 0; i < *cfg.concurrency; i++ {
		wg.Add(1)
		go worker(workerArgs{client: client, cfg: cfg, wg: &wg, jobs: jobs, w: w, mu: &mu, c: &c, start: start})
	}
	queued := dispatchJobs(cfg, done, jobs)
	wg.Wait()
	el := time.Since(start)
	fmt.Printf("done: queued=%d created=%d exists=%d errors=%d in %s (%.0f/s)\n",
		queued, c.created.Load(), c.exists.Load(), c.errs.Load(), el.Round(time.Second),
		float64(queued)/el.Seconds())
	return c.errs.Load()
}

// workerArgs bundles the inputs a provisioning worker goroutine needs.
type workerArgs struct {
	client *http.Client
	cfg    seedConfig
	wg     *sync.WaitGroup
	jobs   <-chan string
	w      *bufio.Writer
	mu     *sync.Mutex
	c      *counters
	start  time.Time
}

func worker(a workerArgs) {
	defer a.wg.Done()
	for slug := range a.jobs {
		spec := provisionSpec{slug: slug, plan: *a.cfg.plan, dsn: *a.cfg.dsn, isolation: *a.cfg.isolation, mounts: *a.cfg.mounts}
		rec := provisionOne(a.client, *a.cfg.base, *a.cfg.token, spec)
		tallyStatus(a.c, rec.Status)
		writeRecord(a.w, a.mu, rec)
		progress(progressArgs{c: a.c, mu: a.mu, w: a.w, n: *a.cfg.n, start: a.start})
	}
}

func dispatchJobs(cfg seedConfig, done map[string]bool, jobs chan<- string) int {
	queued := 0
	for i := 1; i <= *cfg.n; i++ {
		slug := fmt.Sprintf("%s-%06d", *cfg.prefix, i)
		if done[slug] {
			continue
		}
		jobs <- slug
		queued++
	}
	close(jobs)
	return queued
}
