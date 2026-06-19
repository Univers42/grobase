package metadata

// Info is the TMDb enrichment overlaid on a torrent search result. Empty fields
// mean TMDb had no match (or the key was unset) — the result still renders.
type Info struct {
	Rating  float64  `json:"rating"`
	Genres  []string `json:"genres"`
	Summary string   `json:"summary,omitempty"`
	Cast    []Member `json:"cast,omitempty"`
	Cover   string   `json:"cover,omitempty"`
}

// Member is one cast entry (role = character name, name = actor).
type Member struct {
	Role string `json:"role"`
	Name string `json:"name"`
}
