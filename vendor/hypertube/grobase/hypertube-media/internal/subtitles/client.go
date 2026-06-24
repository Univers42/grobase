package subtitles

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
)

// userAgent identifies this client to OpenSubtitles (required by their API).
const userAgent = "hypertube-media/1.0"

// getJSON issues an authenticated GET against the OpenSubtitles API and decodes
// the JSON body into out.
func (f *Fetcher) getJSON(ctx context.Context, path string, out any) error {
	req, err := f.newRequest(ctx, http.MethodGet, apiBase+path, "")
	if err != nil {
		return err
	}
	return f.do(req, out)
}

// postJSON issues an authenticated POST with a JSON body and decodes the reply.
func (f *Fetcher) postJSON(ctx context.Context, path, body string, out any) error {
	req, err := f.newRequest(ctx, http.MethodPost, apiBase+path, body)
	if err != nil {
		return err
	}
	return f.do(req, out)
}

// getText fetches a raw (un-credentialed) URL and returns its body as a string,
// bounded to 4 MiB so a hostile link cannot exhaust memory.
func (f *Fetcher) getText(ctx context.Context, rawURL string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	res, err := f.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	b, err := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	return string(b), err
}

// newRequest builds an OpenSubtitles request carrying the Api-Key, User-Agent
// and JSON content-type headers; body is empty for GETs.
func (f *Fetcher) newRequest(ctx context.Context, method, url, body string) (*http.Request, error) {
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Api-Key", f.key)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Content-Type", "application/json")
	return req, nil
}

// do executes req and decodes a 2xx JSON body into out; a non-2xx is dropped
// silently (the caller degrades to an empty track).
func (f *Fetcher) do(req *http.Request, out any) error {
	res, err := f.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil
	}
	return json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(out)
}
