package searchhttp

import (
	"context"
	"sync"

	"hypertube/search/internal/metadata"
	"hypertube/search/internal/sources"
)

// Item is one search hit: the normalized torrent fields plus TMDb enrichment.
type Item struct {
	sources.Result
	Metadata metadata.Info `json:"metadata"`
}

// Service composes the torrent aggregator with the TMDb enricher. Both are
// injected ports (no globals — see .claude/rules/no-globals.md).
type Service struct {
	agg    *sources.Aggregator
	enrich *metadata.Enricher
}

// NewService wires the aggregator and enricher into a search service.
func NewService(agg *sources.Aggregator, enrich *metadata.Enricher) *Service {
	return &Service{agg: agg, enrich: enrich}
}

// collect fans the query out to the sources and enriches each result with TMDb
// metadata concurrently, returning the merged, enriched items.
func (s *Service) collect(ctx context.Context, query string, page int) []Item {
	raw := s.agg.Search(ctx, query, page)
	items := make([]Item, len(raw))
	var wg sync.WaitGroup
	for i := range raw {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			items[i] = Item{
				Result:   raw[i],
				Metadata: s.enrich.Enrich(ctx, raw[i].Title, raw[i].Year),
			}
		}(i)
	}
	wg.Wait()
	return items
}
