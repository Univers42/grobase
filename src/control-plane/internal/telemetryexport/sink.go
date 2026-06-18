package telemetryexport

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
)

// httpSink is the default sink: it POSTs a tenant's serialized batch to that
// tenant's configured collector endpoint. It is the ONLY place an outbound
// connection is opened, and only ever from the export loop, which only runs when
// the flag is on — so with the flag OFF no httpSink.Deliver is ever called and no
// connection is made (the parity invariant).
type httpSink struct{ client *http.Client }

// Deliver POSTs body to endpoint. authHeader, when non-empty, is sent as the
// Authorization header (the customer's collector token). A non-2xx response or a
// transport error is returned so the exporter leaves the cursor unadvanced and
// retries the tenant next tick (at-least-once delivery, never silent loss). The
// response body is drained to io.Discard before close so the keep-alive
// connection can be reused.
func (s *httpSink) Deliver(ctx context.Context, endpoint, authHeader, contentType string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer func() {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("collector returned HTTP %d", resp.StatusCode)
	}
	return nil
}
