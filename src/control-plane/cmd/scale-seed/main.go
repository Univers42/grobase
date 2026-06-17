// scale-seed — bulk tenant provisioner for the 10K-tenant scale experiments
// (program phase B1). Drives tenant-control's idempotent POST /v1/provision
// with bounded concurrency, capturing each tenant's api key + mount ids as
// JSONL so the k6 multi-tenant workload (B2) and m39 can replay them.
//
//	go run ./cmd/scale-seed -n 10000 -base http://127.0.0.1:<tc-port> \
//	    -dsn postgres://user:pass@postgres:5432/db -out artifacts/scale/tenants-10000.jsonl
//	go run ./cmd/scale-seed -teardown -out artifacts/scale/tenants-10000.jsonl
//
// Deterministic slugs (scale-000001…), idempotent (re-runs reuse the existing
// key via provision's key_reuse), resumable (-resume skips slugs already in
// the out file). Concurrency is deliberately modest by default: every first
// provision mints an Argon2id key hash (~50ms CPU) on tenant-control.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dlesieur/mini-baas/control-plane/internal/shared"
)

type mountSpec struct {
	Engine           string `json:"engine"`
	Name             string `json:"name"`
	ConnectionString string `json:"connection_string"`
	Isolation        string `json:"isolation"`
}

type provisionRequest struct {
	Tenant         string      `json:"tenant"`
	Name           string      `json:"name"`
	Plan           string      `json:"plan"`
	DefaultKeyName string      `json:"default_key_name"`
	SeedRoles      bool        `json:"seed_roles"`
	Mounts         []mountSpec `json:"mounts"`
}

// The live /v1/provision returns a reconcile result: tenant + api_key +
// outcome + a flat resources[] (one per tenant/key/mount/role step). See
// internal/provision/reconcile.go (ReconcileResult / ResourceResult).
type provisionResponse struct {
	APIKey *struct {
		ID  string `json:"id"`
		Key string `json:"key"`
	} `json:"api_key"`
	Outcome   string `json:"outcome"` // complete | partial | failed
	Resources []struct {
		Kind   string `json:"kind"`   // tenant | key | mount | role | …
		Status string `json:"status"` // created | exists | error
		ID     string `json:"id"`
		Error  string `json:"error"`
	} `json:"resources"`
}

// One JSONL record per tenant — the contract B2/m39 read.
type record struct {
	Slug   string   `json:"slug"`
	Key    string   `json:"key,omitempty"`
	KeyID  string   `json:"key_id,omitempty"`
	DBIDs  []string `json:"db_ids"`
	Status string   `json:"status"` // created | exists | error
	Error  string   `json:"error,omitempty"`
}

func serviceHeaders(req *http.Request, token, body string) {
	if strings.EqualFold(os.Getenv("SERVICE_TOKEN_MODE"), "hmac") {
		req.Header.Set("X-Service-Auth",
			shared.ComputeServiceSignature(token, req.Method, req.URL.Path, []byte(body), time.Now().Unix()))
	} else {
		req.Header.Set("X-Service-Token", token)
	}
}

func provisionOne(client *http.Client, base, token, slug, plan, dsn, isolation string, mounts int) record {
	specs := make([]mountSpec, 0, mounts)
	for m := 0; m < mounts; m++ {
		specs = append(specs, mountSpec{
			Engine:           "postgresql",
			Name:             fmt.Sprintf("bench-m%d", m),
			ConnectionString: dsn,
			Isolation:        isolation,
		})
	}
	body, _ := json.Marshal(provisionRequest{
		Tenant:         slug,
		Name:           slug,
		Plan:           plan,
		DefaultKeyName: "scale-bench",
		SeedRoles:      false,
		Mounts:         specs,
	})
	req, err := http.NewRequest(http.MethodPost, base+"/v1/provision", bytes.NewReader(body))
	if err != nil {
		return record{Slug: slug, Status: "error", Error: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	serviceHeaders(req, token, string(body))

	resp, err := client.Do(req)
	if err != nil {
		return record{Slug: slug, Status: "error", Error: err.Error()}
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return record{Slug: slug, Status: "error",
			Error: fmt.Sprintf("provision %d: %s", resp.StatusCode, shared.RedactDSN(string(raw)))}
	}
	var out provisionResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return record{Slug: slug, Status: "error", Error: "bad provision response: " + err.Error()}
	}
	rec := record{Slug: slug, Status: "exists"}
	if out.APIKey != nil {
		rec.Key = out.APIKey.Key
		rec.KeyID = out.APIKey.ID
	}
	for _, r := range out.Resources {
		switch r.Kind {
		case "tenant":
			if r.Status == "created" {
				rec.Status = "created"
			}
		case "mount":
			if r.Status == "error" {
				rec.Status = "error"
				rec.Error = r.Error
			} else if r.ID != "" {
				rec.DBIDs = append(rec.DBIDs, r.ID)
			}
		}
	}
	if out.Outcome == "failed" {
		rec.Status = "error"
		if rec.Error == "" {
			rec.Error = "provision outcome: failed"
		}
	}
	return rec
}

func teardown(client *http.Client, base, token, outPath string) error {
	f, err := os.Open(outPath)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	n := 0
	for sc.Scan() {
		var rec record
		if json.Unmarshal(sc.Bytes(), &rec) != nil || rec.Slug == "" {
			continue
		}
		req, _ := http.NewRequest(http.MethodDelete, base+"/v1/tenants/"+rec.Slug, nil)
		serviceHeaders(req, token, "")
		if resp, err := client.Do(req); err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		n++
		if n%500 == 0 {
			fmt.Printf("  teardown %d…\n", n)
		}
	}
	fmt.Printf("teardown complete: %d tenants soft-deleted\n", n)
	return sc.Err()
}

func main() {
	var (
		n           = flag.Int("n", 1000, "number of tenants")
		base        = flag.String("base", shared.EnvStr("SCALE_TC_URL", "http://127.0.0.1:3022"), "tenant-control base URL")
		token       = flag.String("token", os.Getenv("INTERNAL_SERVICE_TOKEN"), "service token")
		dsn         = flag.String("dsn", os.Getenv("SCALE_MOUNT_DSN"), "postgres DSN for bench mounts")
		isolation   = flag.String("isolation", "shared_rls", "mount isolation (shared_rls|schema_per_tenant|db_per_tenant)")
		plan        = flag.String("plan", "pro", "tenant plan/tier (must allow the mount engine; pro/max allow postgresql+)")
		mounts      = flag.Int("mounts", 1, "mounts per tenant")
		concurrency = flag.Int("concurrency", 16, "parallel provisions (Argon2id is CPU-bound on tenant-control)")
		out         = flag.String("out", "artifacts/scale/tenants.jsonl", "output JSONL")
		prefix      = flag.String("prefix", "scale", "slug prefix")
		resume      = flag.Bool("resume", false, "skip slugs already present in -out")
		doTeardown  = flag.Bool("teardown", false, "soft-delete every tenant listed in -out")
	)
	flag.Parse()

	client := &http.Client{Timeout: 30 * time.Second}
	if *token == "" {
		fmt.Fprintln(os.Stderr, "missing -token / INTERNAL_SERVICE_TOKEN")
		os.Exit(2)
	}
	if *doTeardown {
		if err := teardown(client, *base, *token, *out); err != nil {
			fmt.Fprintln(os.Stderr, "teardown:", err)
			os.Exit(1)
		}
		return
	}
	if *dsn == "" {
		fmt.Fprintln(os.Stderr, "missing -dsn / SCALE_MOUNT_DSN")
		os.Exit(2)
	}

	done := map[string]bool{}
	if *resume {
		if f, err := os.Open(*out); err == nil {
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			for sc.Scan() {
				var rec record
				if json.Unmarshal(sc.Bytes(), &rec) == nil && rec.Status != "error" {
					done[rec.Slug] = true
				}
			}
			f.Close()
		}
	}

	_ = os.MkdirAll(filepath.Dir(*out), 0o755)
	mode := os.O_CREATE | os.O_WRONLY
	if *resume {
		mode |= os.O_APPEND
	} else {
		mode |= os.O_TRUNC
	}
	sink, err := os.OpenFile(*out, mode, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "open out:", err)
		os.Exit(1)
	}
	defer sink.Close()
	w := bufio.NewWriter(sink)
	defer w.Flush()
	var sinkMu sync.Mutex

	jobs := make(chan string)
	var wg sync.WaitGroup
	var created, exists, errs, total atomic.Int64
	start := time.Now()

	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for slug := range jobs {
				rec := provisionOne(client, *base, *token, slug, *plan, *dsn, *isolation, *mounts)
				switch rec.Status {
				case "created":
					created.Add(1)
				case "exists":
					exists.Add(1)
				default:
					errs.Add(1)
				}
				line, _ := json.Marshal(rec)
				sinkMu.Lock()
				_, _ = w.Write(line)
				_, _ = w.WriteString("\n")
				sinkMu.Unlock()
				if t := total.Add(1); t%500 == 0 {
					el := time.Since(start).Seconds()
					fmt.Printf("  %d/%d (%.0f/s) created=%d exists=%d errors=%d\n",
						t, *n, float64(t)/el, created.Load(), exists.Load(), errs.Load())
					sinkMu.Lock()
					_ = w.Flush()
					sinkMu.Unlock()
				}
			}
		}()
	}
	queued := 0
	for i := 1; i <= *n; i++ {
		slug := fmt.Sprintf("%s-%06d", *prefix, i)
		if done[slug] {
			continue
		}
		jobs <- slug
		queued++
	}
	close(jobs)
	wg.Wait()

	el := time.Since(start)
	fmt.Printf("done: queued=%d created=%d exists=%d errors=%d in %s (%.0f/s)\n",
		queued, created.Load(), exists.Load(), errs.Load(), el.Round(time.Second),
		float64(queued)/el.Seconds())
	// os.Exit skips deferred functions — flush the JSONL explicitly so error
	// records (the diagnosis) are never lost on a failing run.
	_ = w.Flush()
	_ = sink.Close()
	if errs.Load() > 0 {
		os.Exit(1)
	}
}
