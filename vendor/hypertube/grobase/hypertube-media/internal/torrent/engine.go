package torrent

import (
	"context"
	"fmt"

	at "github.com/anacrolix/torrent"
)

// Engine is the BitTorrent client that downloads into a data directory. It is
// constructed once at the composition root and injected (no package globals).
type Engine struct{ cl *at.Client }

// New builds an Engine whose downloaded data lands in dataDir. The client owns
// the peer connections; Close shuts them down.
func New(dataDir string) (*Engine, error) {
	cfg := at.NewDefaultClientConfig()
	cfg.DataDir = dataDir
	cfg.Seed = false
	cl, err := at.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("torrent: new client: %w", err)
	}
	return &Engine{cl: cl}, nil
}

// Close stops the BitTorrent client and releases its connections.
func (e *Engine) Close() error { e.cl.Close(); return nil }

// Ensure adds the torrent for ref, waits for its metadata, and returns a Handle
// over its largest file. ctx bounds the metadata wait so a dead torrent cannot
// block forever.
func (e *Engine) Ensure(ctx context.Context, ref string) (*Handle, error) {
	t, err := e.add(ctx, ref)
	if err != nil {
		return nil, fmt.Errorf("torrent: add %q: %w", ref, err)
	}
	if err := awaitInfo(ctx, t); err != nil {
		return nil, err
	}
	f := largestFile(t)
	if f == nil {
		return nil, fmt.Errorf("torrent: %q has no files", ref)
	}
	return &Handle{t: t, f: f}, nil
}

// add adds ref by metainfo when its magnet carries an `xs` .torrent URL (the
// archive.org case — the magnet has no infohash anacrolix could use), else by
// the magnet / bare infohash.
func (e *Engine) add(ctx context.Context, ref string) (*at.Torrent, error) {
	if src := torrentURL(ref); src != "" {
		if mi, err := fetchMetaInfo(ctx, src); err == nil {
			return e.cl.AddTorrent(mi)
		}
	}
	return e.cl.AddMagnet(magnetFor(ref))
}
