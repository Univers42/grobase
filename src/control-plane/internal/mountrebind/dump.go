package mountrebind

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/dlesieur/mini-baas/control-plane/internal/adapterregistry"
)

// Config is the first stdin line of cmd/mount-rebind: both keys and the target logins.
type Config struct {
	SourceKey string   `json:"source_key"`
	TargetKey string   `json:"target_key"`
	Targets   []Target `json:"targets"`
}

// Row is the report for one tenant_databases row: never a DSN, only what happened to it.
// Resealed means its ciphertext is now under the target key.
type Row struct {
	ID       string  `json:"id"`
	Engine   string  `json:"engine"`
	Outcome  Outcome `json:"outcome"`
	Resealed bool    `json:"resealed"`
}

// Stats is what RewriteDump saw: the tenant_databases COPY blocks, and one Row per row.
type Stats struct {
	Blocks int   `json:"blocks"`
	Rows   []Row `json:"rows"`
}

const copyHeader = "COPY public.tenant_databases ("

type rewriter struct {
	source, target *adapterregistry.Encryptor
	targets        []Target
	stats          Stats
}

// RewriteDump copies a plain pg_dumpall stream from r to w, rewriting only the cipher
// columns of the public.tenant_databases rows the source key opens: each is re-sealed under
// the target key, with the DSN RewriteDSN returns for it.
func RewriteDump(r *bufio.Reader, w io.Writer, cfg Config) (Stats, error) {
	src, err := adapterregistry.NewEncryptor(cfg.SourceKey)
	if err != nil {
		return Stats{}, fmt.Errorf("source key: %w", err)
	}
	dst, err := adapterregistry.NewEncryptor(cfg.TargetKey)
	if err != nil {
		return Stats{}, fmt.Errorf("target key: %w", err)
	}
	rw := &rewriter{source: src, target: dst, targets: cfg.Targets}
	err = rw.copy(r, w)
	return rw.stats, err
}

// copy streams line by line, carrying the column index while inside a tenant_databases
// COPY block; a final line without '\n' is written as read.
func (rw *rewriter) copy(r *bufio.Reader, w io.Writer) error {
	var cols map[string]int
	for {
		line, readErr := r.ReadString('\n')
		out, next, err := rw.line(line, cols)
		if err != nil {
			return err
		}
		cols = next
		if _, err := io.WriteString(w, out); err != nil {
			return err
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
}

// line returns the text to write for one input line and the column index to carry: set by
// a tenant_databases COPY header, cleared by its terminating "\.".
func (rw *rewriter) line(line string, cols map[string]int) (string, map[string]int, error) {
	switch {
	case cols == nil && strings.HasPrefix(line, copyHeader):
		rw.stats.Blocks++
		return line, columnIndex(line), nil
	case cols == nil || line == "":
		return line, cols, nil
	case strings.TrimRight(line, "\n") == `\.`:
		return line, nil, nil
	}
	out, err := rw.row(line, cols)
	return out, cols, err
}

// columnIndex maps each column named in a COPY header to its position in the row.
func columnIndex(header string) map[string]int {
	inner := header[len(copyHeader):strings.IndexByte(header, ')')]
	names := strings.Split(inner, ",")
	cols := make(map[string]int, len(names))
	for i, c := range names {
		cols[strings.TrimSpace(c)] = i
	}
	return cols
}
