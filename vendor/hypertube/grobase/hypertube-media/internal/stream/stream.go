// Package stream serves a possibly-still-downloading file as HTTP 206 Partial
// Content, bounding every Range so a seek never waits for the whole tail.
package stream

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// chunkCap bounds an open-ended Range so the response head flushes promptly
// instead of waiting on the file tail to download.
const chunkCap int64 = 8 << 20

// byteRange is a resolved [start,end] inclusive slice of a length-byte resource.
type byteRange struct{ start, end int64 }

// Serve writes src as a 206 Partial Content response for r's Range header (or a
// full 200 when absent), setting Accept-Ranges, Content-Range and Content-Length.
// X-Accel-Buffering:no defeats Kong/WAF response buffering on the live stream.
func Serve(w http.ResponseWriter, r *http.Request, src io.ReadSeeker, length int64, contentType string) {
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("X-Accel-Buffering", "no")
	hdr := r.Header.Get("Range")
	if hdr == "" {
		serveFull(w, src, length)
		return
	}
	br, ok := parseRange(hdr, length)
	if !ok {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", length))
		w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return
	}
	servePartial(w, src, br, length)
}

// serveFull writes the whole resource as 200, capped to the readahead chunk so
// the head flushes before the tail finishes downloading.
func serveFull(w http.ResponseWriter, src io.ReadSeeker, length int64) {
	n := length
	if n > chunkCap {
		n = chunkCap
	}
	w.Header().Set("Content-Length", strconv.FormatInt(n, 10))
	w.WriteHeader(http.StatusOK)
	_, _ = io.CopyN(w, src, n)
}

// servePartial seeks to br.start and writes the bounded slice as 206.
func servePartial(w http.ResponseWriter, src io.ReadSeeker, br byteRange, length int64) {
	if _, err := src.Seek(br.start, io.SeekStart); err != nil {
		http.Error(w, "seek failed", http.StatusInternalServerError)
		return
	}
	n := br.end - br.start + 1
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", br.start, br.end, length))
	w.Header().Set("Content-Length", strconv.FormatInt(n, 10))
	w.WriteHeader(http.StatusPartialContent)
	_, _ = io.CopyN(w, src, n)
}

// parseRange reads a single "bytes=start-end" header against length, bounding an
// open end to chunkCap so a seek never blocks on the whole tail. ok is false on
// a malformed, multi-range, or out-of-bounds request.
func parseRange(hdr string, length int64) (byteRange, bool) {
	spec, found := strings.CutPrefix(strings.TrimSpace(hdr), "bytes=")
	if !found || strings.Contains(spec, ",") {
		return byteRange{}, false
	}
	lo, hi, ok := strings.Cut(spec, "-")
	if !ok {
		return byteRange{}, false
	}
	start, err := strconv.ParseInt(strings.TrimSpace(lo), 10, 64)
	if err != nil || start < 0 || start >= length {
		return byteRange{}, false
	}
	return boundEnd(start, strings.TrimSpace(hi), length)
}

// boundEnd resolves the end of a range: an explicit end is clamped to length-1,
// an absent end is capped to start+chunkCap-1 so the response stays bounded.
func boundEnd(start int64, hi string, length int64) (byteRange, bool) {
	end := start + chunkCap - 1
	if hi != "" {
		v, err := strconv.ParseInt(hi, 10, 64)
		if err != nil || v < start {
			return byteRange{}, false
		}
		end = v
	}
	if end > length-1 {
		end = length - 1
	}
	return byteRange{start: start, end: end}, true
}
