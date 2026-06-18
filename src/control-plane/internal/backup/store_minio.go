package backup

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// ── MinIOStore (production) ───────────────────────────────────────────────────
//
// MinIO speaks the S3 API; we sign requests with AWS SigV4 using only the
// standard library (crypto/hmac + crypto/sha256), so the production backend adds
// ZERO new module dependency — keeping the thin-binary model and a buildable
// containerized build whose Go module cache need not contain minio-go.

// MinIOStore is an S3/MinIO-backed ArtifactStore. endpoint is the host[:port]
// (no scheme); secure selects https. bucket defaults to "baas" and prefix to
// "backups/" so artifacts land at s3://baas/backups/<tenant>/<id>.
type MinIOStore struct {
	client   *http.Client
	endpoint string // host[:port]
	secure   bool
	region   string
	bucket   string
	prefix   string
	access   string
	secret   string
}

// NewMinIOStore builds an S3/MinIO ArtifactStore and runs a boot-time
// connectivity self-check (PUT+GET+DELETE a probe object) so a misconfigured
// MinIO fails FAST at boot instead of silently degrading at first backup.
func NewMinIOStore(endpoint, user, pass, prefix string) (*MinIOStore, error) {
	secure := strings.HasPrefix(endpoint, "https://")
	endpoint = strings.TrimPrefix(strings.TrimPrefix(endpoint, "https://"), "http://")
	endpoint = strings.TrimRight(endpoint, "/")
	s := &MinIOStore{
		client:   &http.Client{Timeout: 30 * time.Second},
		endpoint: endpoint,
		secure:   secure,
		region:   minioRegion(),
		bucket:   "baas",
		prefix:   normalizePrefix(prefix),
		access:   user,
		secret:   pass,
	}
	if err := s.selfCheck(); err != nil {
		return nil, err
	}
	return s, nil
}

// normalizePrefix defaults an empty prefix to "backups/" and guarantees a single
// trailing slash so objects land at <prefix><key>.
func normalizePrefix(prefix string) string {
	if prefix == "" {
		prefix = "backups/"
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return prefix
}

// minioRegion reads MINIO_REGION, defaulting to us-east-1 (the SigV4 default).
func minioRegion() string {
	if region := os.Getenv("MINIO_REGION"); region != "" {
		return region
	}
	return "us-east-1"
}

// selfCheck proves a PUT+GET+DELETE round-trip before accepting traffic, so a
// misconfigured MinIO fails FAST at boot instead of silently degrading.
func (s *MinIOStore) selfCheck() error {
	probe := strings.TrimPrefix(s.prefix+".probe-"+fmt.Sprint(time.Now().UnixNano()), s.prefix)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, _, err := s.Upload(ctx, probe, strings.NewReader("ok")); err != nil {
		return fmt.Errorf("backup: MinIO self-check upload failed: %w", err)
	}
	if err := s.Download(ctx, probe, io.Discard); err != nil {
		return fmt.Errorf("backup: MinIO self-check download failed: %w", err)
	}
	_ = s.Delete(ctx, probe)
	return nil
}

func (s *MinIOStore) scheme() string {
	if s.secure {
		return "https"
	}
	return "http"
}
