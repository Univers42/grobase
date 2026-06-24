// Package store is the one seam to Grobase: it speaks the data plane's
// POST /query/v1/{dbId}/tables/{table} CRUD protocol and the GoTrue admin API.
// Every other package depends on the Store interface, never on HTTP details.
package store

import (
	"context"
	"net/http"
	"time"
)

// Row is a generic data-plane record.
type Row = map[string]any

// Query is one CRUD request against a Mongo collection on the mount.
type Query struct {
	Op     string         `json:"op"`
	Data   Row            `json:"data,omitempty"`
	Filter map[string]any `json:"filter,omitempty"`
	Sort   map[string]any `json:"sort,omitempty"`
	Limit  int            `json:"limit,omitempty"`
	Offset int            `json:"offset,omitempty"`
}

// Result mirrors the {rows,rowCount} / {affected_rows} envelope the router returns.
type Result struct {
	Rows         []Row `json:"rows"`
	RowCount     int   `json:"rowCount"`
	AffectedRows int   `json:"affected_rows"`
}

// Store is the data + identity surface the handlers consume.
type Store interface {
	Query(ctx context.Context, table string, q Query) (Result, error)
	AdminEmail(ctx context.Context, userID string) (string, error)
}

// Config carries the endpoints and credentials the Store binds to (env-injected).
type Config struct {
	DataplaneURL string
	MongoDBID    string
	AppAPIKey    string
	AnonAPIKey   string
	GoTrueURL    string
	GoTrueSvcKey string
}

// client is the concrete Store: a pooled http.Client plus the bound Config.
type client struct {
	cfg  Config
	http *http.Client
}

// New returns a Store bound to cfg with a request-timeout http.Client.
func New(cfg Config) Store {
	return &client{cfg: cfg, http: &http.Client{Timeout: 8 * time.Second}}
}
