package backup

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
)

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
