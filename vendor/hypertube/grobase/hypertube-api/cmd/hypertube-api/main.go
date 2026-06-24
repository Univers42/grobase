// Command hypertube-api is the subject-mandated RESTful OAuth2 API for Hypertube.
// It is the composition root: it reads every secret/endpoint from the environment,
// wires the oauth issuer + Grobase store into the router, and serves it.
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"hypertube/api/internal/oauth"
	"hypertube/api/internal/store"
)

// main wires env -> dependencies -> router and serves. Optional secrets only warn
// (the service still boots) so a missing key degrades rather than crashes.
func main() {
	warnIfEmpty("API_JWT_SECRET", "tokens cannot be verified until it is set")
	warnIfEmpty("API_OAUTH_CLIENT_SECRET", "no client can obtain a token until it is set")
	iss := oauth.New(
		os.Getenv("API_JWT_SECRET"),
		os.Getenv("API_OAUTH_CLIENT_ID"),
		os.Getenv("API_OAUTH_CLIENT_SECRET"),
	)
	st := store.New(storeConfig())
	addr := envOr("API_ADDR", ":3082")
	srv := &http.Server{Addr: addr, Handler: newRouter(iss, st), ReadHeaderTimeout: 5 * time.Second}
	log.Printf("hypertube-api listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}

// storeConfig reads the data-plane + GoTrue endpoints/credentials from the env.
func storeConfig() store.Config {
	return store.Config{
		DataplaneURL: envOr("API_DATAPLANE_URL", "http://kong:8000"),
		MongoDBID:    os.Getenv("API_MONGO_DB_ID"),
		AppAPIKey:    os.Getenv("API_APP_API_KEY"),
		AnonAPIKey:   os.Getenv("API_ANON_APIKEY"),
		GoTrueURL:    os.Getenv("GOTRUE_URL"),
		GoTrueSvcKey: os.Getenv("GOTRUE_SERVICE_KEY"),
	}
}

// warnIfEmpty logs (does not exit) when an optional-but-important env var is unset.
func warnIfEmpty(key, consequence string) {
	if os.Getenv(key) == "" {
		// ponytail: warn instead of exit on empty secret — boots degraded; set it to light the feature up
		log.Printf("hypertube-api: %s empty — %s", key, consequence)
	}
}

// envOr returns the env var named key, or def when it is unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
