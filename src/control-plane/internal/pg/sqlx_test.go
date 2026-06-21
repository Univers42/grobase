/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlx_test.go                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:56 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:58 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

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

func TestNullableStr(t *testing.T) {
	if NullableStr("") != nil {
		t.Fatal("empty string must map to nil")
	}
	if got := NullableStr("x"); got != "x" {
		t.Fatalf("non-empty must pass through, got %v", got)
	}
	if got := NullableStr("   "); got != "   " {
		t.Fatalf("whitespace must NOT be trimmed (passes through), got %q", got)
	}
}

func TestNullableInt(t *testing.T) {
	if NullableInt(0) != nil {
		t.Fatal("zero must map to nil")
	}
	for _, n := range []int{1, -1, 1 << 30} {
		if got := NullableInt(n); got != n {
			t.Fatalf("non-zero %d must pass through, got %v", n, got)
		}
	}
}

func TestNullableStrSlice(t *testing.T) {
	if NullableStrSlice(nil) != nil {
		t.Fatal("nil slice must map to nil")
	}
	empty := []string{}
	if got := NullableStrSlice(empty); got == nil {
		t.Fatal("empty (non-nil) slice must pass through, not become nil")
	}
	in := []string{"a", "b"}
	got, ok := NullableStrSlice(in).([]string)
	if !ok || len(got) != 2 || got[0] != "a" || got[1] != "b" {
		t.Fatalf("non-empty slice must pass through unchanged, got %v", NullableStrSlice(in))
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
