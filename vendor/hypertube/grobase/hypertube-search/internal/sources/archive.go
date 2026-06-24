package sources

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

const archiveBase = "https://archive.org"

// archive queries archive.org for BitTorrent-distributed public movies. It is
// stateless apart from the injected HTTP client.
type archive struct{ http httpClient }

// Name identifies this source in logs.
func (archive) Name() string { return "archive.org" }

// archiveDoc is one advancedsearch result row.
type archiveDoc struct {
	Identifier string     `json:"identifier"`
	Title      flexString `json:"title"`
	Year       flexString `json:"year"`
	Downloads  flexInt    `json:"downloads"`
}

// Search runs an advancedsearch page and maps each public-movie identifier to a
// Result, deriving a magnet from the item's BitTorrent file.
func (a archive) Search(ctx context.Context, query string, page int) ([]Result, error) {
	var resp struct {
		Response struct {
			Docs []archiveDoc `json:"docs"`
		} `json:"response"`
	}
	if err := a.http.getJSON(ctx, a.searchURL(query, page), &resp); err != nil {
		return nil, err
	}
	out := make([]Result, 0, len(resp.Response.Docs))
	for _, d := range resp.Response.Docs {
		out = append(out, a.toResult(d))
	}
	return out, nil
}

// searchURL builds the advancedsearch query, scoping public BitTorrent movies
// and adding the user's title terms when present.
func (a archive) searchURL(query string, page int) string {
	q := `mediatype:movies AND format:"Archive BitTorrent"`
	if t := strings.TrimSpace(query); t != "" {
		q += ` AND title:(` + t + `)`
	}
	p := url.Values{}
	p.Set("q", q)
	p.Set("rows", "30")
	p.Set("page", strconv.Itoa(max(page, 1)))
	p.Set("output", "json")
	p.Add("fl[]", "identifier")
	p.Add("fl[]", "title")
	p.Add("fl[]", "year")
	p.Add("fl[]", "downloads")
	p.Set("sort[]", "downloads desc")
	return archiveBase + "/advancedsearch.php?" + p.Encode()
}

// toResult maps a doc to a Result, building the magnet from the item's torrent
// web seed (archive.org serves the .torrent at a deterministic path).
func (a archive) toResult(d archiveDoc) Result {
	year, _ := strconv.Atoi(firstYear(string(d.Year)))
	return Result{
		MovieID:   "archive:" + d.Identifier,
		Title:     string(d.Title),
		Year:      year,
		CoverURL:  fmt.Sprintf("%s/services/img/%s", archiveBase, d.Identifier),
		Magnet:    a.magnet(d.Identifier, string(d.Title)),
		Downloads: int(d.Downloads),
		Quality:   "",
	}
}

// magnet builds a magnet URI with the archive.org .torrent as a web-seed/tracker
// hint. archive.org doesn't expose the BTIH in advancedsearch, so the .torrent
// URL is carried as an exact-source (xs) the client resolves.
func (a archive) magnet(identifier, title string) string {
	torrent := fmt.Sprintf("%s/download/%s/%s_archive.torrent", archiveBase, identifier, identifier)
	p := url.Values{}
	p.Set("dn", title)
	p.Set("xs", torrent)
	return "magnet:?" + p.Encode()
}

// firstYear extracts a 4-digit year from a possibly-noisy archive.org year field.
func firstYear(s string) string {
	for i := 0; i+4 <= len(s); i++ {
		if isDigits(s[i : i+4]) {
			return s[i : i+4]
		}
	}
	return ""
}

// isDigits reports whether s is all ASCII digits.
func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}
