package dataplane

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// request is a Grobase /query/v1 operation envelope.
type request struct {
	Op     string         `json:"op"`
	Data   map[string]any `json:"data,omitempty"`
	Filter map[string]any `json:"filter,omitempty"`
	Limit  int            `json:"limit,omitempty"`
}

// catalogRow is the subset of a Mongo `movies` document the resolver needs: the
// natural id, the title, and the torrent locators (the magnet lives nested in
// the `torrents` array, not at the top level).
type catalogRow struct {
	MovieID  string `json:"movie_id"`
	Title    string `json:"title"`
	Torrents []struct {
		Magnet string `json:"magnet"`
	} `json:"torrents"`
}

// Resolve looks up mediaID in the movies catalog (keyed by `movie_id`) and
// returns its torrent reference, flattening the first torrent's magnet. A
// disabled client or a missing row yields a not-found error.
func (c *Client) Resolve(ctx context.Context, mediaID string) (MovieRef, error) {
	if !c.Enabled() {
		return MovieRef{}, fmt.Errorf("dataplane: disabled (no MEDIA_APP_API_KEY)")
	}
	body := request{Op: "get", Filter: map[string]any{"movie_id": map[string]any{"$eq": mediaID}}, Limit: 1}
	var out struct {
		Rows []catalogRow `json:"rows"`
	}
	if err := c.call(ctx, "movies", body, &out); err != nil {
		return MovieRef{}, err
	}
	if len(out.Rows) == 0 {
		return MovieRef{}, fmt.Errorf("dataplane: movie %q not found", mediaID)
	}
	r := out.Rows[0]
	ref := MovieRef{MediaID: r.MovieID, Title: r.Title}
	if len(r.Torrents) > 0 {
		ref.Magnet = r.Torrents[0].Magnet
	}
	return ref, nil
}

// UpsertJob records a download job's state in the media_jobs table; the data
// plane stamps owner/tenant itself. A disabled client is a silent no-op.
func (c *Client) UpsertJob(ctx context.Context, job map[string]any) error {
	if !c.Enabled() {
		return nil
	}
	return c.call(ctx, "media_jobs", request{Op: "upsert", Data: job}, nil)
}

// call POSTs a request envelope to {base}/query/v1/{dbID}/tables/{table} with the
// apikey + X-Baas-Api-Key headers, decoding a 2xx JSON body into out when non-nil.
func (c *Client) call(ctx context.Context, table string, body request, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := c.newRequest(ctx, table, buf)
	if err != nil {
		return err
	}
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	return decode(res, out)
}

// newRequest builds the authenticated POST to the table's query endpoint.
func (c *Client) newRequest(ctx context.Context, table string, body []byte) (*http.Request, error) {
	url := fmt.Sprintf("%s/query/v1/%s/tables/%s", c.base, c.dbID, table)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("apikey", c.anonKey)
	req.Header.Set("X-Baas-Api-Key", c.appKey)
	return req, nil
}

// decode reads a 2xx JSON body into out (nil out discards it); a non-2xx becomes
// an error carrying the upstream status.
func decode(res *http.Response, out any) error {
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("dataplane: status %d", res.StatusCode)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(out)
}
