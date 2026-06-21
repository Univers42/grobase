/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   clamp_limits.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:51:45 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:51:46 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package packages

// clampLimits applies min(custom, ceiling) with inherit-on-0 across every limit
// field: a custom 0/absent means "inherit the ceiling" — NEVER "unlimited" — so
// an unset field can never widen the cap.
func clampLimits(custom, ceiling Limits) Limits {
	out := ceiling
	out.RPS = clampU32(custom.RPS, ceiling.RPS)
	out.Burst = clampU32(custom.Burst, ceiling.Burst)
	out.MaxRows = clampMaxRows(custom.MaxRows, ceiling.MaxRows)
	out.Quota = clampQuota(custom.Quota, ceiling.Quota)
	return out
}

// clampPoolPolicy applies min(custom, ceiling) with inherit-on-0 to both fields.
func clampPoolPolicy(custom, ceiling PoolPolicy) PoolPolicy {
	return PoolPolicy{
		MaxConn:   clampInt(custom.MaxConn, ceiling.MaxConn),
		MaxMounts: clampInt(custom.MaxMounts, ceiling.MaxMounts),
	}
}

// clampSecurityMode only allows the mode to become STRICTER: a custom mode whose
// rank is ≥ the ceiling's is honored; a looser (or empty) custom clamps to the
// ceiling's mode.
func clampSecurityMode(custom, ceiling string) string {
	if custom != "" && securityRank(custom) >= securityRank(ceiling) {
		return custom
	}
	return ceiling
}

// clampU32 returns min(custom, ceiling) treating a custom 0 as "inherit ceiling"
// and a ceiling 0 as "unlimited" (so an unbounded ceiling field stays unbounded).
func clampU32(custom, ceiling uint32) uint32 {
	if custom == 0 {
		return ceiling
	}
	if ceiling == 0 {
		return custom
	}
	if custom > ceiling {
		return ceiling
	}
	return custom
}

// clampInt is clampU32 for the int pool-policy fields.
func clampInt(custom, ceiling int) int {
	if custom <= 0 {
		return ceiling
	}
	if ceiling <= 0 {
		return custom
	}
	if custom > ceiling {
		return ceiling
	}
	return custom
}
