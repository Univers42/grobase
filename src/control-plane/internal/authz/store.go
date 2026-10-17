package authz

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/dlesieur/mini-baas/control-plane/internal/pg"
)

// ErrNoModel means the app has not PUT a model yet.
var ErrNoModel = errors.New("no authz model for this app")

// Config sizes the store. Caveat: the defaults come from the m232 bench on one
// local postgres (16 clients); a remote database with real latency holds a
// connection longer per check, so MaxConcurrent may need to go up with it.
type Config struct {
	MaxConcurrent int           // checks holding a connection at once
	QueueWait     time.Duration // how long an extra check waits for a slot
	Timeout       time.Duration // whole check, transaction included
	Limits        Limits
	// ObserveHold, when set, receives how long each check held its connection.
	ObserveHold func(time.Duration)
}

// DefaultConfig keeps checks to half of pgxpool's default (max(4, NumCPU)) on a
// small box, with a short queue so overload answers 503 quickly.
func DefaultConfig() Config {
	return Config{MaxConcurrent: 4, QueueWait: 250 * time.Millisecond, Timeout: 3 * time.Second, Limits: DefaultLimits()}
}

// Store runs authz reads and writes over the admin pool.
type Store struct {
	db   *pg.Postgres
	gate *Gate
	cfg  Config
	log  *slog.Logger
}

// NewStore wires the pool, a bounded gate and a logger.
func NewStore(db *pg.Postgres, log *slog.Logger, cfg Config) *Store {
	return &Store{db: db, gate: NewGate(cfg.MaxConcurrent, cfg.QueueWait), cfg: cfg, log: log}
}

// Check answers q for q.App from one snapshot. A full gate, a timeout or any
// store error is ErrUnavailable: the caller must not read it as a deny.
func (s *Store) Check(ctx context.Context, q Query) ([]Decision, error) {
	release, err := s.gate.Acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer release()
	ctx, cancel := context.WithTimeout(ctx, s.cfg.Timeout)
	defer cancel()
	ds, err := s.checkInTx(ctx, q)
	if err != nil && !isCallerError(err) {
		s.log.Warn("authz check failed", "app", q.App, "err", err)
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	return ds, err
}

// isCallerError separates a bad request (no model, unknown permission) from a
// store failure.
func isCallerError(err error) bool {
	return errors.Is(err, ErrNoModel) || errors.Is(err, ErrUnknownPermission)
}

func (s *Store) checkInTx(ctx context.Context, q Query) ([]Decision, error) {
	start := time.Now()
	tx, err := s.db.BeginTxOpts(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer func() {
		_ = tx.Rollback(context.WithoutCancel(ctx))
		if s.cfg.ObserveHold != nil {
			s.cfg.ObserveHold(time.Since(start))
		}
	}()
	model, err := readModel(ctx, tx, q.App)
	if err != nil {
		return nil, err
	}
	ev := &Evaluator{Model: model, Limits: s.cfg.Limits, Log: s.log}
	return ev.Check(ctx, pgSource{q: tx, app: q.App}, q)
}
