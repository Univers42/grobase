package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"movieverse/tmdbproxy/internal/tmdb"
)

// main wires the TMDB key + listen address from the environment into a tmdb
// proxy and serves it. TMDB_API_KEY is required so the secret never reaches the
// browser; it is injected by Grobase (env/Vault), never a global.
func main() {
	key := os.Getenv("TMDB_API_KEY")
	if key == "" {
		// ponytail: warn instead of exit on empty key — proxy still serves (catalog degrades to []); set TMDB_API_KEY to light it up
		log.Print("tmdb-proxy: TMDB_API_KEY empty — catalog disabled until it is set")
	}
	addr := envOr("TMDB_PROXY_ADDR", ":3070")
	srv := &http.Server{
		Addr:              addr,
		Handler:           tmdb.NewMux(tmdb.New(key)),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("tmdb-proxy listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

// envOr returns the env var named key, or def when it is unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
