package compliance

import (
	"bufio"
	"os"
	"regexp"
	"sort"
	"strings"
)

// parseCIJobs extracts the `<id>:` job keys under a `jobs:` block of a CI
// workflow YAML (a lightweight parse — no YAML dep) via jobKeyRe, which matches
// a `<id>:` job key indented two spaces under a `jobs:` block. Returns nil when
// no workflow is configured, which is fine: the CI section then evidences gates
// only. This is enough to record "which CI jobs exist" as control evidence.
// perf: regex compiled per call — compliance collection, cold path.
func (c *Collector) parseCIJobs() ([]string, error) {
	if c.ciWorkflow == "" {
		return nil, nil
	}
	f, err := os.Open(c.ciWorkflow)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	jobKeyRe := regexp.MustCompile(`^  ([A-Za-z0-9_-]+):\s*$`)
	jobs, err := scanWorkflowJobs(f, jobKeyRe)
	if err != nil {
		return nil, err
	}
	sort.Strings(jobs)
	return jobs, nil
}

// scanWorkflowJobs reads the job keys from an open workflow file, tracking
// whether the scanner is inside the `jobs:` block. A top-level (unindented) key
// ends the block. jobKeyRe is the caller's compiled job-key matcher.
func scanWorkflowJobs(f *os.File, jobKeyRe *regexp.Regexp) ([]string, error) {
	var jobs []string
	inJobs := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "jobs:") {
			inJobs = true
			continue
		}
		if !inJobs {
			continue
		}
		if len(line) > 0 && line[0] != ' ' && line[0] != '#' {
			inJobs = false
			continue
		}
		if m := jobKeyRe.FindStringSubmatch(line); m != nil {
			jobs = append(jobs, m[1])
		}
	}
	return jobs, sc.Err()
}
