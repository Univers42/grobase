package main

import (
	"context"
	"time"

	"hypertube/media/internal/cache"
	"hypertube/media/internal/dataplane"
	"hypertube/media/internal/eviction"
	"hypertube/media/internal/mediahttp"
	"hypertube/media/internal/subtitles"
	"hypertube/media/internal/torrent"
)

// buildDeps constructs the data-plane client and subtitle fetcher and assembles
// the HTTP layer's injected dependency set from the live cache and engine.
func buildDeps(cfg config, store *cache.Store, engine *torrent.Engine) mediahttp.Deps {
	dp := dataplane.New(cfg.dp)
	return mediahttp.Deps{
		Enabled:   cfg.enabled,
		Resolver:  resolver{dp},
		Engine:    engine,
		Jobs:      jobs{dp: dp, store: store},
		Subtitles: subtitles.New(cfg.subsKey),
	}
}

// resolver adapts the data-plane client to mediahttp.Resolver, flattening the
// MovieRef into a (ref, title) pair.
type resolver struct{ dp *dataplane.Client }

// Resolve returns the movie's torrent reference and title from the catalog.
func (r resolver) Resolve(ctx context.Context, mediaID string) (string, string, error) {
	ref, err := r.dp.Resolve(ctx, mediaID)
	if err != nil {
		return "", "", err
	}
	return ref.Ref(), ref.Title, nil
}

// jobs adapts the data-plane client + cache store to mediahttp.JobStore,
// persisting a download job both to media_jobs and to the on-disk cache.
type jobs struct {
	dp    *dataplane.Client
	store *cache.Store
}

// Save records the job's progress in media_jobs and the local cache job.json.
func (j jobs) Save(ctx context.Context, mediaID, title string, p torrent.Progress) error {
	_ = j.store.PutJob(cache.Job{
		MediaID:       mediaID,
		Status:        statusOf(p),
		BytesDone:     p.BytesDone,
		BytesTotal:    p.BytesTotal,
		LastWatchedAt: time.Now().UTC(),
	})
	return j.dp.UpsertJob(ctx, map[string]any{
		"id": mediaID, "owner_pk": "media:" + mediaID,
		"state": statusOf(p), "pct": pct(p), "last_seen_at": time.Now().UTC().Format(time.RFC3339),
	})
}

// Touch bumps the cached movie's last-watched time (drives eviction).
func (j jobs) Touch(mediaID string) error { return j.store.Touch(mediaID) }

// evictStore adapts the cache store to the eviction sweeper's port, projecting
// each job into an eviction.Entry.
type evictStore struct{ store *cache.Store }

// Entries lists cached movies as eviction entries (media id + last-watched).
func (e evictStore) Entries() []eviction.Entry {
	src := e.store.Entries()
	out := make([]eviction.Entry, 0, len(src))
	for _, j := range src {
		out = append(out, eviction.Entry{MediaID: j.MediaID, LastWatchedAt: j.LastWatchedAt})
	}
	return out
}

// Remove deletes a cached movie by id.
func (e evictStore) Remove(mediaID string) error { return e.store.Remove(mediaID) }
