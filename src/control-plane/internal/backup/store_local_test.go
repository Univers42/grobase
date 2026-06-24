/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   store_local_test.go                                :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:40:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:40:26 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package backup

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestLocalFileStoreRoundTrip exercises the full Upload -> Download -> Delete
// lifecycle against a t.TempDir(): the bytes survive the round trip, Upload
// reports the right size and in-stream sha256, and the artifact lands at the
// keyed path. This is the default/gate backend, so its contract is load-bearing.
func TestLocalFileStoreRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := NewLocalFileStore(dir)
	ctx := context.Background()

	const payload = "hello-backup-artifact\nwith\nlines"
	wantSum := sha256.Sum256([]byte(payload))
	wantHex := hex.EncodeToString(wantSum[:])
	key := "tenant-7/backup-id-42"

	loc, size, sum, err := s.Upload(ctx, key, strings.NewReader(payload))
	if err != nil {
		t.Fatalf("Upload: %v", err)
	}
	if size != int64(len(payload)) {
		t.Fatalf("Upload size = %d, want %d", size, len(payload))
	}
	if sum != wantHex {
		t.Fatalf("Upload sha256 = %s, want %s", sum, wantHex)
	}
	wantLoc := filepath.Join(dir, key)
	if loc != wantLoc {
		t.Fatalf("Upload location = %q, want %q", loc, wantLoc)
	}

	var buf bytes.Buffer
	if err := s.Download(ctx, key, &buf); err != nil {
		t.Fatalf("Download: %v", err)
	}
	if buf.String() != payload {
		t.Fatalf("Download = %q, want %q", buf.String(), payload)
	}

	if err := s.Delete(ctx, key); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(wantLoc); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("artifact still present after Delete: %v", err)
	}
}

// TestLocalFileStoreDownloadMissing asserts Download of an absent key errors
// (the open fails) rather than silently returning empty.
func TestLocalFileStoreDownloadMissing(t *testing.T) {
	s := NewLocalFileStore(t.TempDir())
	var buf bytes.Buffer
	err := s.Download(context.Background(), "nope/missing", &buf)
	if err == nil {
		t.Fatalf("Download(missing) returned nil error")
	}
	if !strings.Contains(err.Error(), "open artifact") {
		t.Fatalf("Download(missing) error = %v, want it to mention open artifact", err)
	}
}

// TestLocalFileStoreDeleteMissingIsNoop asserts deleting an absent key is a
// no-op success (os.ErrNotExist is swallowed) — idempotent cleanup.
func TestLocalFileStoreDeleteMissingIsNoop(t *testing.T) {
	s := NewLocalFileStore(t.TempDir())
	if err := s.Delete(context.Background(), "never/existed"); err != nil {
		t.Fatalf("Delete(missing) = %v, want nil", err)
	}
}

// TestLocalFileStorePathTraversal asserts the path() Clean defends against a
// "../" escape: the resolved path stays rooted under dir (filepath.Clean folds
// the leading-slash join), so a crafted key cannot write outside the store.
func TestLocalFileStorePathTraversal(t *testing.T) {
	dir := t.TempDir()
	s := NewLocalFileStore(dir)
	got := s.path("../../etc/passwd")
	if !strings.HasPrefix(got, dir+string(os.PathSeparator)) && got != dir {
		t.Fatalf("path(%q) = %q escaped root %q", "../../etc/passwd", got, dir)
	}
	if strings.Contains(got, "..") {
		t.Fatalf("path(%q) = %q still contains ..", "../../etc/passwd", got)
	}
}

// TestLocalFileStoreEmptyArtifact asserts an empty body uploads cleanly with
// size 0 and the sha256 of the empty string.
func TestLocalFileStoreEmptyArtifact(t *testing.T) {
	s := NewLocalFileStore(t.TempDir())
	emptySum := sha256.Sum256(nil)
	_, size, sum, err := s.Upload(context.Background(), "t/empty", strings.NewReader(""))
	if err != nil {
		t.Fatalf("Upload empty: %v", err)
	}
	if size != 0 {
		t.Fatalf("empty size = %d, want 0", size)
	}
	if sum != hex.EncodeToString(emptySum[:]) {
		t.Fatalf("empty sha256 = %s, want %s", sum, hex.EncodeToString(emptySum[:]))
	}
}
