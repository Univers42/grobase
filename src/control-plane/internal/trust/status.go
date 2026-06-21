/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   status.go                                          :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 05:00:24 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 05:00:26 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package trust

// isAllowedStatus reports whether s is in the closed enum a control's status
// MUST be in. A control outside this set is a malformed manifest (LoadManifest
// rejects it), which keeps the trust page from advertising a garbage/blank
// posture.
func isAllowedStatus(s string) bool {
	switch s {
	case "implemented", "partial", "planned":
		return true
	}
	return false
}
