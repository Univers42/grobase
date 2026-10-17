package authz

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

const pageModel = `{"types":{
 "workspace":{"relations":{"member":{"types":["user"]}}},
 "page":{
  "relations":{"parent":{"types":["page"]},"owner":{"types":["user"]},
    "viewer":{"types":["user","user:*","workspace#member"]},"blocked":{"types":["user"]}},
  "permissions":{
    "read":{"union":[{"relation":"owner"},{"relation":"viewer"},{"from":"parent","permission":"read"}]},
    "view":{"exclude":{"base":{"permission":"read"},"minus":{"relation":"blocked"}}}}}}}`

// parentFirstModel evaluates the parent edge before any direct grant, so a
// cycle is met before the node's own ALLOW branch.
const parentFirstModel = `{"types":{"page":{
  "relations":{"parent":{"types":["page"]},"owner":{"types":["user"]}},
  "permissions":{"read":{"union":[{"from":"parent","permission":"read"},{"relation":"owner"}]}}}}}`

// memSource serves tuples from memory and records every Load call.
type memSource struct {
	rows  map[Want][]Subject
	calls [][]Want
	err   error
}

func newMem(lines ...string) *memSource {
	m := &memSource{rows: map[Want][]Subject{}}
	for _, l := range lines {
		m.add(l)
	}
	return m
}

// add takes "object relation subject", e.g. "page:1 owner user:alice".
func (m *memSource) add(line string) {
	f := strings.Fields(line)
	obj, _ := ParseRef(f[0])
	sub, err := ParseSubject(f[2])
	if err != nil {
		panic(err)
	}
	w := Want{obj.Type, obj.ID, f[1]}
	m.rows[w] = append(m.rows[w], sub)
}

func (m *memSource) Load(_ context.Context, wants []Want, maxRows int) ([]Tuple, error) {
	m.calls = append(m.calls, wants)
	if m.err != nil {
		return nil, m.err
	}
	var out []Tuple
	for _, w := range wants {
		for _, s := range m.rows[w] {
			out = append(out, Tuple{Want: w, Subject: s})
		}
	}
	if len(out) > maxRows {
		return nil, ErrRowBudget
	}
	return out, nil
}

func mustModel(t *testing.T, doc string) *Model {
	t.Helper()
	m, err := ParseModel([]byte(doc))
	if err != nil {
		t.Fatalf("ParseModel: %v", err)
	}
	return m
}

func check(t *testing.T, doc string, src Source, name, user string, objs ...string) []Decision {
	t.Helper()
	refs := make([]Ref, len(objs))
	for i, o := range objs {
		r, err := ParseRef(o)
		if err != nil {
			t.Fatal(err)
		}
		refs[i] = r
	}
	ev := &Evaluator{Model: mustModel(t, doc), Limits: DefaultLimits()}
	ds, err := ev.Check(context.Background(), src, Query{App: "a", UserID: user, Name: name, Objects: refs})
	if err != nil {
		t.Fatalf("Check: %v", err)
	}
	return ds
}

func TestCheckTable(t *testing.T) {
	cases := []struct {
		name    string
		tuples  []string
		perm    string
		user    string
		object  string
		allowed bool
	}{
		{"direct owner", []string{"page:1 owner user:alice"}, "read", "alice", "page:1", true},
		{"direct other user", []string{"page:1 owner user:alice"}, "read", "bob", "page:1", false},
		{"no tuples", nil, "read", "alice", "page:1", false},
		{"computed permission", []string{"page:1 owner user:alice"}, "view", "alice", "page:1", true},
		{"tuple to userset", []string{"page:2 parent page:1", "page:1 owner user:alice"}, "read", "alice", "page:2", true},
		{"tuple to userset, other user", []string{"page:2 parent page:1", "page:1 owner user:alice"}, "read", "bob", "page:2", false},
		{"userset member", []string{"page:1 viewer workspace:w#member", "workspace:w member user:bob"}, "read", "bob", "page:1", true},
		{"userset non member", []string{"page:1 viewer workspace:w#member", "workspace:w member user:bob"}, "read", "eve", "page:1", false},
		{"wildcard", []string{"page:1 viewer user:*"}, "read", "anyone", "page:1", true},
		{"exclude blocks", []string{"page:1 owner user:bob", "page:1 blocked user:bob"}, "view", "bob", "page:1", false},
		{"exclude spares others", []string{"page:1 viewer user:*", "page:1 blocked user:bob"}, "view", "alice", "page:1", true},
		{"exclude, blocked via parent grant", []string{"page:2 parent page:1", "page:1 owner user:bob", "page:2 blocked user:bob"}, "view", "bob", "page:2", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := check(t, pageModel, newMem(c.tuples...), c.perm, c.user, c.object)[0]
			if d.Allowed != c.allowed || d.Cut {
				t.Fatalf("got %+v, want allowed=%v cut=false", d, c.allowed)
			}
		})
	}
}

func chain(n int, ownerAt int) *memSource {
	m := newMem()
	for i := 0; i < n; i++ {
		m.add(fmt.Sprintf("page:%d parent page:%d", i, i+1))
	}
	m.add(fmt.Sprintf("page:%d owner user:alice", ownerAt))
	return m
}

func TestDepthCap(t *testing.T) {
	// The root is level 1: an owner 15 hops up is level 16, the last allowed.
	if d := check(t, pageModel, chain(40, 15), "read", "alice", "page:0")[0]; !d.Allowed || d.Cut {
		t.Fatalf("depth 16: got %+v, want a clean allow", d)
	}
	d := check(t, pageModel, chain(40, 16), "read", "alice", "page:0")[0]
	if d.Allowed || !d.Cut {
		t.Fatalf("depth 17: got %+v, want deny with cut", d)
	}
}

// The cap must not depend on what else is in the batch: a memoized tall
// subtree answers CUT when reused below depth 1.
func TestDepthCapIsBatchOrderIndependent(t *testing.T) {
	src := chain(40, 20)
	alone := check(t, pageModel, src, "read", "alice", "page:0")[0]
	ds := check(t, pageModel, chain(40, 20), "read", "alice", "page:5", "page:0")
	if ds[1] != (Decision{Object: Ref{"page", "0"}, Cut: true}) || alone.Allowed {
		t.Fatalf("page:0 in a batch %+v, alone %+v: want deny+cut both ways", ds[1], alone)
	}
	if !ds[0].Allowed {
		t.Fatalf("page:5 is 16 levels from the owner: %+v", ds[0])
	}
}

func TestBatchSharesRoundTrips(t *testing.T) {
	src := chain(40, 10)
	objs := make([]string, 0, 30)
	for i := 0; i < 30; i++ {
		objs = append(objs, fmt.Sprintf("page:%d", i))
	}
	check(t, pageModel, src, "read", "alice", objs...)
	if got := len(src.calls); got > 20 {
		t.Fatalf("%d Source calls for a 30-object batch over one chain; want about one per level", got)
	}
}

// C4: A -> B -> A, B also true through C, A evaluated first in one batch.
func TestCycleDoesNotPoisonMemo(t *testing.T) {
	lines := []string{
		"page:a parent page:b", "page:b parent page:a", "page:b parent page:c", "page:c owner user:alice",
	}
	for _, doc := range []string{pageModel, parentFirstModel} {
		ds := check(t, doc, newMem(lines...), "read", "alice", "page:a", "page:b", "page:a", "page:b")
		for i, d := range ds {
			if !d.Allowed {
				t.Fatalf("model %.20s: check %d of %s is %+v, want allowed", doc, i, d.Object, d)
			}
		}
	}
}

func TestPureCycleIsCutNotAClean403(t *testing.T) {
	d := check(t, pageModel, newMem("page:a parent page:b", "page:b parent page:a"), "read", "alice", "page:a")[0]
	if d.Allowed || !d.Cut {
		t.Fatalf("got %+v, want deny with cut", d)
	}
}

func TestCutBaseUnderExcludeIsDenyWithCut(t *testing.T) {
	d := check(t, pageModel, newMem("page:a parent page:b", "page:b parent page:a"), "view", "alice", "page:a")[0]
	if d.Allowed || !d.Cut {
		t.Fatalf("got %+v, want deny with cut", d)
	}
}

func captureLog() (*slog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	return slog.New(slog.NewTextHandler(&buf, nil)), &buf
}

func checkWithLog(t *testing.T, src Source, user, obj string) (Decision, string) {
	t.Helper()
	lg, buf := captureLog()
	ref, _ := ParseRef(obj)
	ev := &Evaluator{Model: mustModel(t, pageModel), Limits: DefaultLimits(), Log: lg}
	ds, err := ev.Check(context.Background(), src, Query{App: "a", UserID: user, Name: "view", Objects: []Ref{ref}})
	if err != nil {
		t.Fatal(err)
	}
	return ds[0], buf.String()
}

func TestMinusHoldingUsersetDeniesAndLogs(t *testing.T) {
	src := newMem("page:1 owner user:alice", "page:1 blocked workspace:w#member")
	d, log := checkWithLog(t, src, "alice", "page:1")
	if d.Allowed || d.Cut || !strings.Contains(log, "minus relation holds a non-user subject") {
		t.Fatalf("got %+v log=%q, want a clean deny and a log line", d, log)
	}
}

// N6: only concrete users reach `blocked`. With none there, the owner reads;
// with user:* there, the evaluator denies everyone, the owner included.
func TestMinusWildcardDeniesEveryoneButAbsentBlockedDoesNot(t *testing.T) {
	none := newMem("page:1 owner user:alice")
	if d := check(t, pageModel, none, "view", "alice", "page:1")[0]; !d.Allowed {
		t.Fatalf("owner with no blocked tuples: %+v", d)
	}
	wild := newMem("page:1 owner user:alice", "page:1 blocked user:*")
	d, log := checkWithLog(t, wild, "alice", "page:1")
	if d.Allowed || !strings.Contains(log, "denying") {
		t.Fatalf("owner with blocked=user:*: %+v log=%q, want deny and a log line", d, log)
	}
}

func TestNodeBudgetIsCut(t *testing.T) {
	ev := &Evaluator{Model: mustModel(t, pageModel), Limits: Limits{MaxDepth: 16, MaxNodes: 5, MaxRows: 1000}}
	d, err := ev.Check(context.Background(), chain(40, 12), Query{App: "a", UserID: "alice", Name: "read", Objects: []Ref{{"page", "0"}}})
	if err != nil || d[0].Allowed || !d[0].Cut {
		t.Fatalf("got %+v err=%v, want deny with cut", d, err)
	}
}

func TestRowBudgetIsCut(t *testing.T) {
	ev := &Evaluator{Model: mustModel(t, pageModel), Limits: Limits{MaxDepth: 16, MaxNodes: 1000, MaxRows: 2}}
	d, err := ev.Check(context.Background(), chain(40, 3), Query{App: "a", UserID: "alice", Name: "read", Objects: []Ref{{"page", "0"}}})
	if err != nil || d[0].Allowed || !d[0].Cut {
		t.Fatalf("got %+v err=%v, want deny with cut", d, err)
	}
}

func TestStoreErrorIsAnErrorNotADeny(t *testing.T) {
	src := newMem("page:1 owner user:alice")
	src.err = fmt.Errorf("connection reset")
	ev := &Evaluator{Model: mustModel(t, pageModel), Limits: DefaultLimits()}
	if _, err := ev.Check(context.Background(), src, Query{UserID: "alice", Name: "read", Objects: []Ref{{"page", "1"}}}); err == nil {
		t.Fatal("a store error must surface as an error")
	}
}

func TestUnknownPermissionIsRejected(t *testing.T) {
	ev := &Evaluator{Model: mustModel(t, pageModel), Limits: DefaultLimits()}
	_, err := ev.Check(context.Background(), newMem(), Query{Name: "nope", Objects: []Ref{{"page", "1"}}})
	if err == nil {
		t.Fatal("want ErrUnknownPermission")
	}
}

func TestAllowShortCircuitsTheLoad(t *testing.T) {
	src := newMem("page:1 owner user:alice")
	check(t, pageModel, src, "read", "alice", "page:1")
	if len(src.calls) != 1 {
		t.Fatalf("an owner is found in one load, got %d", len(src.calls))
	}
}
