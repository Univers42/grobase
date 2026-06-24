package sources

import (
	"context"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

const pdtBase = "http://www.publicdomaintorrents.info"

// publicDomain scrapes publicdomaintorrents.info, a curated index of
// public-domain films with direct .torrent links. The site serves no JSON API,
// so the listing HTML is parsed with stdlib regexp (rung 2 — no HTML-parser dep).
type publicDomain struct {
	http   httpClient
	link   *regexp.Regexp
	titler *regexp.Regexp
}

// newPublicDomain compiles the scrape patterns once (struct fields, never
// per-call — see .claude/rules/no-globals.md) and binds the HTTP client.
func newPublicDomain(h httpClient) publicDomain {
	return publicDomain{
		http:   h,
		link:   regexp.MustCompile(`(?i)href="([^"]+\.torrent)"`),
		titler: regexp.MustCompile(`(?i)>([^<>]{2,120}?)\s*\((\d{4})\)`),
	}
}

// Name identifies this source in logs.
func (publicDomain) Name() string { return "publicdomaintorrents.info" }

// Search fetches the browse listing and maps each .torrent link to a Result;
// query filters client-side by title substring (the index has no search param).
func (p publicDomain) Search(ctx context.Context, query string, _ int) ([]Result, error) {
	body, err := p.http.getBytes(ctx, pdtBase+"/nshowcat.php?category=ALL")
	if err != nil {
		return nil, err
	}
	return p.parse(string(body), strings.ToLower(strings.TrimSpace(query))), nil
}

// parse extracts (title, year, torrent-url) triples from the listing HTML,
// filtering by the lowercased query when one is given.
func (p publicDomain) parse(html, query string) []Result {
	titles := p.titler.FindAllStringSubmatch(html, -1)
	links := p.link.FindAllStringSubmatch(html, -1)
	n := min(len(titles), len(links))
	out := make([]Result, 0, n)
	for i := 0; i < n; i++ {
		title := strings.TrimSpace(titles[i][1])
		if query != "" && !strings.Contains(strings.ToLower(title), query) {
			continue
		}
		year, _ := strconv.Atoi(titles[i][2])
		out = append(out, p.toResult(title, year, links[i][1]))
	}
	return out
}

// toResult maps a scraped film to a Result, carrying the .torrent URL as an
// exact-source magnet hint the client resolves.
func (p publicDomain) toResult(title string, year int, torrentPath string) Result {
	torrent := torrentPath
	if !strings.HasPrefix(torrent, "http") {
		torrent = pdtBase + "/" + strings.TrimPrefix(torrent, "/")
	}
	q := url.Values{}
	q.Set("dn", title)
	q.Set("xs", torrent)
	return Result{
		MovieID: "pdt:" + slug(title),
		Title:   title,
		Year:    year,
		Magnet:  "magnet:?" + q.Encode(),
		Quality: "SD",
	}
}

// slug lowercases title and replaces non-alphanumerics with '-' for a stable id.
func slug(title string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(title) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else if b.Len() > 0 && b.String()[b.Len()-1] != '-' {
			b.WriteByte('-')
		}
	}
	return strings.Trim(b.String(), "-")
}
