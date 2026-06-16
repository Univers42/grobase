package funcsecrets

import "testing"

func TestSetRequestValidate(t *testing.T) {
	ok := []string{"API_KEY", "_x", "STRIPE_SECRET_KEY", "a", "A1_b2"}
	for _, k := range ok {
		if err := (SetRequest{Key: k}).Validate(); err != nil {
			t.Fatalf("key %q should be valid: %v", k, err)
		}
	}
	bad := []string{"", "1KEY", "has space", "has-dash", "weird$", "a.b"}
	for _, k := range bad {
		if err := (SetRequest{Key: k}).Validate(); err == nil {
			t.Fatalf("key %q should be invalid", k)
		}
	}
}
