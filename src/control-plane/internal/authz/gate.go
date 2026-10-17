package authz

import (
	"context"
	"errors"
	"time"
)

// ErrUnavailable means the check could not run: every slot was busy for the
// whole wait, or the store failed. The handler answers 503 authz_unavailable.
var ErrUnavailable = errors.New("authz unavailable")

// Gate bounds how many checks hold a database connection at once, so a burst
// of checks cannot starve the rest of tenant-control of the shared pool.
// Caveat: it is a count, not a reservation: the shared pool can still be
// exhausted by other callers, in which case a check waits on the pool inside
// its own timeout and fails with ErrUnavailable.
type Gate struct {
	slots chan struct{}
	wait  time.Duration
}

// NewGate allows size concurrent holders and makes a caller wait at most wait.
func NewGate(size int, wait time.Duration) *Gate {
	return &Gate{slots: make(chan struct{}, max(size, 1)), wait: wait}
}

// Acquire takes a slot or fails with ErrUnavailable after the wait. The
// returned func must be called exactly once.
func (g *Gate) Acquire(ctx context.Context) (func(), error) {
	select {
	case g.slots <- struct{}{}:
		return g.release, nil
	default:
	}
	timer := time.NewTimer(g.wait)
	defer timer.Stop()
	select {
	case g.slots <- struct{}{}:
		return g.release, nil
	case <-timer.C:
		return nil, ErrUnavailable
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (g *Gate) release() { <-g.slots }
