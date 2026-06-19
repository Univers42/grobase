// Package dataplane is the Grobase /query/v1 client used with a service identity
// to resolve a movie's torrent reference and persist download jobs.
package dataplane

import (
	"net/http"
	"time"
)

// Client talks to the Grobase data plane through Kong with a service API key. It
// is constructed once at the composition root and injected (no globals).
type Client struct {
	base    string
	dbID    string
	appKey  string
	anonKey string
	http    *http.Client
}

// Config carries the injected data-plane endpoint and the service credentials.
type Config struct {
	BaseURL string
	DBID    string
	AppKey  string
	AnonKey string
}

// New returns a data-plane Client from cfg; an empty AppKey leaves the client
// disabled (Enabled reports false) so the service still serves cached media.
func New(cfg Config) *Client {
	return &Client{
		base:    cfg.BaseURL,
		dbID:    cfg.DBID,
		appKey:  cfg.AppKey,
		anonKey: cfg.AnonKey,
		http:    &http.Client{Timeout: 8 * time.Second},
	}
}

// Enabled reports whether a service API key is configured.
func (c *Client) Enabled() bool { return c.appKey != "" }

// MovieRef is a movie's torrent locator resolved from the catalog: a magnet URI
// or bare infohash plus the title for logging.
type MovieRef struct {
	MediaID  string `json:"media_id"`
	Magnet   string `json:"magnet"`
	InfoHash string `json:"info_hash"`
	Title    string `json:"title"`
}

// Ref returns the torrent reference (magnet preferred, else infohash) for use
// with the torrent engine.
func (m MovieRef) Ref() string {
	if m.Magnet != "" {
		return m.Magnet
	}
	return m.InfoHash
}
