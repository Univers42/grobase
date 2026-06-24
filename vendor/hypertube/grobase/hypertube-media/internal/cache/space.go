package cache

import (
	"os"
	"syscall"
)

// minFreeBytes is the disk headroom required before a new movie download starts.
const minFreeBytes uint64 = 1 << 30

// HasFreeSpace reports whether the cache filesystem has at least minFreeBytes
// free, so a Put never fills the disk.
func (s *Store) HasFreeSpace() bool {
	var st syscall.Statfs_t
	if syscall.Statfs(s.root, &st) != nil {
		return true
	}
	return st.Bavail*uint64(st.Bsize) >= minFreeBytes
}

// Entries lists every cached movie's job, skipping directories without a
// readable job.json. It is the input the eviction sweep walks.
func (s *Store) Entries() []Job {
	ents, err := os.ReadDir(s.root)
	if err != nil {
		return nil
	}
	jobs := make([]Job, 0, len(ents))
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		if job, ok := s.GetJob(e.Name()); ok {
			jobs = append(jobs, job)
		}
	}
	return jobs
}

// Remove deletes a cached movie's entire directory (media file + job.json).
func (s *Store) Remove(mediaID string) error {
	return os.RemoveAll(s.dir(mediaID))
}
