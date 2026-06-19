// Package transcode streams non-browser-native containers (mkv, avi…) to
// fragmented mp4 on the fly via ffmpeg, and passes native mp4/webm through.
package transcode

import (
	"context"
	"io"
	"net/http"
	"os/exec"
	"strings"
)

// Native reports whether path's container plays in a browser unchanged
// (mp4/m4v/webm) so the caller can range-serve it instead of transcoding.
func Native(path string) bool {
	switch lowerExt(path) {
	case ".mp4", ".m4v", ".webm":
		return true
	default:
		return false
	}
}

// Serve transcodes src to fragmented mp4 and streams it as a 200 chunked
// video/mp4 response. The ffmpeg child is killed when r's context is cancelled.
// X-Accel-Buffering:no defeats Kong/WAF response buffering.
// ponytail: no seek inside a transcode — non-native files play from the start
// only; HLS segmenting is the upgrade path for mid-file seeks.
func Serve(w http.ResponseWriter, r *http.Request, src io.Reader) {
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	cmd := ffmpegCmd(ctx, src, w)
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	_ = cmd.Run()
}

// ffmpegCmd builds the ffmpeg invocation that reads src on stdin and writes a
// fragmented mp4 to out on stdout, killed when ctx is cancelled.
func ffmpegCmd(ctx context.Context, src io.Reader, out io.Writer) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "ffmpeg",
		"-loglevel", "error",
		"-i", "pipe:0",
		"-c:v", "libx264", "-preset", "veryfast",
		"-c:a", "aac",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4", "pipe:1",
	)
	cmd.Stdin = src
	cmd.Stdout = out
	return cmd
}

// lowerExt returns the lower-cased file extension of path, including the dot.
func lowerExt(path string) string {
	i := strings.LastIndex(path, ".")
	if i < 0 {
		return ""
	}
	return strings.ToLower(path[i:])
}
