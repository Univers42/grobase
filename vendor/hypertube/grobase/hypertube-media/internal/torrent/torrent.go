// Package torrent owns the only third-party dependency (anacrolix/torrent), a
// general BitTorrent download library. Streaming is built on top of it here.
package torrent

import (
	"io"
	"strings"

	at "github.com/anacrolix/torrent"
)

// Progress is the download state of one torrent: bytes verified vs total, the
// live peer count, and whether enough metadata is known to start streaming.
type Progress struct {
	BytesDone  int64 `json:"bytes_done"`
	BytesTotal int64 `json:"bytes_total"`
	Seeders    int   `json:"seeders"`
	Ready      bool  `json:"ready"`
}

// Handle is a single torrent's largest file, exposing a seekable reader whose
// reads block only until the requested bytes are verified (download streaming).
type Handle struct {
	t *at.Torrent
	f *at.File
}

// Length returns the byte length of the streamed file.
func (h *Handle) Length() int64 { return h.f.Length() }

// Name returns the streamed file's display path, used to decide whether the
// container is browser-native (range-served) or needs transcoding.
func (h *Handle) Name() string { return h.f.DisplayPath() }

// Reader returns a fresh torrent.Reader positioned at 0, with readahead set so a
// seek prioritizes the requested pieces; Read blocks until bytes are verified.
func (h *Handle) Reader() at.Reader {
	r := h.f.NewReader()
	r.SetReadahead(4 << 20)
	r.SetResponsive()
	return r
}

// ReadSeeker returns the Handle's Reader as an io.ReadSeeker for the stream layer.
func (h *Handle) ReadSeeker() io.ReadSeeker { return h.Reader() }

// Progress reports verified bytes, total size, active peers, and readiness.
func (h *Handle) Progress() Progress {
	st := h.t.Stats()
	return Progress{
		BytesDone:  h.t.BytesCompleted(),
		BytesTotal: h.t.Length(),
		Seeders:    st.ActivePeers,
		Ready:      h.t.Info() != nil,
	}
}

// magnetFor turns a bare infohash (40-hex or 32-base32) into a magnet URI; an
// input already starting with "magnet:" is returned unchanged.
func magnetFor(ref string) string {
	if strings.HasPrefix(ref, "magnet:") {
		return ref
	}
	return "magnet:?xt=urn:btih:" + ref
}
