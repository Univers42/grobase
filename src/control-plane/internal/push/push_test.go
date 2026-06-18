package push

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestGuardTarget_RejectsInternal is the LOAD-BEARING SSRF unit: the guard must
// refuse loopback, link-local (incl. the 169.254.169.254 cloud-metadata
// address), RFC1918 private, and unspecified targets — these are exactly the
// addresses a tenant could weaponize for server-side request forgery.
func TestGuardTarget_RejectsInternal(t *testing.T) {
	blocked := []string{
		"http://127.0.0.1/",
		"http://127.0.0.1:5432/",
		"http://localhost/",              // resolves to loopback
		"http://169.254.169.254/latest/", // cloud metadata (link-local)
		"http://10.0.0.5/",               // RFC1918
		"http://172.16.5.5/",             // RFC1918
		"http://192.168.1.1/",            // RFC1918
		"http://[::1]/",                  // IPv6 loopback
		"http://0.0.0.0/",                // unspecified
		"http://100.64.0.1/",             // CGNAT
		"ftp://example.com/",             // bad scheme
		"http:///nohost",                 // empty host
	}
	for _, raw := range blocked {
		if err := guardTarget(raw); err == nil {
			t.Errorf("guardTarget(%q) = nil, want ErrBlockedTarget — SSRF wall leaked", raw)
		}
	}
}

// TestGuardTarget_AllowsPublic confirms a clearly-public address passes (so the
// guard is not a blanket-deny no-op that would make the gate's POSITIVE arm
// vacuous). 8.8.8.8 is a stable public literal.
func TestGuardTarget_AllowsPublic(t *testing.T) {
	if err := guardTarget("http://8.8.8.8/hook"); err != nil {
		t.Errorf("guardTarget(public literal) = %v, want nil", err)
	}
	if err := guardTarget("https://203.0.113.0/"); err == nil {
		t.Error("guardTarget(TEST-NET doc range) = nil, want blocked")
	}
}

// TestRegisterValidate enforces the request contract (channel + http(s) URL +
// webhook-carries-no-token).
func TestRegisterValidate(t *testing.T) {
	bad := []RegisterRequest{
		{Channel: "sms", TargetURL: "https://x.test/"},                      // bad channel
		{Channel: channelWebhook, TargetURL: ""},                            // missing url
		{Channel: channelWebhook, TargetURL: "notaurl"},                     // not http(s)
		{Channel: channelWebhook, TargetURL: "https://x.test/", Token: "k"}, // webhook + token
	}
	for i, r := range bad {
		if err := r.Validate(); err == nil {
			t.Errorf("Validate()[%d] = nil, want error for %+v", i, r)
		}
	}
	good := RegisterRequest{Channel: channelFCM, TargetURL: "https://fcm.example.com/send", Token: "server-key"}
	if err := good.Validate(); err != nil {
		t.Errorf("Validate(good fcm) = %v, want nil", err)
	}
}

// TestSendValidate enforces a non-empty title + body.
func TestSendValidate(t *testing.T) {
	for _, r := range []SendRequest{{}, {Title: "hi"}, {Body: "yo"}} {
		if err := r.Validate(); err == nil {
			t.Errorf("Validate(%+v) = nil, want error", r)
		}
	}
	if err := (SendRequest{Title: "t", Body: "b"}).Validate(); err != nil {
		t.Errorf("Validate(good) = %v, want nil", err)
	}
}

// TestNotificationPayloadShape pins the wire shape: an FCM-shaped notification
// object (title/body) + the tenant/notification ids the receiver needs. The
// gate greps these fields in the sink-received body.
func TestNotificationPayloadShape(t *testing.T) {
	body, err := marshalNotification("acme", "notif-1", SendRequest{
		Title: "Build done", Body: "deploy ok", Data: map[string]string{"k": "v"},
	})
	if err != nil {
		t.Fatalf("marshalNotification: %v", err)
	}
	var got notification
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Notification.Title != "Build done" || got.Notification.Body != "deploy ok" {
		t.Errorf("notification title/body wrong: %+v", got.Notification)
	}
	if got.TenantID != "acme" || got.NotificationID != "notif-1" {
		t.Errorf("tenant/notification id wrong: %q / %q", got.TenantID, got.NotificationID)
	}
	if got.Data["k"] != "v" {
		t.Errorf("data bag not forwarded: %+v", got.Data)
	}
	if !strings.Contains(string(body), `"notification"`) {
		t.Error("payload missing top-level notification object")
	}
}

// TestSealerRoundTrip confirms a sealed token opens back to the same plaintext,
// a tampered blob fails (GCM auth tag), and a non-empty token without a key is
// rejected (never stored clear).
func TestSealerRoundTrip(t *testing.T) {
	s := newSealer("a-sufficiently-long-operator-key")
	blob, err := s.seal("fcm-server-key")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if len(blob) == 0 {
		t.Fatal("seal produced empty blob for non-empty token")
	}
	if string(blob) == "fcm-server-key" {
		t.Fatal("token stored in clear — must be sealed")
	}
	open, err := s.open(blob)
	if err != nil || open != "fcm-server-key" {
		t.Fatalf("open = %q,%v, want fcm-server-key,nil", open, err)
	}
	tampered := append([]byte(nil), blob...)
	tampered[len(tampered)-1] ^= 0xFF
	if _, err := s.open(tampered); err == nil {
		t.Error("open(tampered) = nil error, want GCM auth failure")
	}
	// Empty token seals to nil regardless of key (webhook path).
	if b, err := s.seal(""); err != nil || b != nil {
		t.Errorf("seal(empty) = %v,%v, want nil,nil", b, err)
	}
	// A nil sealer (no key) cannot store a provider token.
	var nilSealer *tokenSealer
	if _, err := nilSealer.seal("k"); err == nil {
		t.Error("nil sealer seal(non-empty) = nil error, want errNoKey")
	}
	if b, err := nilSealer.seal(""); err != nil || b != nil {
		t.Errorf("nil sealer seal(empty) = %v,%v, want nil,nil (webhook path)", b, err)
	}
}
