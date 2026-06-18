package compliance

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// ───────────────────────── change management ─────────────────────────────────

// commit is one change-management record: a commit's short hash, author, and
// subject — the audit trail of WHO changed WHAT.
type commit struct {
	Hash    string `json:"hash"`
	Author  string `json:"author"`
	Subject string `json:"subject"`
}

// collectChangeMgmt reads the git change-log snapshot file. Each line is one
// commit in the pipe-delimited form `<hash>|<author>|<subject>` (the format a
// `git log --pretty=format:'%h|%an|%s'` dump produces). git is not in the
// distroless runtime, so the deploy mounts the trail as a snapshot file; when no
// file is configured the section evidences zero commits (an honest "no trail
// available" rather than a fabricated green).
func (c *Collector) collectChangeMgmt() (json.RawMessage, error) {
	commits := []commit{}
	if c.gitLogPath == "" {
		return c.marshalChange(commits, "")
	}
	f, err := os.Open(c.gitLogPath)
	if err != nil {
		if os.IsNotExist(err) {
			return c.marshalChange(commits, c.gitLogPath)
		}
		return nil, err
	}
	defer f.Close()
	commits, err = scanCommitTrail(f)
	if err != nil {
		return nil, err
	}
	return c.marshalChange(commits, c.gitLogPath)
}

// scanCommitTrail parses the pipe-delimited `<hash>|<author>|<subject>` lines
// of a git change-log snapshot into commit records, skipping blank lines.
func scanCommitTrail(f *os.File) ([]commit, error) {
	commits := []commit{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "|", 3)
		cm := commit{Hash: parts[0]}
		if len(parts) > 1 {
			cm.Author = parts[1]
		}
		if len(parts) > 2 {
			cm.Subject = parts[2]
		}
		commits = append(commits, cm)
	}
	return commits, sc.Err()
}

func (c *Collector) marshalChange(commits []commit, src string) (json.RawMessage, error) {
	authors := map[string]bool{}
	for _, cm := range commits {
		if cm.Author != "" {
			authors[cm.Author] = true
		}
	}
	uniq := make([]string, 0, len(authors))
	for a := range authors {
		uniq = append(uniq, a)
	}
	sort.Strings(uniq)
	return json.Marshal(map[string]any{
		"control_type":    "change_management",
		"commits_total":   len(commits),
		"authors":         uniq,
		"commits":         commits,
		"source_gitlog":   src,
		"trail_available": len(commits) > 0,
	})
}
