package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	"github.com/dlesieur/mini-baas/control-plane/internal/config"
)

type seedConfig struct {
	n, mounts, concurrency      *int
	base, token, dsn, isolation *string
	plan, out, prefix           *string
	resume, doTeardown          *bool
}

func parseFlags() seedConfig {
	c := seedConfig{
		n:           flag.Int("n", 1000, "number of tenants"),
		base:        flag.String("base", config.EnvStr("SCALE_TC_URL", "http://127.0.0.1:3022"), "tenant-control base URL"),
		token:       flag.String("token", os.Getenv("INTERNAL_SERVICE_TOKEN"), "service token"),
		dsn:         flag.String("dsn", os.Getenv("SCALE_MOUNT_DSN"), "postgres DSN for bench mounts"),
		isolation:   flag.String("isolation", "shared_rls", "mount isolation (shared_rls|schema_per_tenant|db_per_tenant)"),
		plan:        flag.String("plan", "pro", "tenant plan/tier (must allow the mount engine; pro/max allow postgresql+)"),
		mounts:      flag.Int("mounts", 1, "mounts per tenant"),
		concurrency: flag.Int("concurrency", 16, "parallel provisions (Argon2id is CPU-bound on tenant-control)"),
		out:         flag.String("out", "artifacts/scale/tenants.jsonl", "output JSONL"),
		prefix:      flag.String("prefix", "scale", "slug prefix"),
		resume:      flag.Bool("resume", false, "skip slugs already present in -out"),
		doTeardown:  flag.Bool("teardown", false, "soft-delete every tenant listed in -out"),
	}
	flag.Parse()
	return c
}

func loadDone(out string, resume bool) map[string]bool {
	done := map[string]bool{}
	if !resume {
		return done
	}
	f, err := os.Open(out)
	if err != nil {
		return done
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		var rec record
		if json.Unmarshal(sc.Bytes(), &rec) == nil && rec.Status != "error" {
			done[rec.Slug] = true
		}
	}
	return done
}

func openSink(out string, resume bool) (*os.File, error) {
	_ = os.MkdirAll(filepath.Dir(out), 0o755)
	mode := os.O_CREATE | os.O_WRONLY
	if resume {
		mode |= os.O_APPEND
	} else {
		mode |= os.O_TRUNC
	}
	return os.OpenFile(out, mode, 0o600)
}

// seed runs the bulk provision and streams JSONL records to the out file. On a
// failing run (errs > 0) it exits non-zero, but os.Exit skips deferred
// functions, so the JSONL is flushed explicitly first — error records (the
// diagnosis) are never lost.
func seed(client *http.Client, cfg seedConfig) error {
	done := loadDone(*cfg.out, *cfg.resume)
	sink, err := openSink(*cfg.out, *cfg.resume)
	if err != nil {
		return fmt.Errorf("open out: %w", err)
	}
	defer sink.Close()
	w := bufio.NewWriter(sink)
	defer w.Flush()
	if errs := runWorkers(client, cfg, done, w); errs > 0 {
		_ = w.Flush()
		_ = sink.Close()
		os.Exit(1)
	}
	return nil
}
