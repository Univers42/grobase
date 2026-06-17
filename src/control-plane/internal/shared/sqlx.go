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
