package push

import (
	"errors"
	"net/http"
	"testing"
)

// TestAllowlistedDialControl: the allowlisted path reaches loopback and private
// space but never a metadata address, IPv4-mapped forms included.
func TestAllowlistedDialControl(t *testing.T) {
	cases := []struct {
		addr    string
		blocked bool
	}{
		{"127.0.0.1:8080", false},
		{"10.0.0.5:8080", false},
		{"[fd12::5]:8080", false},
		{"169.254.169.254:80", true},
		{"[::ffff:169.254.169.254]:80", true},
		{"[fe80::1]:80", true},
		{"[fd00:ec2::254]:80", true},
		{"100.100.100.200:80", true},
	}
	for _, tc := range cases {
		err := allowlistedDialControl("tcp", tc.addr, nil)
		if got := errors.Is(err, ErrBlockedTarget); got != tc.blocked {
			t.Errorf("allowlistedDialControl(%s) = %v, want blocked=%v", tc.addr, err, tc.blocked)
		}
	}
}

// TestDispatcherIgnoresProxyEnv: the push transport never routes through
// HTTP(S)_PROXY, where the dial guard would only see the proxy.
func TestDispatcherIgnoresProxyEnv(t *testing.T) {
	if newDispatcher().client.Transport.(*http.Transport).Proxy != nil {
		t.Fatal("push transport honours proxy env — the dial guard would check the proxy, not the target")
	}
}
