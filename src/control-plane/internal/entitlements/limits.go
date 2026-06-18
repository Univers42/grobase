package entitlements

import "github.com/dlesieur/mini-baas/control-plane/internal/packages"

// applyTo overlays the tenant's narrowed limits onto a packages.Limits in place.
// A nil receiver (absent "limits" in the stored JSON) is a no-op — every field
// keeps the package zero value, which Clamp interprets as "inherit the ceiling".
// Each pointer field distinguishes "absent → inherit" from an explicit value.
func (l *EntitlementLimits) applyTo(out *packages.Limits) {
	if l == nil {
		return
	}
	if l.RPS != nil {
		out.RPS = *l.RPS
	}
	if l.Burst != nil {
		out.Burst = *l.Burst
	}
	if l.MaxRows != nil {
		v := *l.MaxRows
		out.MaxRows = &v
	}
	if l.QueryCount != nil {
		out.Quota = &packages.Quota{QueryCount: *l.QueryCount}
	}
}
