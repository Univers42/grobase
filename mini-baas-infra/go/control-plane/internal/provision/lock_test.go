package provision

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// fakeConn is a fake PoolConn that records every call so a test can prove the
// advisory-lock acquire (Query) and release (Exec) run on the SAME connection,
// and that the connection is returned to the pool exactly once.
type fakeConn struct {
	id        int
	shared    *lockState // shared advisory-lock slot (per-slug serialization)
	queryRan  bool
	execRan   bool
	released  bool
	lockedKey string
}

// lockState models Postgres' session-advisory-lock slot for one key: only one
// connection can hold it at a time. unlock clears it.
type lockState struct {
	held    bool
	heldBy  int // conn id holding it
	key     string
	acquire func() bool // returns true if THIS conn took the lock
}

// boolRows is a one-row pgx.Rows yielding a single bool, enough for scanBool.
type boolRows struct {
	val  bool
	done bool
}

func (r *boolRows) Next() bool {
	if r.done {
		return false
	}
	r.done = true
	return true
}
func (r *boolRows) Scan(dest ...any) error {
	if p, ok := dest[0].(*bool); ok {
		*p = r.val
	}
	return nil
}
func (r *boolRows) Close()                                       {}
func (r *boolRows) Err() error                                   { return nil }
func (r *boolRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *boolRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *boolRows) Values() ([]any, error)                       { return nil, nil }
func (r *boolRows) RawValues() [][]byte                          { return nil }
func (r *boolRows) Conn() *pgx.Conn                              { return nil }

func (c *fakeConn) Query(_ context.Context, _ string, args ...any) (pgx.Rows, error) {
	c.queryRan = true
	took := c.shared.acquire() // try to take the slot for this conn
	if took {
		c.shared.heldBy = c.id
		c.lockedKey, _ = args[0].(string)
	}
	return &boolRows{val: took}, nil
}

func (c *fakeConn) Exec(_ context.Context, _ string, _ ...any) (pgconn.CommandTag, error) {
	c.execRan = true
	// Release only if THIS conn holds the lock (mirrors pg_advisory_unlock).
	if c.shared.held && c.shared.heldBy == c.id {
		c.shared.held = false
		c.shared.heldBy = 0
	}
	return pgconn.CommandTag{}, nil
}

func (c *fakeConn) Release() { c.released = true }

// fakeConnSource hands out a fresh fakeConn per acquire, all sharing one
// advisory-lock slot — modeling distinct pooled connections contending for the
// same session lock.
type fakeConnSource struct {
	slot     *lockState
	acquired int
	failNext bool
}

func (s *fakeConnSource) acquire(_ context.Context) (PoolConn, error) {
	if s.failNext {
		return nil, errors.New("acquire failed")
	}
	s.acquired++
	if s.slot.acquire == nil {
		s.slot.acquire = func() bool {
			if s.slot.held {
				return false
			}
			s.slot.held = true
			return true
		}
	}
	return &fakeConn{id: s.acquired, shared: s.slot}, nil
}

// TestPGLockerConnectionAffinity proves the lock is connection-affine: a single
// TryLock takes the lock on one conn and the returned release() runs the unlock
// Exec on the SAME conn before returning it to the pool.
func TestPGLockerConnectionAffinity(t *testing.T) {
	src := &fakeConnSource{slot: &lockState{}}
	lk := newPGLockerWithSource(src)

	release, ok, err := lk.TryLock(context.Background(), "acme")
	if err != nil {
		t.Fatalf("TryLock error: %v", err)
	}
	if !ok {
		t.Fatal("first TryLock should acquire the lock")
	}
	if !src.slot.held {
		t.Fatal("advisory lock slot must be held after acquire")
	}
	release()
	if src.slot.held {
		t.Error("release() must unlock the advisory lock")
	}
}

// TestPGLockerSerializesSameSlug proves real mutual exclusion: while one holder
// has the lock, a second TryLock on the same slug fast-fails (ok=false) — the
// 409/ErrBusy path. After release, a third TryLock succeeds again.
func TestPGLockerSerializesSameSlug(t *testing.T) {
	src := &fakeConnSource{slot: &lockState{}}
	lk := newPGLockerWithSource(src)

	release1, ok1, err := lk.TryLock(context.Background(), "acme")
	if err != nil || !ok1 {
		t.Fatalf("first TryLock should succeed: ok=%v err=%v", ok1, err)
	}

	_, ok2, err := lk.TryLock(context.Background(), "acme")
	if err != nil {
		t.Fatalf("second TryLock error: %v", err)
	}
	if ok2 {
		t.Fatal("second concurrent TryLock on same slug MUST fail (busy → 409)")
	}

	release1()

	release3, ok3, err := lk.TryLock(context.Background(), "acme")
	if err != nil || !ok3 {
		t.Fatalf("TryLock after release should succeed again: ok=%v err=%v", ok3, err)
	}
	release3()
}

// TestPGLockerBusyReleasesConn proves the fast-fail (busy) path does NOT leak a
// pooled connection: when the lock is already held, the acquired conn is
// released immediately (no unlock, since we never took the lock).
func TestPGLockerBusyReleasesConn(t *testing.T) {
	// Pre-hold the slot so the next acquire's Query returns false.
	slot := &lockState{}
	src := &fakeConnSource{slot: slot}
	lk := newPGLockerWithSource(src)

	release1, ok1, _ := lk.TryLock(context.Background(), "acme")
	if !ok1 {
		t.Fatal("setup: first lock should be held")
	}

	// Capture the busy-path conn by wrapping acquire.
	var busyConn *fakeConn
	src2 := &fakeConnSource{slot: slot}
	wrapped := connAcquirerFunc(func(ctx context.Context) (PoolConn, error) {
		c, err := src2.acquire(ctx)
		busyConn, _ = c.(*fakeConn)
		return c, err
	})
	lk2 := newPGLockerWithSource(wrapped)

	_, ok2, _ := lk2.TryLock(context.Background(), "acme")
	if ok2 {
		t.Fatal("busy path should not acquire")
	}
	if busyConn == nil || !busyConn.released {
		t.Error("busy path must release the checked-out connection (no leak)")
	}
	if busyConn != nil && busyConn.execRan {
		t.Error("busy path must NOT run unlock Exec (it never took the lock)")
	}
	release1()
}

// TestPGLockerAcquireErrorPropagates ensures a pool acquire failure surfaces as
// an error (the reconciler turns it into a transport error, not a false busy).
func TestPGLockerAcquireErrorPropagates(t *testing.T) {
	src := &fakeConnSource{slot: &lockState{}, failNext: true}
	lk := newPGLockerWithSource(src)
	if _, _, err := lk.TryLock(context.Background(), "acme"); err == nil {
		t.Error("acquire failure must propagate as an error")
	}
}
