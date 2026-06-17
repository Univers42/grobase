package compliance

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ciControl is one CI/gate control's evidence: the gate file, its milestone id,
// and whether it self-attests PASS.
type ciControl struct {
	Gate    string `json:"gate"`    // m104
	File    string `json:"file"`    // m104-audit-chain.sh
	Passing bool   `json:"passing"` // true iff the script emits a <gate>=PASS marker
}

func (c *Collector) collectCI() (json.RawMessage, error) {
	controls := []ciControl{}
	entries, err := os.ReadDir(c.gatesDir)
	if err != nil {
		// A missing gates dir is itself evidence (zero controls) — not a fatal
		// collector error. Record it as an empty inventory rather than failing.
		if os.IsNotExist(err) {
			return c.marshalCI(controls, nil)
		}
		return nil, err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := gateFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		passing, err := fileHasPassMarker(filepath.Join(c.gatesDir, e.Name()), "m"+m[1])
		if err != nil {
			return nil, err
		}
		controls = append(controls, ciControl{Gate: "m" + m[1], File: e.Name(), Passing: passing})
	}
	sort.Slice(controls, func(i, j int) bool { return controls[i].File < controls[j].File })

	jobs, err := c.parseCIJobs()
	if err != nil {
		return nil, err
	}
	return c.marshalCI(controls, jobs)
}

// fileHasPassMarker scans a gate script for its `<gate>=PASS` self-attestation.
// A gate that authors the marker is "passing"; one that does not (a stub, a
// known-failing control, or a script with no gate emission) is "not passing".
func fileHasPassMarker(path, gate string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	want := gate + "=PASS"
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.Contains(line, want) {
			// also confirm the regex agrees this is a PASS token (defense vs a
			// comment that merely mentions the string in prose).
			for _, mm := range gatePassRe.FindAllStringSubmatch(line, -1) {
				if "m"+mm[1]+"=PASS" == want {
					return true, nil
				}
			}
		}
	}
	return false, sc.Err()
}

// parseCIJobs extracts the `<id>:` job keys under a `jobs:` block of a CI
// workflow YAML (a lightweight parse — no YAML dep). Returns nil when no
// workflow is configured, which is fine: the CI section then evidences gates
// only. This is enough to record "which CI jobs exist" as control evidence.
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
	var jobs []string
	inJobs := false
	jobKeyRe := regexp.MustCompile(`^  ([A-Za-z0-9_-]+):\s*$`)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "jobs:") {
			inJobs = true
			continue
		}
		if inJobs {
			// a top-level key (no indent) ends the jobs block.
			if len(line) > 0 && line[0] != ' ' && line[0] != '#' {
				inJobs = false
				continue
			}
			if m := jobKeyRe.FindStringSubmatch(line); m != nil {
				jobs = append(jobs, m[1])
			}
		}
	}
	sort.Strings(jobs)
	return jobs, sc.Err()
}

func (c *Collector) marshalCI(controls []ciControl, jobs []string) (json.RawMessage, error) {
	passing := 0
	for _, ct := range controls {
		if ct.Passing {
			passing++
		}
	}
	return json.Marshal(map[string]any{
		"control_type":    "ci_gate_posture",
		"gates_total":     len(controls),
		"gates_passing":   passing,
		"all_passing":     len(controls) > 0 && passing == len(controls),
		"gates":           controls,
		"ci_jobs":         jobs,
		"source_gatesdir": c.gatesDir,
	})
}

// ───────────────────────── access review ─────────────────────────────────────
