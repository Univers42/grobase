// Package push implements the tenant-scoped PUSH / MESSAGING registry (Track-E,
// Firebase FCM-parity). A tenant registers delivery SUBSCRIPTIONS (channel
// 'webhook' or 'fcm' — both are an outbound HTTP POST to a configured target_url,
// so 'fcm' is a pluggable FCM-compatible endpoint, no real FCM SDK required) and
// SENDS a notification that fans out to every matching subscription.
//
// It mirrors internal/webhooks' outbound-HTTP delivery discipline (per-request
// timeout, an SSRF guard that refuses to POST to private/loopback/link-local
// addresses) so a tenant can never coerce the control plane into hitting an
// internal service (the cloud metadata endpoint, the Postgres container, etc.).
//
// CONTROL-PLANE ONLY: push never enters RequestIdentity, the RLS GUCs, or the
// data plane; tenant_id is bound in every query (the wall). Flag-gated OFF by
// PUSH_ENABLED (default): when off the routes are never mounted and the table
// stays empty = byte-parity.
package push

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// Channel kinds. Both deliver over HTTP POST; 'fcm' is just a configured
// FCM-compatible endpoint (no real FCM SDK).
const (
	channelWebhook = "webhook"
	channelFCM     = "fcm"
)

// Sentinel errors mapped to HTTP status codes by the handler.
var (
	// ErrNotFound — a subscription does not exist under the caller's tenant scope.
	ErrNotFound = errors.New("push subscription not found")
	// ErrValidation — a malformed register/send request (mapped to 400).
	ErrValidation = errors.New("push validation error")
	// ErrBlockedTarget — the target_url resolves to a private/loopback/link-local
	// address (SSRF guard). Mapped to 400; NO delivery is attempted.
	ErrBlockedTarget = errors.New("push target_url is not a permitted public endpoint (SSRF guard)")
)

// Subscription is the public metadata view of a registered delivery target. The
// sealed provider token is NEVER included — it is a write-only secret.
type Subscription struct {
	ID        string `json:"id"`
	TenantID  string `json:"tenant_id"`
	UserID    string `json:"user_id,omitempty"`
	Channel   string `json:"channel"`
	TargetURL string `json:"target_url"`
	Label     string `json:"label"`
	HasToken  bool   `json:"has_token"`
	CreatedAt string `json:"created_at"`
	RevokedAt string `json:"revoked_at,omitempty"`
}

// RegisterRequest is the JSON body for POST .../push/subscriptions.
type RegisterRequest struct {
	UserID    string `json:"user_id"`
	Channel   string `json:"channel"`
	TargetURL string `json:"target_url"`
	Token     string `json:"token"` // optional provider token (sealed at rest); only for 'fcm'
	Label     string `json:"label"`
}

// Validate enforces the structural contract (channel in {webhook,fcm}, a
// well-formed http(s) target_url). The SSRF reachability check is a SEPARATE,
// load-bearing wall applied at register + send time (see guardTarget) — Validate
// only checks SHAPE, guardTarget checks the resolved DESTINATION.
func (r RegisterRequest) Validate() error {
	switch r.Channel {
	case channelWebhook, channelFCM:
	default:
		return fmt.Errorf("%w: channel must be 'webhook' or 'fcm'", ErrValidation)
	}
	if strings.TrimSpace(r.TargetURL) == "" {
		return fmt.Errorf("%w: target_url is required", ErrValidation)
	}
	u, err := url.Parse(r.TargetURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return fmt.Errorf("%w: target_url must be an absolute http(s) URL", ErrValidation)
	}
	if l := len(r.Label); l > 128 {
		return fmt.Errorf("%w: label must be <=128 chars", ErrValidation)
	}
	if r.Channel == channelWebhook && r.Token != "" {
		return fmt.Errorf("%w: a webhook subscription must not carry a provider token", ErrValidation)
	}
	return nil
}

// SendRequest is the JSON body for POST .../push/send. A notification with a
// title + body is delivered to every live matching subscription. user_id (when
// set) narrows the fan-out to that subscriber's subscriptions.
type SendRequest struct {
	Title  string `json:"title"`
	Body   string `json:"body"`
	UserID string `json:"user_id"` // optional: narrow the send to one subscriber
	// Data is an optional free-form key/value bag forwarded in the payload
	// (FCM-shaped data messages).
	Data map[string]string `json:"data"`
}

// Validate enforces a non-empty title/body.
func (r SendRequest) Validate() error {
	if strings.TrimSpace(r.Title) == "" {
		return fmt.Errorf("%w: title is required", ErrValidation)
	}
	if strings.TrimSpace(r.Body) == "" {
		return fmt.Errorf("%w: body is required", ErrValidation)
	}
	return nil
}

// SendResult reports the fan-out outcome of a send.
type SendResult struct {
	Notification string           `json:"notification"` // a generated id for the notification
	Matched      int              `json:"matched"`      // subscriptions that matched the send
	Delivered    int              `json:"delivered"`    // 2xx deliveries
	Failed       int              `json:"failed"`       // non-2xx / transport failures
	Deliveries   []DeliveryResult `json:"deliveries"`
}

// DeliveryResult is the per-subscription outcome of one send.
type DeliveryResult struct {
	SubscriptionID string `json:"subscription_id"`
	Channel        string `json:"channel"`
	StatusCode     int    `json:"status_code,omitempty"`
	OK             bool   `json:"ok"`
	Error          string `json:"error,omitempty"`
}
