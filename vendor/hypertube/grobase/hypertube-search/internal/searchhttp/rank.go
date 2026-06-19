package searchhttp

import (
	"sort"
	"strings"
)

const pageSize = 20

// Page is a paginated slice of enriched items plus the cursor the UI echoes.
type Page struct {
	Results []Item `json:"results"`
	Page    int    `json:"page"`
	Count   int    `json:"count"`
}

// rankAndPage filters by genre/year, orders the items (alphabetical when a query
// is present, else by popularity), and returns the requested 1-based page.
func rankAndPage(items []Item, q query) Page {
	items = filter(items, q)
	if q.text != "" {
		sort.SliceStable(items, func(i, j int) bool {
			return strings.ToLower(items[i].Title) < strings.ToLower(items[j].Title)
		})
	} else {
		sort.SliceStable(items, func(i, j int) bool {
			return items[i].Popularity() > items[j].Popularity()
		})
	}
	return paginate(items, max(q.page, 1))
}

// filter keeps only items matching the genre and year facets (empty = no facet).
func filter(items []Item, q query) []Item {
	out := make([]Item, 0, len(items))
	for _, it := range items {
		if q.year > 0 && it.Year != q.year {
			continue
		}
		if q.genre != "" && !hasGenre(it, q.genre) {
			continue
		}
		out = append(out, it)
	}
	return out
}

// hasGenre reports whether item carries the named genre (case-insensitive).
func hasGenre(it Item, genre string) bool {
	g := strings.ToLower(genre)
	for _, name := range it.Metadata.Genres {
		if strings.ToLower(name) == g {
			return true
		}
	}
	return false
}

// paginate slices items into the 1-based page of pageSize, clamping bounds.
func paginate(items []Item, page int) Page {
	start := (page - 1) * pageSize
	if start > len(items) {
		start = len(items)
	}
	end := min(start+pageSize, len(items))
	out := items[start:end]
	if out == nil {
		out = []Item{}
	}
	return Page{Results: out, Page: page, Count: len(items)}
}
