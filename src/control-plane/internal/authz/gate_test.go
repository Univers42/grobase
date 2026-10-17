package authz

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestGateOverflowIsUnavailable(t *testing.T) {
	g := NewGate(2, 20*time.Millisecond)
	ctx := context.Background()
	r1, err1 := g.Acquire(ctx)
	r2, err2 := g.Acquire(ctx)
	if err1 != nil || err2 != nil {
		t.Fatalf("first two acquires: %v %v", err1, err2)
	}
	if _, err := g.Acquire(ctx); !errors.Is(err, ErrUnavailable) {
		t.Fatalf("third acquire: %v, want ErrUnavailable", err)
	}
	r1()
	r3, err := g.Acquire(ctx)
	if err != nil {
		t.Fatalf("after a release: %v", err)
	}
	r2()
	r3()
}

func TestGateWaitsForARelease(t *testing.T) {
	g := NewGate(1, time.Second)
	rel, _ := g.Acquire(context.Background())
	go func() { time.Sleep(10 * time.Millisecond); rel() }()
	r, err := g.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	r()
}
