package store

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// Query issues one CRUD op against table on the Mongo mount via the data plane.
// Headers: apikey (Kong anon, clears key-auth) + X-Baas-Api-Key (resolves the
// tenant). The plane stamps owner_id/tenant_id itself.
func (c *client) Query(ctx context.Context, table string, q Query) (Result, error) {
	url := fmt.Sprintf("%s/query/v1/%s/tables/%s", c.cfg.DataplaneURL, c.cfg.MongoDBID, table)
	body, err := json.Marshal(q)
	if err != nil {
		return Result{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Result{}, err
	}
	c.setDataHeaders(req)
	return c.doQuery(req)
}

// setDataHeaders applies the data-plane auth + content-type headers to req.
func (c *client) setDataHeaders(req *http.Request) {
	req.Header.Set("apikey", c.cfg.AnonAPIKey)
	req.Header.Set("X-Baas-Api-Key", c.cfg.AppAPIKey)
	req.Header.Set("Content-Type", "application/json")
}

// doQuery sends req and decodes the {rows,rowCount}/{affected_rows} envelope; a
// non-2xx status becomes a statusError so callers never see the upstream body.
func (c *client) doQuery(req *http.Request) (Result, error) {
	res, err := c.http.Do(req)
	if err != nil {
		return Result{}, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return Result{}, statusError(res.StatusCode)
	}
	var out Result
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return Result{}, err
	}
	return out, nil
}

// statusError is an upstream non-2xx status, modelled as a const-friendly error
// type (no sentinel var — see .claude/rules/no-globals.md).
type statusError int

// Error renders the upstream status code without leaking the response body.
func (e statusError) Error() string { return fmt.Sprintf("upstream status %d", int(e)) }
