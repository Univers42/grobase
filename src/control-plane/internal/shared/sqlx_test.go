package shared

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestIsUniqueViolation(t *testing.T) {
	uniq := &pgconn.PgError{Code: "23505"}
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain error", errors.New("boom"), false},
		{"other pg code", &pgconn.PgError{Code: "23503"}, false},
		{"direct 23505", uniq, true},
		{"wrapped 23505", fmt.Errorf("insert failed: %w", uniq), true},
		{"double wrapped", fmt.Errorf("outer: %w", fmt.Errorf("inner: %w", uniq)), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := IsUniqueViolation(c.err); got != c.want {
				t.Fatalf("IsUniqueViolation = %v, want %v", got, c.want)
			}
		})
	}
}

func TestNullableTime(t *testing.T) {
	if NullableTime(time.Time{}) != nil {
		t.Fatal("zero time must map to nil")
	}
	loc := time.FixedZone("X", 3600)
	in := time.Date(2026, 6, 17, 12, 0, 0, 0, loc)
	got, ok := NullableTime(in).(time.Time)
	if !ok {
		t.Fatalf("non-zero time must map to time.Time, got %T", NullableTime(in))
	}
	if got.Location() != time.UTC {
		t.Fatalf("must be normalized to UTC, got %v", got.Location())
	}
	if !got.Equal(in) {
		t.Fatalf("instant changed: %v != %v", got, in)
	}
}
