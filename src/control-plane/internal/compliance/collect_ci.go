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

// collectCI scans the gates dir into ciControls (each gate script + whether it
// self-attests PASS), parses the CI workflow's job names, and marshals the CI
// gate-posture section. A missing gates dir is itself evidence (zero controls),
// not a fatal error — it records an empty inventory rather than failing.
func (c *Collector) collectCI() (json.RawMessage, error) {
	entries, err := os.ReadDir(c.gatesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return c.marshalCI([]ciControl{}, nil)
		}
		return nil, err
	}
	controls, err := c.scanGateControls(entries)
	if err != nil {
		return nil, err
	}
	sort.Slice(controls, func(i, j int) bool { return controls[i].File < controls[j].File })
	jobs, err := c.parseCIJobs()
	if err != nil {
		return nil, err
	}
	return c.marshalCI(controls, jobs)
}

// scanGateControls turns the gates-dir entries into one ciControl per gate
// script (mNN-*.sh), recording whether each self-attests PASS. Both regexes are
// compiled once here (not per entry); fileHasPassMarker reuses gatePassRe.
// perf: regex compiled per call — compliance collection, cold path.
func (c *Collector) scanGateControls(entries []os.DirEntry) ([]ciControl, error) {
	gateFileRe := regexp.MustCompile(`^m([0-9]+)-.*\.sh$`)
	gatePassRe := regexp.MustCompile(`m([0-9]+)=PASS`)
	controls := []ciControl{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := gateFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		passing, err := fileHasPassMarker(filepath.Join(c.gatesDir, e.Name()), "m"+m[1], gatePassRe)
		if err != nil {
			return nil, err
		}
		controls = append(controls, ciControl{Gate: "m" + m[1], File: e.Name(), Passing: passing})
	}
	return controls, nil
}

// fileHasPassMarker scans a gate script for its `<gate>=PASS` self-attestation.
// A gate that authors the marker is "passing"; one that does not (a stub, a
// known-failing control, or a script with no gate emission) is "not passing".
// passRe is the caller's compiled `m([0-9]+)=PASS` matcher (reused per file). A
// substring hit is confirmed against passRe so a comment that merely mentions
// the string in prose does not count as a PASS token.
func fileHasPassMarker(path, gate string, passRe *regexp.Regexp) (bool, error) {
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
			for _, mm := range passRe.FindAllStringSubmatch(line, -1) {
				if "m"+mm[1]+"=PASS" == want {
					return true, nil
				}
			}
		}
	}
	return false, sc.Err()
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
