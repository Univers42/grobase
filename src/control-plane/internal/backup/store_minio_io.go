package backup

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// objectURL builds the full URL for an artifact key (key is relative to prefix).
func (s *MinIOStore) objectURL(key string) string {
	obj := s.prefix + strings.TrimPrefix(key, "/")
	return fmt.Sprintf("%s://%s/%s/%s", s.scheme(), s.endpoint, s.bucket, obj)
}

// Upload PUTs the artifact to MinIO. S3 PUT must sign a payload hash, so the body
// is read into memory; this is bounded — the MinIO backend is the production path,
// size-capped by MAX_BACKUP_SIZE_BYTES upstream (very large artifacts stream to the
// LocalFileStore default instead).
func (s *MinIOStore) Upload(ctx context.Context, key string, r io.Reader) (string, int64, string, error) {
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
