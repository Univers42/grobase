// Package cache is the on-disk movie store: one directory per movie holding the
// media file plus a job.json (status/bytes/last-watched). Presence on disk is
// the source of truth for whether a movie is downloaded.
package cache

import (
	"path/filepath"
	"time"
)

// Store roots all cached movies under one directory (MEDIA_CACHE_ROOT). It is
// constructed once and injected; it holds no mutable global state.
type Store struct{ root string }

// New returns a Store rooted at dir, creating the root if absent.
func New(dir string) (*Store, error) {
	if err := ensureDir(dir); err != nil {
		return nil, err
	}
	return &Store{root: dir}, nil
}

// Root returns the cache root directory.
func (s *Store) Root() string { return s.root }

// Job is the persisted state of one movie's download: its status, byte counters,
// the on-disk media path, and when it was last streamed (drives eviction).
type Job struct {
	MediaID       string    `json:"media_id"`
	Status        string    `json:"status"`
	BytesDone     int64     `json:"bytes_done"`
	BytesTotal    int64     `json:"bytes_total"`
	FilePath      string    `json:"file_path"`
	LastWatchedAt time.Time `json:"last_watched_at"`
}

// dir is the per-movie directory for mediaID.
func (s *Store) dir(mediaID string) string {
	return filepath.Join(s.root, safeID(mediaID))
}

// jobPath is the job.json path for mediaID.
func (s *Store) jobPath(mediaID string) string {
	return filepath.Join(s.dir(mediaID), "job.json")
}
