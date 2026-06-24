/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   status_test.go                                     :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:22 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:23 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package trust

import "testing"

// TestIsAllowedStatus_Membership pins the EXACT closed enum a control's status
// must be in (the former allowlist, now a switch): implemented|partial|planned
// are true, anything else — including case variants, the literal "green" the
// LoadManifest reject test uses, and empty — is false. A drift here would let a
// malformed/garbage posture status through.
func TestIsAllowedStatus_Membership(t *testing.T) {
	for _, s := range []string{"implemented", "partial", "planned"} {
		if !isAllowedStatus(s) {
			t.Errorf("isAllowedStatus(%q) = false, want true (status dropped from enum)", s)
		}
	}
	rejected := []string{
		"", "green", "Implemented", "PARTIAL", "Planned", "done",
		"in-progress", "todo", "implemented ", " partial", "complete",
	}
	for _, s := range rejected {
		if isAllowedStatus(s) {
			t.Errorf("isAllowedStatus(%q) = true, want false (status outside the closed enum accepted)", s)
		}
	}
}
