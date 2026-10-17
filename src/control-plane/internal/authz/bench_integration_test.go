//go:build authz_bench

package authz

// Measures the Go evaluator against a real postgres seeded by m232 (testdata/perf_seed.sql).
// Driven by scripts/verify/m232-authz-perf.sh, which owns the kill criterion; this file
// only measures and writes JSON. Env: AUTHZ_BENCH_DSN, AUTHZ_BENCH_OUT.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

type benchResult struct {
	Strategy    string  `json:"strategy"`
	Scenario    string  `json:"scenario"`
	Clients     int     `json:"clients"`
	Calls       int     `json:"calls"`
	P50ms       float64 `json:"p50_ms"`
	P95ms       float64 `json:"p95_ms"`
	HoldP50ms   float64 `json:"hold_p50_ms"`
	HoldP95ms   float64 `json:"hold_p95_ms"`
	Unavailable int     `json:"unavailable"`
}

type checker func(context.Context, Query) ([]Decision, error)

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func pct(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	return sorted[int(float64(len(sorted)-1)*p)]
}

// scenarioQuery returns a worst-case deny: a user with no grant, so every
// ancestor and every userset is explored.
func scenarioQuery(scenario string) Query {
	q := Query{App: "osionos", UserID: "nobody", Name: "read"}
	if scenario == "single_depth10" {
		q.Objects = []Ref{{"page", "88888"}}
		return q
	}
	for i := 0; i < 500; i++ {
		q.Objects = append(q.Objects, Ref{"page", fmt.Sprint(60000 + i)})
	}
	return q
}

// drive drives `calls` checks over `clients` goroutines and summarizes them.
// Caveat: closed loop, no think time: it measures service time under queueing at
// `clients`, not a production arrival pattern.
func drive(check checker, hold *holdLog, strategy, scenario string, clients, calls int) benchResult {
	var mu sync.Mutex
	var lat []time.Duration
	unavailable := 0
	var wg sync.WaitGroup
	next := make(chan struct{}, calls)
	for i := 0; i < calls; i++ {
		next <- struct{}{}
	}
	close(next)
	hold.reset()
	for c := 0; c < clients; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range next {
				t0 := time.Now()
				_, err := check(context.Background(), scenarioQuery(scenario))
				d := time.Since(t0)
				mu.Lock()
				if errors.Is(err, ErrUnavailable) {
					unavailable++
				} else {
					lat = append(lat, d)
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	h := hold.sorted()
	return benchResult{strategy, scenario, clients, calls, ms(pct(lat, .5)), ms(pct(lat, .95)),
		ms(pct(h, .5)), ms(pct(h, .95)), unavailable}
}

type holdLog struct {
	mu sync.Mutex
	d  []time.Duration
}

func (h *holdLog) add(d time.Duration) { h.mu.Lock(); h.d = append(h.d, d); h.mu.Unlock() }
func (h *holdLog) reset()              { h.mu.Lock(); h.d = nil; h.mu.Unlock() }
func (h *holdLog) sorted() []time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := append([]time.Duration(nil), h.d...)
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func TestBenchmarkAuthz(t *testing.T) {
	dsn, out := os.Getenv("AUTHZ_BENCH_DSN"), os.Getenv("AUTHZ_BENCH_OUT")
	if dsn == "" || out == "" {
		t.Skip("AUTHZ_BENCH_DSN / AUTHZ_BENCH_OUT not set")
	}
	db, err := pg.NewPostgres(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	hold := &holdLog{}
	cfg := DefaultConfig()
	cfg.ObserveHold = hold.add
	store := NewStore(db, slog.New(slog.NewTextHandler(io.Discard, nil)), cfg)
	assertSeedAnswers(t, store)

	strategies := map[string]checker{
		"levels":  store.Check,
		"closure": func(ctx context.Context, q Query) ([]Decision, error) { return checkClosure(ctx, store, q) },
	}
	var results []benchResult
	for _, strategy := range []string{"levels", "closure"} {
		for _, sc := range []struct {
			name  string
			calls int
		}{{"single_depth10", 3000}, {"batch500", 300}} {
			for _, clients := range []int{1, 16} {
				// closure has no gate, so its hold time is measured around the call instead
				chk := strategies[strategy]
				if strategy == "closure" {
					chk = timed(chk, hold)
				}
				drive(chk, hold, strategy, sc.name, clients, sc.calls/10) // warm-up
				results = append(results, drive(chk, hold, strategy, sc.name, clients, sc.calls))
			}
		}
	}
	raw, _ := json.MarshalIndent(map[string]any{"max_concurrent": cfg.MaxConcurrent, "results": results}, "", " ")
	if err := os.WriteFile(out, raw, 0o644); err != nil {
		t.Fatal(err)
	}
}

func timed(c checker, hold *holdLog) checker {
	return func(ctx context.Context, q Query) ([]Decision, error) {
		t0 := time.Now()
		defer func() { hold.add(time.Since(t0)) }()
		return c(ctx, q)
	}
}

// assertSeedAnswers fails fast when the seed does not give the answers the
// timings assume: a stranger is denied everywhere; an owner reads their page.
func assertSeedAnswers(t *testing.T, s *Store) {
	t.Helper()
	ds, err := s.Check(context.Background(), scenarioQuery("batch500"))
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range ds {
		if d.Allowed || d.Cut {
			t.Fatalf("stranger on %v: allowed=%v cut=%v, want a plain deny", d.Object, d.Allowed, d.Cut)
		}
	}
	owner := Query{App: "osionos", UserID: "u888", Name: "read", Objects: []Ref{{"page", "88888"}}}
	if ds, err = s.Check(context.Background(), owner); err != nil || !ds[0].Allowed {
		t.Fatalf("page 88888 owner u888: %v %v, want allow", ds, err)
	}
}
