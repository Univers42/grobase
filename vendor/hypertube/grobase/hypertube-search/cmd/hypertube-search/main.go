package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"hypertube/search/internal/metadata"
	"hypertube/search/internal/searchhttp"
	"hypertube/search/internal/sources"
)

// main wires the TMDb key + listen address from the environment into the search
// service and serves it. The TMDb key is optional: an empty key disables
// enrichment (results still render), so the service degrades instead of crashing
// — injected by Grobase (env/Vault), never a global.
func main() {
	key := os.Getenv("TMDB_API_KEY")
	if key == "" {
		// ponytail: warn instead of exit on empty key — search still serves torrent results, metadata degrades to []; set TMDB_API_KEY to enrich
		log.Print("hypertube-search: TMDB_API_KEY empty — metadata enrichment disabled until it is set")
	}
	svc := searchhttp.NewService(sources.NewAggregator(), metadata.New(key))
	addr := envOr("SEARCH_ADDR", ":3081")
	srv := &http.Server{
		Addr:              addr,
		Handler:           searchhttp.NewMux(svc),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("hypertube-search listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

// envOr returns the env var named key, or def when it is unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
