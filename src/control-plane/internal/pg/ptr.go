/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   ptr.go                                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:52:54 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:52:55 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package pg

// DerefStr returns the pointed-to string, or "" when the pointer is nil — the
// safe read of a nullable text column scanned into a *string.
func DerefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
