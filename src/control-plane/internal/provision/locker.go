package provision

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// locker MUST acquire AND release on the SAME PoolConn — the pool-level
// DB/AdminQuery/AdminExec abstraction cannot express that affinity.
type PoolConn interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Release()
}

// ConnAcquirer hands out a dedicated connection for the lock's whole lifetime.
// *shared.Postgres satisfies it via AcquireConn.
type ConnAcquirer interface {
	AcquireConn(ctx context.Context) (*pgxpool.Conn, error)
}

// connAcquirer adapts a ConnAcquirer to return the PoolConn interface so the
// locker logic stays decoupled from *pgxpool.Conn (and unit-testable with a fake).
type connAcquirerFunc func(ctx context.Context) (PoolConn, error)

func (f connAcquirerFunc) acquire(ctx context.Context) (PoolConn, error) { return f(ctx) }

type connSource interface {
	acquire(ctx context.Context) (PoolConn, error)
}

// pgLocker implements Locker via a CONNECTION-AFFINE session advisory lock: it
// pins one connection for the entire reconcile, takes pg_try_advisory_lock on
// it, and releases the lock + the connection together. This actually serializes
// concurrent same-slug reconciles (the prior pool-level impl did not — acquire
// and release landed on different pooled connections, making it a no-op).
type pgLocker struct{ src connSource }

// NewPGLocker builds a connection-affine Postgres advisory-lock Locker.
func NewPGLocker(src ConnAcquirer) Locker {
	return newPGLockerWithSource(connAcquirerFunc(func(ctx context.Context) (PoolConn, error) {
		return src.AcquireConn(ctx)
	}))
}

// newPGLockerWithSource is the testable seam: it takes a connSource directly so a
// fake PoolConn can verify acquire/release land on the SAME connection (real
// connection affinity) without a live Postgres.
func newPGLockerWithSource(src connSource) Locker { return &pgLocker{src: src} }

func (l *pgLocker) TryLock(ctx context.Context, slug string) (func(), bool, error) {
	conn, err := l.src.acquire(ctx)
	if err != nil {
		return nil, false, err
	}
	rows, err := conn.Query(ctx, sqlTryAdvisoryLock, slug)
	if err != nil {
		conn.Release()
		return nil, false, err
	}
	var ok bool
	if scanErr := scanBool(rows, &ok); scanErr != nil {
		conn.Release()
		return nil, false, scanErr
	}
	if !ok {
		// Lock held elsewhere → fast-fail to 409. Return the connection
		// immediately; we never took the lock so there is nothing to unlock.
		conn.Release()
		return nil, false, nil
	}
	release := func() {
		// Release the lock on the SAME connection that holds it, THEN return the
		// connection to the pool. A fresh background ctx so unlock still runs when
		// the request ctx is already cancelled; the session lock also drops on
		// conn close, so this is belt-and-suspenders.
		_, _ = conn.Exec(context.Background(), sqlAdvisoryUnlock, slug)
		conn.Release()
	}
	return release, true, nil
}

func scanBool(rows pgx.Rows, dst *bool) error {
	defer rows.Close()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	return rows.Scan(dst)
}
