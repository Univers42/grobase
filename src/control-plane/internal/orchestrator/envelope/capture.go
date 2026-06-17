package envelope

import (
	"bytes"
	"net/http"
)

// capture buffers a handler's response so the body can be re-wrapped.
type capture struct {
	header http.Header
	buf    bytes.Buffer
	status int
	wrote  bool
}

func (c *capture) Header() http.Header { return c.header }
func (c *capture) WriteHeader(s int)   { c.status = s; c.wrote = true }
func (c *capture) Write(b []byte) (int, error) {
	if !c.wrote {
		c.status = http.StatusOK // net/http implicit-200 on first Write
		c.wrote = true
	}
	return c.buf.Write(b)
}

// writeVerbatim replays the captured response unchanged (the passthrough path).
func writeVerbatim(w http.ResponseWriter, c *capture, body []byte) {
	copyHeader(w.Header(), c.header)
	w.WriteHeader(c.status)
	_, _ = w.Write(body)
}

func copyHeader(dst, src http.Header) {
	for k, vs := range src {
		// Content-Length/Type are re-set by Wrap on the wrapped path.
		if k == "Content-Length" {
			continue
		}
		for _, v := range vs {
			dst.Add(k, v)
		}
	}
}
