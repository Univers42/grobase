package sources

import (
	"context"
	"log"
	"sync"
)

// source is the port every torrent index implements.
type source interface {
	Name() string
	Search(ctx context.Context, query string, page int) ([]Result, error)
}

// Aggregator fans a query out to every configured source and merges the results.
// A source that errors is logged and skipped, never fatal — so one dead index
// degrades the catalog instead of failing the request.
type Aggregator struct{ sources []source }

// NewAggregator wires the two real public-domain torrent sources (archive.org +
// publicdomaintorrents.info) over a shared bounded HTTP client.
func NewAggregator() *Aggregator {
	h := newHTTPClient()
	return &Aggregator{sources: []source{
		archive{http: h},
		newPublicDomain(h),
	}}
}

// Search queries all sources concurrently and concatenates their results.
func (a *Aggregator) Search(ctx context.Context, query string, page int) []Result {
	var (
		mu  sync.Mutex
		wg  sync.WaitGroup
		all []Result
	)
	for _, s := range a.sources {
		wg.Add(1)
		go func(s source) {
			defer wg.Done()
			res, err := s.Search(ctx, query, page)
			if err != nil {
				log.Printf("hypertube-search: source %s failed: %v", s.Name(), err)
				return
			}
			mu.Lock()
			all = append(all, res...)
			mu.Unlock()
		}(s)
	}
	wg.Wait()
	return all
}
