package tenants

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestIsUniqueViolation(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain error", errors.New("boom"), false},
		{"direct 23505", &pgconn.PgError{Code: "23505"}, true},
		// The bug: pgx surfaces the 23505 wrapped, during row scan.
		{"wrapped 23505", fmt.Errorf("scan: %w", &pgconn.PgError{Code: "23505"}), true},
		{"other pg code", &pgconn.PgError{Code: "23503"}, false},
	}
	for _, c := range cases {
		if got := isUniqueViolation(c.err); got != c.want {
			t.Errorf("%s: isUniqueViolation = %v, want %v", c.name, got, c.want)
		}
	}
}
