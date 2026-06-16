// Package backup implements per-tenant logical backup + restore (Track-B B6).
//
// The data path is Go-native logical export over the EXISTING pgx pool: COPY ...
// TO STDOUT streams each table into an [ArtifactStore]; restore replays COPY ...
// FROM STDIN inside one transaction per scope (atomic — full restore or full
// rollback, never partial). No pg_dump binary, no image change.
//
// MVP supports the two clean isolation models only — schema_per_tenant and
// db_per_tenant. shared_rls (filtered dump + upsert into a LIVE shared table)
// and tenant_owned (external DB) are DEFERRED and rejected with a 400-mapped
// [ErrIsolationDeferred].
//
// The whole surface is flag-gated by TENANT_BACKUP_ENABLED (default OFF); when
// off, main.go never mounts the routes, so nothing in this package ever runs and
// the table stays empty = byte-parity baseline.
package backup

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// ArtifactStore is the storage abstraction behind which a backup artifact is
// persisted. The DEFAULT backend is [LocalFileStore] (the gate needs no MinIO
// container on the RAM-constrained box); [MinIOStore] is the production backend
// behind the SAME interface so the code path is identical.
//
// Upload streams r to the artifact identified by key and returns the resolved
// location (a path or an s3:// URL), the byte size written, and the lower-hex
// sha256 of the bytes (computed in-stream, never buffering the whole artifact).
type ArtifactStore interface {
	Upload(ctx context.Context, key string, r io.Reader) (location string, size int64, sha256hex string, err error)
	Download(ctx context.Context, key string, w io.Writer) error
	Delete(ctx context.Context, key string) error
}

// ── LocalFileStore (default / gate) ──────────────────────────────────────────

// LocalFileStore writes artifacts under dir/<key>. It computes sha256 in-stream
// via io.TeeReader and publishes atomically (temp file -> rename) so a partial
// write is never observable as a completed artifact.
type LocalFileStore struct{ dir string }

// NewLocalFileStore returns a filesystem-backed ArtifactStore rooted at dir.
func NewLocalFileStore(dir string) *LocalFileStore { return &LocalFileStore{dir: dir} }

func (s *LocalFileStore) path(key string) string {
	// key is "<tenant>/<backupId>"; both are sanitized upstream (tenant id and a
	// gen_random_uuid()), but Clean defends against any "../" regardless.
	return filepath.Join(s.dir, filepath.Clean("/"+key))
}

func (s *LocalFileStore) Upload(ctx context.Context, key string, r io.Reader) (string, int64, string, error) {
	dst := s.path(key)
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return "", 0, "", fmt.Errorf("backup: mkdir artifact dir: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".bak-*")
	if err != nil {
		return "", 0, "", fmt.Errorf("backup: create temp artifact: %w", err)
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }() // no-op after a successful rename

	h := sha256.New()
	n, err := io.Copy(tmp, io.TeeReader(r, h))
	if err != nil {
		_ = tmp.Close()
		return "", 0, "", fmt.Errorf("backup: write artifact: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return "", 0, "", fmt.Errorf("backup: sync artifact: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", 0, "", fmt.Errorf("backup: close artifact: %w", err)
	}
	if err := os.Rename(tmpName, dst); err != nil {
		return "", 0, "", fmt.Errorf("backup: publish artifact: %w", err)
	}
	return dst, n, hex.EncodeToString(h.Sum(nil)), nil
}

func (s *LocalFileStore) Download(ctx context.Context, key string, w io.Writer) error {
	f, err := os.Open(s.path(key))
	if err != nil {
		return fmt.Errorf("backup: open artifact: %w", err)
	}
	defer func() { _ = f.Close() }()
	if _, err := io.Copy(w, f); err != nil {
		return fmt.Errorf("backup: read artifact: %w", err)
	}
	return nil
}

func (s *LocalFileStore) Delete(ctx context.Context, key string) error {
	if err := os.Remove(s.path(key)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("backup: delete artifact: %w", err)
	}
	return nil
}

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
	if prefix == "" {
		prefix = "backups/"
	}
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	region := os.Getenv("MINIO_REGION")
	if region == "" {
		region = "us-east-1"
	}
	s := &MinIOStore{
		client:   &http.Client{Timeout: 30 * time.Second},
		endpoint: endpoint,
		secure:   secure,
		region:   region,
		bucket:   "baas",
		prefix:   prefix,
		access:   user,
		secret:   pass,
	}
	// Boot-time self-check: prove round-trip before accepting traffic.
	probe := s.prefix + ".probe-" + fmt.Sprint(time.Now().UnixNano())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, _, err := s.Upload(ctx, strings.TrimPrefix(probe, s.prefix), strings.NewReader("ok")); err != nil {
		return nil, fmt.Errorf("backup: MinIO self-check upload failed: %w", err)
	}
	if err := s.Download(ctx, strings.TrimPrefix(probe, s.prefix), io.Discard); err != nil {
		return nil, fmt.Errorf("backup: MinIO self-check download failed: %w", err)
	}
	_ = s.Delete(ctx, strings.TrimPrefix(probe, s.prefix))
	return s, nil
}

func (s *MinIOStore) scheme() string {
	if s.secure {
		return "https"
	}
	return "http"
}

// objectURL builds the full URL for an artifact key (key is relative to prefix).
func (s *MinIOStore) objectURL(key string) string {
	obj := s.prefix + strings.TrimPrefix(key, "/")
	return fmt.Sprintf("%s://%s/%s/%s", s.scheme(), s.endpoint, s.bucket, obj)
}

func (s *MinIOStore) Upload(ctx context.Context, key string, r io.Reader) (string, int64, string, error) {
	// S3 PUT must sign a payload hash; we read into memory only for the small
	// control-plane process. For very large artifacts the service streams to the
	// LocalFileStore default; the MinIO backend is for the production path and is
	// size-bounded by MAX_BACKUP_SIZE_BYTES upstream.
	body, err := io.ReadAll(r)
	if err != nil {
		return "", 0, "", fmt.Errorf("backup: read upload body: %w", err)
	}
	sum := sha256.Sum256(body)
	hexsum := hex.EncodeToString(sum[:])
	if err := s.do(ctx, http.MethodPut, key, body, hexsum); err != nil {
		return "", 0, "", err
	}
	return "s3://" + s.bucket + "/" + s.prefix + strings.TrimPrefix(key, "/"), int64(len(body)), hexsum, nil
}

func (s *MinIOStore) Download(ctx context.Context, key string, w io.Writer) error {
	emptyHash := hex.EncodeToString(sha256.New().Sum(nil))
	req, err := s.signedRequest(ctx, http.MethodGet, key, nil, emptyHash)
	if err != nil {
		return err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("backup: MinIO GET: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("backup: MinIO GET %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if _, err := io.Copy(w, resp.Body); err != nil {
		return fmt.Errorf("backup: MinIO GET copy: %w", err)
	}
	return nil
}

func (s *MinIOStore) Delete(ctx context.Context, key string) error {
	emptyHash := hex.EncodeToString(sha256.New().Sum(nil))
	return s.do(ctx, http.MethodDelete, key, nil, emptyHash)
}

func (s *MinIOStore) do(ctx context.Context, method, key string, body []byte, payloadHash string) error {
	req, err := s.signedRequest(ctx, method, key, body, payloadHash)
	if err != nil {
		return err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("backup: MinIO %s: %w", method, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode/100 != 2 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("backup: MinIO %s %d: %s", method, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

// signedRequest builds an AWS SigV4-signed S3 request (stdlib-only).
func (s *MinIOStore) signedRequest(ctx context.Context, method, key string, body []byte, payloadHash string) (*http.Request, error) {
	u, err := url.Parse(s.objectURL(key))
	if err != nil {
		return nil, fmt.Errorf("backup: build object url: %w", err)
	}
	var rdr io.Reader
	if body != nil {
		rdr = strings.NewReader(string(body))
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), rdr)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")

	req.Header.Set("Host", u.Host)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)

	canonicalURI := u.EscapedPath()
	canonicalHeaders := fmt.Sprintf("host:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n", u.Host, payloadHash, amzDate)
	signedHeaders := "host;x-amz-content-sha256;x-amz-date"
	canonicalRequest := strings.Join([]string{method, canonicalURI, "", canonicalHeaders, signedHeaders, payloadHash}, "\n")

	scope := strings.Join([]string{dateStamp, s.region, "s3", "aws4_request"}, "/")
	crHash := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope, hex.EncodeToString(crHash[:])}, "\n")

	signingKey := sigV4Key(s.secret, dateStamp, s.region, "s3")
	sig := hmacSHA256(signingKey, []byte(stringToSign))
	auth := fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		s.access, scope, signedHeaders, hex.EncodeToString(sig))
	req.Header.Set("Authorization", auth)
	return req, nil
}

func hmacSHA256(key, data []byte) []byte {
	m := hmac.New(sha256.New, key)
	m.Write(data)
	return m.Sum(nil)
}

func sigV4Key(secret, dateStamp, region, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), []byte(dateStamp))
	kRegion := hmacSHA256(kDate, []byte(region))
	kService := hmacSHA256(kRegion, []byte(service))
	return hmacSHA256(kService, []byte("aws4_request"))
}

// ── selector ─────────────────────────────────────────────────────────────────

// NewStoreFromEnv selects the artifact backend from the environment: a
// MinIOStore when MINIO_ENDPOINT and MINIO_ROOT_USER are set (the production
// compose vars pg-backup already uses), otherwise a LocalFileStore rooted at
// $BACKUP_DATA_DIR (default /var/lib/baas-artifacts). main.go consumes this.
func NewStoreFromEnv() (ArtifactStore, error) {
	if ep := os.Getenv("MINIO_ENDPOINT"); ep != "" && os.Getenv("MINIO_ROOT_USER") != "" {
		return NewMinIOStore(ep, os.Getenv("MINIO_ROOT_USER"), os.Getenv("MINIO_ROOT_PASSWORD"), "backups/")
	}
	dir := os.Getenv("BACKUP_DATA_DIR")
	if dir == "" {
		dir = "/var/lib/baas-artifacts"
	}
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("backup: create local artifact dir %q: %w", dir, err)
	}
	return NewLocalFileStore(dir), nil
}
