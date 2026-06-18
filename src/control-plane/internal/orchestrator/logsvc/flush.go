package logsvc

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
)

// flush pushes up to batchSize queued entries to Loki. On failure the batch is
// returned to the FRONT of the queue (no loss), mirroring the Node unshift.
func (s *Service) flush() {
	s.mu.Lock()
	if len(s.queue) == 0 {
		s.mu.Unlock()
		return
	}
	n := s.batchSize
	if n > len(s.queue) {
		n = len(s.queue)
	}
	batch := make([]Entry, n)
	copy(batch, s.queue[:n])
	s.queue = s.queue[n:]
	s.mu.Unlock()

	if err := s.push(batch); err != nil {
		s.mu.Lock()
		s.queue = append(batch, s.queue...)
		s.mu.Unlock()
		s.log.Warn("loki push failed", "err", err)
	}
}

func (s *Service) push(batch []Entry) error {
	streams := make([]map[string]any, 0, len(batch))
	for _, e := range batch {
		streams = append(streams, toLokiStream(e))
	}
	body, err := json.Marshal(map[string]any{"streams": streams})
	if err != nil {
		return err
	}
	req, err := http.NewRequest(http.MethodPost, s.lokiURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return &lokiError{status: resp.StatusCode}
	}
	return nil
}

type lokiError struct{ status int }

func (e *lokiError) Error() string { return "loki push returned " + strconv.Itoa(e.status) }
