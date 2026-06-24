package main

import "hypertube/media/internal/torrent"

// statusOf maps download progress to a job state: "ready" once metadata is known
// and bytes are flowing, "complete" when fully downloaded, else "pending".
func statusOf(p torrent.Progress) string {
	switch {
	case p.BytesTotal > 0 && p.BytesDone >= p.BytesTotal:
		return "complete"
	case p.Ready:
		return "ready"
	default:
		return "pending"
	}
}

// pct returns the integer download percentage (0 when total is unknown).
func pct(p torrent.Progress) int {
	if p.BytesTotal <= 0 {
		return 0
	}
	return int(p.BytesDone * 100 / p.BytesTotal)
}
