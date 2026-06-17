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
		go worker(client, cfg, &wg, jobs, w, &mu, &c, start)
	}
	queued := dispatchJobs(cfg, done, jobs)
	wg.Wait()
	el := time.Since(start)
	fmt.Printf("done: queued=%d created=%d exists=%d errors=%d in %s (%.0f/s)\n",
		queued, c.created.Load(), c.exists.Load(), c.errs.Load(), el.Round(time.Second),
		float64(queued)/el.Seconds())
	return c.errs.Load()
}

func worker(client *http.Client, cfg seedConfig, wg *sync.WaitGroup, jobs <-chan string,
	w *bufio.Writer, mu *sync.Mutex, c *counters, start time.Time) {
	defer wg.Done()
	for slug := range jobs {
		rec := provisionOne(client, *cfg.base, *cfg.token, slug, *cfg.plan, *cfg.dsn, *cfg.isolation, *cfg.mounts)
		tallyStatus(c, rec.Status)
		writeRecord(w, mu, rec)
		progress(c, mu, w, *cfg.n, start)
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
