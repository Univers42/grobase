package shared

import (
	"errors"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// IsUniqueViolation reports whether err is a PostgreSQL unique-constraint
// violation (SQLSTATE 23505) — used to turn a duplicate insert into a 409 rather
// than a 500.
func IsUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// NullableTime returns nil for a zero time, otherwise the time in UTC. It maps a
// Go time.Time to a JSON null / SQL NULL without a sentinel.
func NullableTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC()
}

// NullableStr returns nil for an empty string, otherwise the string — mapping a
// Go string to a SQL NULL / JSON null without a sentinel. Note: it does NOT trim
// whitespace; a caller that must treat "   " as NULL has different semantics and
// should not use this.
func NullableStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// NullableInt returns nil for a zero int, otherwise the int — mapping a Go int to
// a SQL NULL / JSON null without a sentinel.
func NullableInt(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

// NullableStrSlice returns nil for a nil slice, otherwise the slice — so an
// absent list maps to SQL NULL / JSON null rather than an empty array. An empty
// (non-nil) slice passes through unchanged.
func NullableStrSlice(s []string) any {
	if s == nil {
		return nil
	}
	return s
}
