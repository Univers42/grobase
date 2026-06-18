package scheduler

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"time"
)

type dueRow struct {
	id           string
	tenantID     string
	functionName string
	scheduleExpr string
	payload      string
	timeoutMs    int
	lastRun      time.Time
	hasLastRun   bool
	nextRun      time.Time
}

func (r *Runner) invoke(ctx context.Context, d dueRow, interval time.Duration) (int, error) {
	timeout := time.Duration(d.timeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	reqCtx, cancel := context.WithTimeout(ctx, timeout+5*time.Second)
	defer cancel()

	req, err := r.buildInvokeRequest(reqCtx, d)
	if err != nil {
		return 0, err
	}
	resp, err := r.httpClient.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return resp.StatusCode, nil
	}
	return resp.StatusCode, &httpStatusError{code: resp.StatusCode}
}

// buildInvokeRequest constructs the POST request to the functions-runtime that
// invokes the scheduled function with its payload and provenance headers.
func (r *Runner) buildInvokeRequest(ctx context.Context, d dueRow) (*http.Request, error) {
	body := d.payload
	if body == "" {
		body = "{}"
	}
	url := r.runtimeURL + "/v1/functions/" + d.functionName + "/invoke"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Baas-Tenant-Id", d.tenantID)
	req.Header.Set("X-Baas-Event-Source", "function-schedule")
	req.Header.Set("User-Agent", "mini-baas-function-scheduler/1.0")
	return req, nil
}

type httpStatusError struct{ code int }

func (e *httpStatusError) Error() string {
	return "non-2xx response: " + itoa(e.code)
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
