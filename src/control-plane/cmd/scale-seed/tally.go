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

func progress(c *counters, mu *sync.Mutex, w *bufio.Writer, n int, start time.Time) {
	t := c.total.Add(1)
	if t%500 != 0 {
		return
	}
	el := time.Since(start).Seconds()
	fmt.Printf("  %d/%d (%.0f/s) created=%d exists=%d errors=%d\n",
		t, n, float64(t)/el, c.created.Load(), c.exists.Load(), c.errs.Load())
	mu.Lock()
	_ = w.Flush()
	mu.Unlock()
}
