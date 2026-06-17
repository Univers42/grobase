package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"syscall"
	"time"
)

// deliverTimeout caps one outbound delivery (mirrors webhooks' per-attempt
// timeout default). A slow/blackholing subscriber can never hang the send.
const deliverTimeout = 10 * time.Second

// dispatcher performs the outbound HTTP POST to a subscription's target_url. It
// reuses internal/webhooks' delivery discipline: a per-request timeout and — the
// load-bearing security wall — an SSRF guard that resolves the host and REFUSES
// to POST to any private/loopback/link-local/unspecified address. Without this a
// tenant could register a subscription pointing at http://169.254.169.254/ (the
// cloud metadata endpoint) or the in-cluster Postgres and coerce the control
// plane into a server-side request forgery. The guard runs at register time
// (reject the subscription before it is stored), at send time (guardTarget
// re-check), AND at dial time (the http.Client pins the validated IP — see
// newDispatcher), so a DNS name that rebinds between resolution and connection
// is still refused.
type dispatcher struct {
	client *http.Client
}

// newDispatcher builds the SSRF-hardened HTTP client.
//
// @brief Construct the push HTTP client with a dial-time SSRF guard (rebind fix).
//
// @par Vulnerability (CWE-918 Server-Side Request Forgery — DNS rebinding)
// guardTarget validates a hostname with net.LookupIP, but http.Client.Do then
// performs its OWN independent DNS resolution when dialing. Because the validated
// lookup and the connecting lookup are two distinct queries against an
// attacker-controlled name, a low-TTL/rebinding record can return a public IP to
// the guard and a private/metadata IP (e.g. 169.254.169.254) to the transport —
// defeating the guard within a single Send call. A send-time re-check only closes
// the register→send window, not the resolve→connect window.
//
// @par Remediation
// The client's dialer carries a net.Dialer.Control hook (pinnedDialControl) that
// runs AFTER name resolution with the concrete ip:port the kernel is about to
// connect to, and re-applies isBlockedIP to that exact address — so the IP
// validated is the IP connected to, closing the within-call rebinding window for
// both the send and register-then-trigger paths.
//
// @see https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
// @see https://cwe.mitre.org/data/definitions/918.html
func newDispatcher() *dispatcher {
	dialer := &net.Dialer{Timeout: deliverTimeout, Control: pinnedDialControl}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = dialer.DialContext
	return &dispatcher{client: &http.Client{Timeout: deliverTimeout, Transport: transport}}
}

// pinnedDialControl is the dial-time half of the SSRF guard: it receives the
// concrete post-resolution address the kernel is about to connect to and refuses
// any private/loopback/link-local/metadata IP, so a rebinding DNS name cannot
// slip an internal address past guardTarget's earlier lookup.
func pinnedDialControl(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); ip != nil && isBlockedIP(ip) {
		return fmt.Errorf("%w: refusing to dial blocked address %s", ErrBlockedTarget, host)
	}
	return nil
}

// notification is the JSON payload POSTed to a subscription. It is FCM-shaped
// (a `notification` object + an optional `data` bag) so an FCM-compatible
// endpoint accepts it unchanged, while a plain webhook receives the same
// self-describing document.
type notification struct {
	Notification struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	} `json:"notification"`
	Data           map[string]string `json:"data,omitempty"`
	TenantID       string            `json:"tenant_id"`
	NotificationID string            `json:"notification_id"`
}

// deliver POSTs the notification to sub.TargetURL and returns the HTTP status
// (0 on a transport error) and an error on a non-2xx / transport failure. The
// SSRF guard is re-applied here (send-time re-check) BEFORE any byte leaves the
// process. If the subscription carries a sealed FCM token it is sent as a
// Bearer authorization header (the FCM-compatible auth path); the webhook path
// carries none.
func (d *dispatcher) deliver(ctx context.Context, target, bearer string, body []byte) (int, error) {
	if err := guardTarget(target); err != nil {
		return 0, err
	}
	reqCtx, cancel := context.WithTimeout(ctx, deliverTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "mini-baas-push/1.0")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}

	resp, err := d.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.StatusCode, nil
	}
	return resp.StatusCode, fmt.Errorf("non-2xx response: %d", resp.StatusCode)
}

// marshalNotification builds the wire payload once per send (reused across all
// matching subscriptions).
func marshalNotification(tenantID, notifID string, req SendRequest) ([]byte, error) {
	var n notification
	n.Notification.Title = req.Title
	n.Notification.Body = req.Body
	n.Data = req.Data
	n.TenantID = tenantID
	n.NotificationID = notifID
	return json.Marshal(n)
}

// guardTarget is the SSRF wall (mirrors the intent of webhooks' outbound guard).
// It rejects a target_url that is not a public http(s) endpoint:
//   - a non-http(s) scheme,
//   - a host that IS a literal private/loopback/link-local/unspecified IP, or
//   - a hostname EVERY resolved A/AAAA record of which is private/loopback/
//     link-local/unspecified (a hostname that resolves to a public IP is allowed;
//     one that resolves only to internal space — e.g. an internal DNS name or a
//     rebinding name — is refused).
//
// Refusing on resolution failure is intentional fail-closed: a name we cannot
// resolve is not a proven-public destination.
func guardTarget(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return fmt.Errorf("%w: scheme must be http(s)", ErrBlockedTarget)
	}
	host := u.Hostname()
	if host == "" {
		return fmt.Errorf("%w: empty host", ErrBlockedTarget)
	}
	// A narrow operator allowlist (PUSH_SSRF_ALLOW_HOSTS, comma-separated host
	// entries; default empty) permits naming specific internal webhook targets for
	// in-cluster delivery — e.g. a private notification relay reachable only on the
	// cluster network. Default empty => nothing private is allowed => the SSRF guard
	// below applies unchanged (production stays SSRF-locked = byte-parity). Only an
	// EXACT host match is trusted; every other internal address stays blocked.
	if hostAllowlisted(host) {
		return nil
	}
	// A literal IP target is checked directly.
	if ip := net.ParseIP(host); ip != nil {
		if isBlockedIP(ip) {
			return fmt.Errorf("%w: %s is a private/loopback/link-local address", ErrBlockedTarget, host)
		}
		return nil
	}
	// A hostname: resolve and require at least one public IP, and reject if ANY
	// resolved address is internal (a name resolving to a mix is suspicious —
	// fail closed on the safe side).
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return fmt.Errorf("%w: cannot resolve %q to a public address", ErrBlockedTarget, host)
	}
	for _, ip := range ips {
		if isBlockedIP(ip) {
			return fmt.Errorf("%w: %s resolves to internal address %s", ErrBlockedTarget, host, ip)
		}
	}
	return nil
}

// hostAllowlisted reports whether host is named in PUSH_SSRF_ALLOW_HOSTS — a
// comma-separated allowlist of hostnames/IPs the operator explicitly trusts for
// in-cluster delivery. Default empty => always false => the SSRF guard applies
// unchanged (byte-parity). This is the deliberate, opt-in operator escape hatch
// for delivering to a known private endpoint without weakening the guard for any
// other target; only an exact (case-insensitive) host match is trusted.
func hostAllowlisted(host string) bool {
	raw := strings.TrimSpace(os.Getenv("PUSH_SSRF_ALLOW_HOSTS"))
	if raw == "" {
		return false
	}
	for _, entry := range strings.Split(raw, ",") {
		if e := strings.TrimSpace(entry); e != "" && strings.EqualFold(e, host) {
			return true
		}
	}
	return false
}

// isBlockedIP reports whether ip is in a range we must never POST to from the
// control plane: loopback, link-local (incl. 169.254.0.0/16 — the cloud
// metadata range), private RFC1918/ULA, unspecified, and the
// carrier-grade-NAT / benchmarking / documentation ranges that should never be
// a legitimate public push endpoint.
func isBlockedIP(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsPrivate() || ip.IsUnspecified() || ip.IsMulticast() {
		return true
	}
	// Additional reserved IPv4 ranges net.IP helpers do not cover.
	for _, cidr := range extraBlockedV4 {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}

// extraBlockedV4 are reserved IPv4 ranges not flagged by the net.IP predicates
// (CGNAT 100.64.0.0/10, benchmarking 198.18.0.0/15, the three TEST-NET
// documentation ranges, and the broadcast address) — none is a valid public
// push endpoint.
var extraBlockedV4 = mustCIDRs(
	"100.64.0.0/10",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"255.255.255.255/32",
)

func mustCIDRs(cidrs ...string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			panic("push: bad CIDR constant " + c)
		}
		out = append(out, n)
	}
	return out
}
