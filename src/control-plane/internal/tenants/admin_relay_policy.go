package tenants

import (
	"fmt"
	"strings"
)

// D1 enforce precondition 1 (ADR 0023, devil 2026-10-30): the data plane judges the
// key tenant-control signs with, not who reached tenant-control. INTERNAL_SERVICE_TOKEN
// is also held by functions-runtime, so under enforce the relay's service_token arm
// would let it drive /v1/admin/{migrate,rotate} as tenant_control with any inline DSN.
// The relay reads the data plane's own DATA_PLANE_CALLER_POLICY, so one value judges
// both hops.
type CallerPolicy uint8

const (
	CallerPolicyOff CallerPolicy = iota
	CallerPolicyShadow
	CallerPolicyEnforce
)

// adminRelayWouldDeny is the shadow line an operator greps for before enforce.
const adminRelayWouldDeny = "admin relay: would_deny"

func (p CallerPolicy) String() string {
	return [...]string{"off", "shadow", "enforce"}[p]
}

// ParseCallerPolicy matches InboundAuthMode::parse (data-plane inbound_auth.rs): trimmed,
// lower-cased, empty means off. An unknown value is an error so boot refuses it.
func ParseCallerPolicy(raw string) (CallerPolicy, error) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "off":
		return CallerPolicyOff, nil
	case "shadow":
		return CallerPolicyShadow, nil
	case "enforce":
		return CallerPolicyEnforce, nil
	}
	return CallerPolicyOff, fmt.Errorf("DATA_PLANE_CALLER_POLICY=%q: want off, shadow or enforce", raw)
}
