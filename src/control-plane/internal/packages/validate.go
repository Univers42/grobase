package packages

import "fmt"

// ValidateWithin reports the FIRST axis on which custom exceeds ceiling, as a
// clean error a compose-time handler maps to 403 entitlement_exceeds_ceiling. It
// is the friendly pre-write gate; Clamp is the resolve-time backstop. Pure.
//
// "Exceeds" means: an engine not in the ceiling; a capability turned ON the
// ceiling has OFF; an rps/burst/max_rows/quota above the ceiling's positive cap;
// max_conn/max_mounts above the ceiling's positive cap; an addon not in the
// ceiling; a security_mode LOOSER than the ceiling. Turning things OFF/down is
// always within bounds (returns nil).
func ValidateWithin(custom, ceiling Package) error {
	if err := validateList("engine", custom.Engines, ceiling.Engines); err != nil {
		return err
	}
	for _, k := range sortedCapKeys(custom.Capabilities) {
		if custom.Capabilities[k] && !ceiling.Capabilities[k] {
			return fmt.Errorf("capability %q exceeds ceiling (ceiling has it off)", k)
		}
	}
	if err := validateLimits(custom.Limits, ceiling.Limits); err != nil {
		return err
	}
	if over := overInt("max_conn", custom.PoolPolicy.MaxConn, ceiling.PoolPolicy.MaxConn); over != nil {
		return over
	}
	if over := overInt("max_mounts", custom.PoolPolicy.MaxMounts, ceiling.PoolPolicy.MaxMounts); over != nil {
		return over
	}
	if err := validateList("addon", custom.Addons, ceiling.Addons); err != nil {
		return err
	}
	if custom.SecurityMode != "" && securityRank(custom.SecurityMode) < securityRank(ceiling.SecurityMode) {
		return fmt.Errorf("security_mode %q is looser than ceiling %q", custom.SecurityMode, ceiling.SecurityMode)
	}
	return nil
}

// validateList reports the FIRST custom entry (in sorted order, for determinism)
// absent from the ceiling — the engine/addon axes share this membership check.
// `kind` names the axis in the error ("engine" / "addon").
func validateList(kind string, custom, ceiling []string) error {
	allowed := make(map[string]bool, len(ceiling))
	for _, c := range ceiling {
		allowed[c] = true
	}
	for _, c := range sortedStrings(custom) {
		if !allowed[c] {
			return fmt.Errorf("%s %q exceeds ceiling (ceiling %ss: %v)", kind, c, kind, ceiling)
		}
	}
	return nil
}

// validateLimits reports the FIRST limits axis on which custom exceeds a positive
// ceiling cap (rps/burst/max_rows/quota.query.count). A ceiling of 0/nil is
// "unlimited" and a custom 0/nil (inherit) never exceeds.
func validateLimits(custom, ceiling Limits) error {
	if over := overU32("rps", custom.RPS, ceiling.RPS); over != nil {
		return over
	}
	if over := overU32("burst", custom.Burst, ceiling.Burst); over != nil {
		return over
	}
	if custom.MaxRows != nil && ceiling.MaxRows != nil && *custom.MaxRows > *ceiling.MaxRows {
		return fmt.Errorf("max_rows %d exceeds ceiling %d", *custom.MaxRows, *ceiling.MaxRows)
	}
	if custom.Quota != nil && ceiling.Quota != nil &&
		ceiling.Quota.QueryCount != 0 && custom.Quota.QueryCount > ceiling.Quota.QueryCount {
		return fmt.Errorf("quota.query.count %d exceeds ceiling %d",
			custom.Quota.QueryCount, ceiling.Quota.QueryCount)
	}
	return nil
}

// overU32 returns an error iff custom exceeds a POSITIVE ceiling (a ceiling of 0
// is "unlimited", so nothing exceeds it). A custom 0 (inherit) never exceeds.
func overU32(field string, custom, ceiling uint32) error {
	if ceiling != 0 && custom > ceiling {
		return fmt.Errorf("%s %d exceeds ceiling %d", field, custom, ceiling)
	}
	return nil
}

// overInt is overU32 for the int pool-policy fields.
func overInt(field string, custom, ceiling int) error {
	if ceiling > 0 && custom > ceiling {
		return fmt.Errorf("%s %d exceeds ceiling %d", field, custom, ceiling)
	}
	return nil
}
