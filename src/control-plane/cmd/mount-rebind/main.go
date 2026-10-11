// Command mount-rebind re-targets a plain pg_dumpall seed at another grobase deployment.
//
// stdin: one JSON line (mountrebind.Config: source_key, target_key, targets), then the dump.
// stdout: the dump with only the public.tenant_databases cipher columns of rebound rows
// changed. stderr: one JSON report of ids, engines and outcomes, never a DSN or a key.
// Keys travel on stdin so they never reach argv, the environment or disk.
//
// Exit codes: 0 rewritten · 1 I/O, key or encryption failure · 2 bad config line, no
// tenant_databases block, or a row refused.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/dlesieur/mini-baas/control-plane/internal/mountrebind"
)

type exitErr struct {
	code int
	msg  string
}

func (e exitErr) Error() string { return e.msg }

func main() {
	if err := run(os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "mount-rebind:", err)
		var e exitErr
		if errors.As(err, &e) {
			os.Exit(e.code)
		}
		os.Exit(1)
	}
}

// run reads the config line, streams the rewritten dump to stdout and reports to stderr.
func run(stdin io.Reader, stdout, stderr io.Writer) error {
	in := bufio.NewReaderSize(stdin, 1<<20)
	first, err := in.ReadBytes('\n')
	if err != nil {
		return exitErr{2, "stdin must start with one JSON config line"}
	}
	var cfg mountrebind.Config
	if err := json.Unmarshal(first, &cfg); err != nil {
		return exitErr{2, "config line is not valid JSON"}
	}
	out := bufio.NewWriterSize(stdout, 1<<20)
	stats, err := mountrebind.RewriteDump(in, out, cfg)
	if err != nil {
		return err
	}
	if err := out.Flush(); err != nil {
		return err
	}
	if err := json.NewEncoder(stderr).Encode(stats); err != nil {
		return err
	}
	return verdict(stats)
}

// verdict turns a finished rewrite into an exit status: a dump with no tenant_databases
// block is the wrong file, and a refused row would point a mount at the wrong login.
func verdict(stats mountrebind.Stats) error {
	if stats.Blocks == 0 {
		return exitErr{2, "no COPY public.tenant_databases block in the dump"}
	}
	for _, r := range stats.Rows {
		if r.Outcome == mountrebind.Refused {
			return exitErr{2, "row " + r.ID + " refused: " + string(r.Outcome)}
		}
	}
	return nil
}
