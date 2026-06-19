package torrent

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	at "github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
)

// torrentURL extracts an http(s) `.torrent` exact-source (`xs`) from a magnet
// ref. archive.org magnets carry the .torrent URL there and omit the infohash,
// so anacrolix cannot AddMagnet them. Empty for a plain magnet/infohash.
func torrentURL(ref string) string {
	if !strings.HasPrefix(ref, "magnet:") {
		return ""
	}
	u, err := url.Parse(ref)
	if err != nil {
		return ""
	}
	xs := u.Query().Get("xs")
	if strings.HasPrefix(xs, "http://") || strings.HasPrefix(xs, "https://") {
		return xs
	}
	return ""
}

// fetchMetaInfo downloads and parses a .torrent file from src, bounded by ctx.
func fetchMetaInfo(ctx context.Context, src string) (*metainfo.MetaInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src, nil)
	if err != nil {
		return nil, err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("torrent: fetch %s: status %d", src, res.StatusCode)
	}
	return metainfo.Load(res.Body)
}

// awaitInfo blocks until the torrent's metadata arrives or ctx is done.
func awaitInfo(ctx context.Context, t *at.Torrent) error {
	select {
	case <-t.GotInfo():
		return nil
	case <-ctx.Done():
		return fmt.Errorf("torrent: metadata wait: %w", ctx.Err())
	}
}

// largestFile returns the biggest file in t (the feature video), or nil if empty.
func largestFile(t *at.Torrent) *at.File {
	var best *at.File
	for _, f := range t.Files() {
		if best == nil || f.Length() > best.Length() {
			best = f
		}
	}
	return best
}
