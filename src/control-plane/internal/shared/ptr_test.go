package shared

import "testing"

func TestDerefStr(t *testing.T) {
	if got := DerefStr(nil); got != "" {
		t.Fatalf("nil pointer must deref to empty, got %q", got)
	}
	s := "hello"
	if got := DerefStr(&s); got != "hello" {
		t.Fatalf("non-nil must deref to value, got %q", got)
	}
	empty := ""
	if got := DerefStr(&empty); got != "" {
		t.Fatalf("pointer to empty must deref to empty, got %q", got)
	}
}
