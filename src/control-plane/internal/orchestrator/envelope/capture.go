/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   capture.go                                         :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:48:13 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:48:14 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

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

// Write buffers the body and, like net/http, records an implicit 200 on the
// first Write when the handler never called WriteHeader.
func (c *capture) Write(b []byte) (int, error) {
	if !c.wrote {
		c.status = http.StatusOK
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

// copyHeader copies src into dst, skipping Content-Length because Wrap re-sets
// Content-Length/Type itself on the wrapped path.
func copyHeader(dst, src http.Header) {
	for k, vs := range src {
		if k == "Content-Length" {
			continue
		}
		for _, v := range vs {
			dst.Add(k, v)
		}
	}
}
