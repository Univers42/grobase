package tmdb

// Media is the camelCase movie/series shape the MovieVerse frontend consumes
// (poster/backdrop absolutised). Detail-only fields are omitempty.
type Media struct {
	ID           int        `json:"id"`
	Title        string     `json:"title"`
	MediaType    string     `json:"mediaType"`
	PosterPath   string     `json:"posterPath,omitempty"`
	BackdropPath string     `json:"backdropPath,omitempty"`
	ReleaseDate  string     `json:"releaseDate,omitempty"`
	VoteAverage  float64    `json:"voteAverage"`
	VoteCount    int        `json:"voteCount"`
	Overview     string     `json:"overview,omitempty"`
	Genres       []string   `json:"genres"`
	Runtime      int        `json:"runtime,omitempty"`
	TrailerKey   string     `json:"trailerKey,omitempty"`
	Cast         []Person   `json:"cast,omitempty"`
	Providers    []Provider `json:"providers,omitempty"`
}

// Person is a cast member (profile path absolutised).
type Person struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Character   string `json:"character,omitempty"`
	ProfilePath string `json:"profilePath,omitempty"`
}

// Provider is a watch provider available in the ES region.
type Provider struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	LogoPath string `json:"logoPath,omitempty"`
	Link     string `json:"link,omitempty"`
}

// rawItem is the subset of a TMDB movie/tv object this proxy reads. TV uses
// name/first_air_date; movies use title/release_date — both land in Media.
type rawItem struct {
	ID            int      `json:"id"`
	Title         string   `json:"title"`
	Name          string   `json:"name"`
	PosterPath    string   `json:"poster_path"`
	BackdropPath  string   `json:"backdrop_path"`
	ReleaseDate   string   `json:"release_date"`
	FirstAirDate  string   `json:"first_air_date"`
	VoteAverage   float64  `json:"vote_average"`
	VoteCount     int      `json:"vote_count"`
	Overview      string   `json:"overview"`
	GenreIDs      []int    `json:"genre_ids"`
	Genres        []idName `json:"genres"`
	Runtime       int      `json:"runtime"`
	EpisodeRunMin []int    `json:"episode_run_time"`
}

type idName struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// absURL prepends base to a TMDB relative image path ("" stays "").
func absURL(base, path string) string {
	if path == "" {
		return ""
	}
	return base + path
}

// mapItem projects a rawItem into the frontend Media shape for the given type
// ("MOVIE"/"SERIE"), resolving genre ids through gmap when the item lacks names.
func mapItem(r rawItem, mediaType string, gmap map[int]string) Media {
	isTV := mediaType == "SERIE"
	m := Media{
		ID: r.ID, MediaType: mediaType,
		Title:        pick(isTV, r.Name, r.Title),
		PosterPath:   absURL(posterBase, r.PosterPath),
		BackdropPath: absURL(backdropBase, r.BackdropPath),
		ReleaseDate:  pick(isTV, r.FirstAirDate, r.ReleaseDate),
		VoteAverage:  r.VoteAverage, VoteCount: r.VoteCount, Overview: r.Overview,
		Genres: genreNames(r, gmap),
	}
	if isTV && len(r.EpisodeRunMin) > 0 {
		m.Runtime = r.EpisodeRunMin[0]
	} else {
		m.Runtime = r.Runtime
	}
	return m
}

// pick returns a when cond else b.
func pick(cond bool, a, b string) string {
	if cond {
		return a
	}
	return b
}

// genreNames resolves the item's genres: explicit names (detail) take priority,
// else the genre ids are looked up in gmap.
func genreNames(r rawItem, gmap map[int]string) []string {
	out := make([]string, 0, len(r.Genres)+len(r.GenreIDs))
	if len(r.Genres) > 0 {
		for _, g := range r.Genres {
			out = append(out, g.Name)
		}
		return out
	}
	for _, id := range r.GenreIDs {
		if n := gmap[id]; n != "" {
			out = append(out, n)
		}
	}
	return out
}
