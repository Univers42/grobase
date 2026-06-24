package tmdb

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	apiBase      = "https://api.themoviedb.org/3"
	language     = "es-ES"
	region       = "ES"
	posterBase   = "https://image.tmdb.org/t/p/w500"
	backdropBase = "https://image.tmdb.org/t/p/original"
	profileBase  = "https://image.tmdb.org/t/p/w185"
)

// Client proxies the TMDB v3 REST endpoints with a server-side credential. Go's
// net/http does dual-stack Happy-Eyeballs, so outbound succeeds on an IPv4-only
// bridge net — unlike the Deno functions runtime, which hangs on the AAAA address.
type Client struct {
	key    string
	bearer bool
	http   *http.Client
	genres *genreCache
}

// New returns a Client bound to the given TMDB credential. A v4 Read Access Token
// (a JWT — contains dots) is sent as an Authorization: Bearer header; a v3 api key
// (hex) is sent as the api_key query param. TMDB v3 endpoints accept either.
func New(key string) *Client {
	c := &Client{
		key:    key,
		bearer: strings.Contains(key, "."),
		http:   &http.Client{Timeout: 8 * time.Second},
	}
	c.genres = newGenreCache(c)
	return c
}

// get issues GET apiBase+path with the api key + locale + params, decoding the
// JSON body into out; a non-200 TMDB status becomes a statusError.
func (c *Client) get(ctx context.Context, path string, params url.Values, out any) error {
	if params == nil {
		params = url.Values{}
	}
	params.Set("language", language)
	if !c.bearer {
		params.Set("api_key", c.key)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+path+"?"+params.Encode(), nil)
	if err != nil {
		return err
	}
	if c.bearer {
		req.Header.Set("Authorization", "Bearer "+c.key)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return statusError(res.StatusCode)
	}
	return json.NewDecoder(res.Body).Decode(out)
}

// statusError is a TMDB non-200 status, modelled as a const-friendly error type
// (no sentinel var — see .claude/rules/no-globals.md).
type statusError int

// Error renders the upstream TMDB status code.
func (e statusError) Error() string { return fmt.Sprintf("tmdb upstream status %d", int(e)) }
