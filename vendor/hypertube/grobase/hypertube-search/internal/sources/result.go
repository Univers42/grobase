package sources

// Result is the normalized torrent shape every source maps to. movieId is the
// stable per-source identifier the rest of Hypertube keys media jobs on; quality
// is a coarse label ("HD"/"SD"/"") parsed from the source when available.
type Result struct {
	MovieID   string `json:"movieId"`
	Title     string `json:"title"`
	Year      int    `json:"year"`
	CoverURL  string `json:"coverUrl,omitempty"`
	Magnet    string `json:"magnet,omitempty"`
	Seeders   int    `json:"seeders"`
	Peers     int    `json:"peers"`
	Downloads int    `json:"downloads"`
	Quality   string `json:"quality,omitempty"`
}

// Popularity scores a result for the default (non-search) ranking:
// downloads + peers + seeders, highest first.
func (r Result) Popularity() int { return r.Downloads + r.Peers + r.Seeders }
