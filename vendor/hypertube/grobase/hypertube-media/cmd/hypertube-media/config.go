package main

import (
	"log"
	"os"

	"hypertube/media/internal/dataplane"
)

// config is the fully-resolved runtime configuration read from the environment.
type config struct {
	addr      string
	cacheRoot string
	enabled   bool
	eviction  bool
	dp        dataplane.Config
	subsKey   string
}

// load reads every env var the service needs, applying defaults and warning
// (never crashing) on empty optional secrets — the tmdb-proxy discipline.
func load() config {
	cfg := config{
		addr:      envOr("MEDIA_ADDR", ":3080"),
		cacheRoot: envOr("MEDIA_CACHE_ROOT", "/cache"),
		enabled:   envBool("HYPERTUBE_MEDIA_ENABLED"),
		eviction:  envBool("HYPERTUBE_CACHE_EVICTION"),
		dp: dataplane.Config{
			BaseURL: envOr("MEDIA_DATAPLANE_URL", "http://kong:8000"),
			DBID:    os.Getenv("MEDIA_DB_ID"),
			AppKey:  os.Getenv("MEDIA_APP_API_KEY"),
			AnonKey: os.Getenv("MEDIA_ANON_APIKEY"),
		},
		subsKey: os.Getenv("OPENSUBTITLES_API_KEY"),
	}
	warnEmpty(cfg)
	return cfg
}

// warnEmpty logs a degradation notice for each empty optional credential so an
// operator sees why a capability is dark, without the service refusing to boot.
func warnEmpty(cfg config) {
	if cfg.dp.AppKey == "" {
		log.Print("hypertube-media: MEDIA_APP_API_KEY empty — catalog resolve disabled (cached media still streams)")
	}
	if cfg.subsKey == "" {
		log.Print("hypertube-media: OPENSUBTITLES_API_KEY empty — subtitles degrade to empty tracks")
	}
	if !cfg.enabled {
		log.Print("hypertube-media: HYPERTUBE_MEDIA_ENABLED off — only /media/v1/health answers; others 503")
	}
}

// envOr returns the env var named key, or def when it is unset/empty.
func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// envBool reports whether key is set to a truthy value (1/true/yes/on).
func envBool(key string) bool {
	switch os.Getenv(key) {
	case "1", "true", "TRUE", "yes", "on":
		return true
	default:
		return false
	}
}
