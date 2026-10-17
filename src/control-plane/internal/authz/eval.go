package authz

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
)

// ErrRowBudget is returned by a Source that would exceed the row budget.
var ErrRowBudget = errors.New("authz row budget exceeded")

// ErrUnknownPermission reports a check against a type or name the model lacks.
var ErrUnknownPermission = errors.New("unknown permission")

// Limits bound one request. Caveat: every limit turns an answer into CUT (deny
// with cut=true), so a legitimately deep or wide graph is refused, never
// guessed. Raise them per deployment only after measuring (m232).
type Limits struct {
	MaxDepth int // node levels along one path; the 17th is CUT
	MaxNodes int // node expansions per request, memo hits excluded
	MaxRows  int // tuples loaded per request
}

// DefaultLimits are the contract values: depth 16, budgets sized for a
// 1000-object batch over a 10-level tree.
func DefaultLimits() Limits { return Limits{MaxDepth: 16, MaxNodes: 200_000, MaxRows: 200_000} }

// Query asks whether user UserID holds permission or relation Name on each object.
type Query struct {
	App     string
	UserID  string
	Name    string
	Objects []Ref
}

// Decision is the answer for one object. Allowed=false with Cut=true means a
// limit was hit on the way: deny, but not a real "no".
type Decision struct {
	Object  Ref
	Allowed bool
	Cut     bool
}

// Evaluator evaluates a model against a Source. It holds no per-request state.
type Evaluator struct {
	Model  *Model
	Limits Limits
	Log    *slog.Logger
}

type nodeKey struct{ typ, id, name string }

// run is the state of one Check call.
type run struct {
	ev        *Evaluator
	q         Query
	idx       *tupleIndex
	memo      map[nodeKey]outcome
	pending   map[nodeKey]outcome // this pass only; see node
	path      map[nodeKey]struct{}
	wants     map[Want]struct{}
	nodes     int
	exhausted bool
}

// maxPasses bounds the prefetch loop; each pass resolves at least one level.
func (l Limits) maxPasses() int { return l.MaxDepth + 2 }

// Check answers q. It loops: evaluate with what is loaded, load what the pass
// found missing (one Source call per pass, shared by every object of the
// batch), and evaluate again until nothing is pending. Memoized results carry
// over because they were computed from fully loaded data.
// Caveat: round trips = levels of the deepest unresolved path (at most
// MaxDepth+1); a union short-circuits on ALLOW, so a shallow grant loads less.
func (e *Evaluator) Check(ctx context.Context, src Source, q Query) ([]Decision, error) {
	if err := e.validateQuery(q); err != nil {
		return nil, err
	}
	n := len(q.Objects)
	r := &run{
		ev: e, q: q, idx: newTupleIndex(n), memo: make(map[nodeKey]outcome, 4*n), pending: make(map[nodeKey]outcome, 4*n),
		path: map[nodeKey]struct{}{}, wants: make(map[Want]struct{}, 4*n),
	}
	for pass := 0; ; pass++ {
		outs := r.evalAll()
		if len(r.wants) == 0 || r.exhausted || pass >= e.Limits.maxPasses() {
			return r.decisions(outs), nil
		}
		if err := r.load(ctx, src); err != nil {
			return nil, err
		}
	}
}

func (e *Evaluator) validateQuery(q Query) error {
	for _, o := range q.Objects {
		if _, ok := e.Model.lookup(o.Type, q.Name); !ok {
			return fmt.Errorf("%w: %q on type %q", ErrUnknownPermission, q.Name, o.Type)
		}
	}
	return nil
}

func (r *run) evalAll() []outcome {
	outs := make([]outcome, len(r.q.Objects))
	clear(r.pending)
	for i, o := range r.q.Objects {
		outs[i] = r.node(nodeKey{o.Type, o.ID, r.q.Name}, 1)
	}
	return outs
}

// load fetches every pending want in one Source call. Exceeding the row budget
// is not an error: it exhausts the request, so every unresolved node is CUT.
func (r *run) load(ctx context.Context, src Source) error {
	wants := r.sortedWants()
	rows, err := src.Load(ctx, wants, r.ev.Limits.MaxRows-r.idx.rows)
	switch {
	case errors.Is(err, ErrRowBudget):
		r.exhausted = true
		r.idx.add(wants, nil)
	case err != nil:
		return err
	default:
		r.idx.add(wants, rows)
	}
	r.wants = map[Want]struct{}{}
	return nil
}

func (r *run) sortedWants() []Want {
	out := make([]Want, 0, len(r.wants))
	for w := range r.wants {
		out = append(out, w)
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if a.ObjType != b.ObjType {
			return a.ObjType < b.ObjType
		}
		if a.ObjID != b.ObjID {
			return a.ObjID < b.ObjID
		}
		return a.Relation < b.Relation
	})
	return out
}

// decisions maps final outcomes to answers. A pending outcome here means the
// pass cap was hit: CUT, never ALLOW.
func (r *run) decisions(outs []outcome) []Decision {
	ds := make([]Decision, len(outs))
	for i, o := range outs {
		ds[i] = Decision{Object: r.q.Objects[i], Allowed: o.v == vAllow, Cut: o.v != vAllow && (o.v != vDeny || o.cut)}
	}
	return ds
}

// node evaluates one (object, name) pair. Depth is the 1-based node level along
// the current path; a memo hit still answers CUT when the memoized subtree is
// too tall for this depth, so the cap does not depend on batch order.
func (r *run) node(n nodeKey, depth int) outcome {
	if o, ok := r.cached(n); ok {
		if depth-1+o.height > r.ev.Limits.MaxDepth {
			return cutOutcome
		}
		return o
	}
	if _, onPath := r.path[n]; onPath || depth > r.ev.Limits.MaxDepth || r.exhausted {
		return cutOutcome
	}
	if r.nodes++; r.nodes > r.ev.Limits.MaxNodes {
		r.exhausted = true
		return cutOutcome
	}
	expr, ok := r.ev.Model.lookup(n.typ, n.name)
	if !ok {
		return outcome{v: vDeny, height: 1}
	}
	r.path[n] = struct{}{}
	out := r.expr(expr, n, depth)
	delete(r.path, n)
	out.height++
	switch {
	case out.memoizable():
		r.memo[n] = out
	case out.v == vPending:
		r.pending[n] = out
	}
	return out
}

// cached returns a reusable earlier outcome for n. The pending map lives for one
// pass: the loaded data cannot change inside a pass, so a node found pending
// stays pending, and the objects of a batch that share ancestors stop
// re-walking them (500-page batch, evaluation time in Go: 22-28 ms -> 7-8 ms,
// three runs timed around Evaluator.Check on the m232 seed).
// Caveat: a pending outcome drops the cut flag of its siblings, which is safe
// only because pending is never an answer: the next pass recomputes it.
func (r *run) cached(n nodeKey) (outcome, bool) {
	if o, ok := r.memo[n]; ok {
		return o, true
	}
	o, ok := r.pending[n]
	return o, ok
}
