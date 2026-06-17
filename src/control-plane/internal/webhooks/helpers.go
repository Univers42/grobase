package webhooks

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

func sign(secret, body string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(body))
	return hex.EncodeToString(mac.Sum(nil))
}

func stringFromPayload(p map[string]any, key string) string {
	if p == nil {
		return ""
	}
	if v, ok := p[key].(string); ok {
		return v
	}
	return ""
}

func nullInt(n int) any {
	if n == 0 {
		return nil
	}
	return n
}
