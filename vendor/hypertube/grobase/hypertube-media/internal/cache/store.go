package cache

import (
	"encoding/json"
	"os"
	"strings"
	"time"
)

// PutJob writes job as the movie's job.json, creating the per-movie directory.
func (s *Store) PutJob(job Job) error {
	if err := ensureDir(s.dir(job.MediaID)); err != nil {
		return err
	}
	b, err := json.Marshal(job)
	if err != nil {
		return err
	}
	return os.WriteFile(s.jobPath(job.MediaID), b, 0o644)
}

// GetJob reads the movie's job.json; ok is false when the movie is not cached.
func (s *Store) GetJob(mediaID string) (Job, bool) {
	b, err := os.ReadFile(s.jobPath(mediaID))
	if err != nil {
		return Job{}, false
	}
	var job Job
	if json.Unmarshal(b, &job) != nil {
		return Job{}, false
	}
	return job, true
}

// Complete reports whether mediaID is fully downloaded (status "complete").
func (s *Store) Complete(mediaID string) bool {
	job, ok := s.GetJob(mediaID)
	return ok && job.Status == "complete"
}

// Touch updates the movie's last-watched timestamp to now (drives eviction).
func (s *Store) Touch(mediaID string) error {
	job, ok := s.GetJob(mediaID)
	if !ok {
		return nil
	}
	job.LastWatchedAt = time.Now().UTC()
	return s.PutJob(job)
}

// safeID strips path separators from a media id so it cannot escape the root.
func safeID(id string) string {
	r := strings.NewReplacer("/", "_", "\\", "_", "..", "_")
	return r.Replace(id)
}

// ensureDir creates dir (and parents) if it does not already exist.
func ensureDir(dir string) error { return os.MkdirAll(dir, 0o755) }
