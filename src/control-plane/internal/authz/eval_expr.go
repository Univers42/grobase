package authz

import "log/slog"

// expr evaluates one permission expression for the object of n.
func (r *run) expr(e *Expr, n nodeKey, depth int) outcome {
	switch e.Kind {
	case kindRelation:
		return r.direct(n, e.Name, depth)
	case kindPermission:
		return r.node(nodeKey{n.typ, n.id, e.Name}, depth+1)
	case kindFrom:
		return r.follow(n, e, depth)
	case kindUnion:
		return r.union(e, n, depth)
	case kindExclude:
		return r.exclude(e, n, depth)
	}
	return denyOutcome
}

func (r *run) union(e *Expr, n nodeKey, depth int) outcome {
	var u union
	for _, c := range e.Children {
		u.add(r.expr(c, n, depth))
		if u.allow {
			break
		}
	}
	return u.result()
}

// need reports whether w is loaded; if not it is queued for the next pass.
func (r *run) need(w Want) bool {
	if r.idx.isLoaded(w) {
		return true
	}
	r.wants[w] = struct{}{}
	return false
}

// direct answers a relation: the user itself, the wildcard, or a userset the
// user may belong to. Plain-object subjects only matter to `from`.
func (r *run) direct(n nodeKey, rel string, depth int) outcome {
	w := Want{n.typ, n.id, rel}
	if !r.need(w) {
		return pendingOutcome
	}
	var u union
	for _, s := range r.idx.subjects[w] {
		if s.Type == UserType && s.Relation == "" {
			if s.ID == r.q.UserID || s.ID == Wildcard {
				return allowOutcome
			}
			continue
		}
		if s.Relation == "" {
			continue
		}
		u.add(r.node(nodeKey{s.Type, s.ID, s.Relation}, depth+1))
		if u.allow {
			break
		}
	}
	return u.result()
}

// follow is tuple-to-userset: evaluate name on every object the tupleset
// relation points at.
func (r *run) follow(n nodeKey, e *Expr, depth int) outcome {
	w := Want{n.typ, n.id, e.From}
	if !r.need(w) {
		return pendingOutcome
	}
	var u union
	for _, s := range r.idx.subjects[w] {
		if s.Type == UserType || s.Relation != "" {
			continue
		}
		u.add(r.node(nodeKey{s.Type, s.ID, e.Name}, depth+1))
		if u.allow {
			break
		}
	}
	return u.result()
}

type minusState uint8

const (
	minusClear minusState = iota
	minusBlocked
	minusMalformed
	minusPending
)

// exclude is base minus a blocking relation. The result is ALLOW only when the
// base is ALLOW and the user is not blocked; a CUT base is a DENY that keeps
// its cut flag, so the caller can tell it from a clean deny.
func (r *run) exclude(e *Expr, n nodeKey, depth int) outcome {
	m := r.minus(n, e.Minus)
	if m == minusBlocked || m == minusMalformed {
		return outcome{v: vDeny}
	}
	b := r.expr(e.Base, n, depth)
	switch {
	case b.v == vCut:
		return outcome{v: vDeny, cut: true, height: b.height}
	case b.v == vAllow && m == minusPending:
		return outcome{v: vPending, height: b.height}
	}
	return b
}

// minus reads the blocking relation as concrete users only. Caveat: a userset,
// a wildcard or any non-user subject there cannot be answered per user, so the
// whole check is DENY for everyone (owner included) and a warning is logged.
// The mapping (N6) must never put one there; the model validator already
// refuses a minus relation that could hold one.
func (r *run) minus(n nodeKey, rel string) minusState {
	w := Want{n.typ, n.id, rel}
	if !r.need(w) {
		return minusPending
	}
	for _, s := range r.idx.subjects[w] {
		if s.Type != UserType || s.Relation != "" || s.ID == Wildcard {
			r.ev.logger().Warn("authz: minus relation holds a non-user subject; denying",
				"app", r.q.App, "object", n.typ+":"+n.id, "relation", rel)
			return minusMalformed
		}
		if s.ID == r.q.UserID {
			return minusBlocked
		}
	}
	return minusClear
}

func (e *Evaluator) logger() *slog.Logger {
	if e.Log != nil {
		return e.Log
	}
	return slog.Default()
}
