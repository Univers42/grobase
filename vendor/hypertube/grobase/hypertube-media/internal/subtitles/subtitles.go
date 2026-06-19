// Package subtitles fetches OpenSubtitles tracks and converts SRT to WebVTT.
// With no API key the fetcher degrades to empty tracks instead of failing.
package subtitles

import (
	"context"
	"net/http"
	"time"
)

// apiBase is the OpenSubtitles REST endpoint used to discover tracks.
const apiBase = "https://api.opensubtitles.com/api/v1"

// Fetcher resolves subtitle tracks for a media id from OpenSubtitles. It holds
// the API key (injected, never a global) and an HTTP client with a timeout.
type Fetcher struct {
	key  string
	http *http.Client
}

// New returns a Fetcher bound to the OpenSubtitles API key; an empty key makes
// VTT return an empty track (graceful degradation, never an error).
func New(key string) *Fetcher {
	return &Fetcher{key: key, http: &http.Client{Timeout: 10 * time.Second}}
}

// Enabled reports whether an OpenSubtitles key is configured.
func (f *Fetcher) Enabled() bool { return f.key != "" }

// VTT returns the WebVTT body for mediaID in lang (English is always attempted
// as a fallback). Without a key, or on any upstream failure, it returns an empty
// but valid WebVTT document so the player degrades gracefully.
func (f *Fetcher) VTT(ctx context.Context, mediaID, lang string) string {
	if !f.Enabled() {
		return emptyVTT
	}
	srt, err := f.fetchSRT(ctx, mediaID, lang)
	if err != nil || srt == "" {
		return emptyVTT
	}
	return srtToVTT(srt)
}

// emptyVTT is a minimal valid WebVTT document with no cues.
const emptyVTT = "WEBVTT\n\n"
