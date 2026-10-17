package authz

// verdict is the tri-state answer, plus pending: "the data to answer is not
// loaded yet". Pending never leaves a request; the prefetch loop resolves it.
type verdict uint8

const (
	vDeny verdict = iota
	vAllow
	vCut
	vPending
)

// outcome carries a verdict, whether a CUT occurred anywhere in the subtree
// that produced it (cut), and how many node levels that subtree spans (height).
// Caveat: cut marks a deny that may be wrong only because a limit was hit, so
// the handler can answer 503 instead of a plain 403; a clean deny has cut=false.
type outcome struct {
	v      verdict
	cut    bool
	height int
}

var (
	denyOutcome    = outcome{v: vDeny}
	cutOutcome     = outcome{v: vCut, cut: true}
	pendingOutcome = outcome{v: vPending}
	allowOutcome   = outcome{v: vAllow}
)

// memoizable reports whether the outcome is final and was reached with no cut
// below it: only those are safe to reuse for another path.
func (o outcome) memoizable() bool {
	return (o.v == vAllow || o.v == vDeny) && !o.cut
}

// union folds branch outcomes: ALLOW wins; else PENDING (data still to load);
// else CUT; else DENY.
type union struct {
	allow, pending, sawCut, taint bool
	height                        int
}

func (u *union) add(o outcome) {
	switch o.v {
	case vAllow:
		u.allow = true
	case vPending:
		u.pending = true
	case vCut:
		u.sawCut = true
	}
	u.taint = u.taint || o.cut
	u.height = max(u.height, o.height)
}

func (u *union) result() outcome {
	switch {
	case u.allow:
		return outcome{v: vAllow, cut: u.taint, height: u.height}
	case u.pending:
		return outcome{v: vPending, height: u.height}
	case u.sawCut:
		return outcome{v: vCut, cut: true, height: u.height}
	}
	return outcome{v: vDeny, cut: u.taint, height: u.height}
}
