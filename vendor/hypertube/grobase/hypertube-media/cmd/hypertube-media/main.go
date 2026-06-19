// Command hypertube-media is the BitTorrent download+stream service Grobase
// cannot provide: it resolves a movie via the data plane, downloads it, and
// streams it (range or transcoded) while it is still downloading.
package main

import (
	"context"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"hypertube/media/internal/cache"
	"hypertube/media/internal/eviction"
	"hypertube/media/internal/mediahttp"
	"hypertube/media/internal/torrent"
)

// main reads configuration from the environment, constructs every dependency
// once, injects them into the HTTP mux, and serves until interrupted. Optional
// secrets warn (never crash) when empty, like the tmdb-proxy template.
func main() {
	cfg := load()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	store := mustCache(cfg.cacheRoot)
	engine := mustEngine(cfg.cacheRoot)
	defer engine.Close()

	eviction.New(evictStore{store}, cfg.eviction).Start(ctx)
	deps := buildDeps(cfg, store, engine)
	serve(ctx, cfg.addr, mediahttp.NewMux(deps))
}

// serve runs an HTTP server with a read-header timeout and shuts it down when
// ctx is cancelled.
func serve(ctx context.Context, addr string, h http.Handler) {
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		sc, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sc)
	}()
	log.Printf("hypertube-media listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

// mustCache builds the on-disk store or exits — the cache root is mandatory.
func mustCache(root string) *cache.Store {
	s, err := cache.New(root)
	if err != nil {
		log.Fatalf("hypertube-media: cache root %q: %v", root, err)
	}
	return s
}

// mustEngine builds the torrent engine or exits — streaming cannot work without it.
func mustEngine(dataDir string) *torrent.Engine {
	e, err := torrent.New(dataDir)
	if err != nil {
		log.Fatalf("hypertube-media: torrent engine: %v", err)
	}
	return e
}
