// Package eviction sweeps the movie cache on a ticker, deleting entries unwatched
// for at least the retention window. When disabled the ticker never starts.
package eviction

import (
	"context"
	"log"
	"time"
)

// retention is the unwatched age past which a cached movie is evicted.
const retention = 30 * 24 * time.Hour

// sweepInterval is how often the cache is scanned for stale entries.
const sweepInterval = 6 * time.Hour

// Sweeper deletes cache entries unwatched past the retention window. enabled
// gates the ticker so the OFF state is a no-op.
type Sweeper struct {
	store   store
	enabled bool
}

// store is the dependency the Sweeper drives, listing and removing entries.
type store interface {
	Entries() []Entry
	Remove(mediaID string) error
}

// Entry is the eviction view of a cached movie.
type Entry struct {
	MediaID       string
	LastWatchedAt time.Time
}

// New returns a Sweeper over s; enabled comes from HYPERTUBE_CACHE_EVICTION.
func New(s store, enabled bool) *Sweeper { return &Sweeper{store: s, enabled: enabled} }

// Start launches the eviction loop in a goroutine when enabled; otherwise it
// returns immediately and no ticker is ever created.
func (e *Sweeper) Start(ctx context.Context) {
	if !e.enabled {
		log.Print("hypertube-media: cache eviction disabled (HYPERTUBE_CACHE_EVICTION off)")
		return
	}
	go e.loop(ctx)
}

// loop ticks every sweepInterval, sweeping until ctx is cancelled.
func (e *Sweeper) loop(ctx context.Context) {
	t := time.NewTicker(sweepInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			e.sweep(time.Now().UTC())
		}
	}
}

// sweep removes every entry whose last-watched age exceeds the retention window.
func (e *Sweeper) sweep(now time.Time) {
	for _, ent := range e.store.Entries() {
		if now.Sub(ent.LastWatchedAt) < retention {
			continue
		}
		if err := e.store.Remove(ent.MediaID); err != nil {
			log.Printf("hypertube-media: evict %s: %v", ent.MediaID, err)
		}
	}
}
