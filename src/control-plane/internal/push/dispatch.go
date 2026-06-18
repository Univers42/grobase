package push

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
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
	req, err := newDeliverRequest(reqCtx, target, bearer, body)
	if err != nil {
		return 0, err
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

// newDeliverRequest builds the outbound POST with the push headers and the
// optional Bearer authorization (the FCM-compatible auth path).
func newDeliverRequest(ctx context.Context, target, bearer string, body []byte) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "mini-baas-push/1.0")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	return req, nil
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

// The SSRF wall (guardTarget, hostAllowlisted, isBlockedIP, mustCIDRs and the
// extraBlockedV4 reserved-range table) lives in ssrf.go.
