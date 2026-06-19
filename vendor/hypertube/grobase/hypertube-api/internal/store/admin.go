package store

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// AdminEmail fetches a user's email from GoTrue's admin API with the service key.
// It is only ever called after the caller has proven token sub == userID, so the
// email-privacy invariant is enforced by the handler, not here. An empty GoTrue
// URL yields "" (degraded, never a crash).
func (c *client) AdminEmail(ctx context.Context, userID string) (string, error) {
	if c.cfg.GoTrueURL == "" {
		return "", nil
	}
	url := fmt.Sprintf("%s/admin/users/%s", c.cfg.GoTrueURL, userID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+c.cfg.GoTrueSvcKey)
	req.Header.Set("apikey", c.cfg.GoTrueSvcKey)
	return c.doAdminEmail(req)
}

// doAdminEmail sends req and projects the GoTrue user's email field, swallowing
// the rest of the admin payload so nothing internal leaks upward.
func (c *client) doAdminEmail(req *http.Request) (string, error) {
	res, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", statusError(res.StatusCode)
	}
	var out struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return "", err
	}
	return out.Email, nil
}
