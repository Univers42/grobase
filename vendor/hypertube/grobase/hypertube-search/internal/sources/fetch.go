package sources

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

// httpClient is the per-source HTTP dependency (injected, never a global —
// see .claude/rules/no-globals.md). It bounds every outbound call so one slow
// torrent index can never wedge a search request.
type httpClient struct{ c *http.Client }

// newHTTPClient returns a client with an 8s timeout (matches the TMDb proxy).
func newHTTPClient() httpClient {
	return httpClient{c: &http.Client{Timeout: 8 * time.Second}}
}

// getJSON issues GET url and decodes the JSON body into out.
func (h httpClient) getJSON(ctx context.Context, url string, out any) error {
	body, err := h.getBytes(ctx, url)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}

// getBytes issues GET url and returns the raw body; a non-200 is a statusError.
func (h httpClient) getBytes(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "hypertube-search/1.0")
	res, err := h.c.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, statusError(res.StatusCode)
	}
	return io.ReadAll(io.LimitReader(res.Body, 8<<20))
}
