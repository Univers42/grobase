package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

type counters struct {
	created, exists, errs, total atomic.Int64
}

func tallyStatus(c *counters, status string) {
	switch status {
	case "created":
		c.created.Add(1)
	case "exists":
		c.exists.Add(1)
	default:
		c.errs.Add(1)
	}
}

func writeRecord(w *bufio.Writer, mu *sync.Mutex, rec record) {
	line, _ := json.Marshal(rec)
	mu.Lock()
	_, _ = w.Write(line)
	_, _ = w.WriteString("\n")
	mu.Unlock()
}

// progressArgs bundles the inputs to the periodic progress reporter.
type progressArgs struct {
	c     *counters
	mu    *sync.Mutex
	w     *bufio.Writer
	n     int
	start time.Time
}

func progress(a progressArgs) {
	t := a.c.total.Add(1)
	if t%500 != 0 {
		return
	}
	el := time.Since(a.start).Seconds()
	fmt.Printf("  %d/%d (%.0f/s) created=%d exists=%d errors=%d\n",
		t, a.n, float64(t)/el, a.c.created.Load(), a.c.exists.Load(), a.c.errs.Load())
	a.mu.Lock()
	_ = a.w.Flush()
	a.mu.Unlock()
}
