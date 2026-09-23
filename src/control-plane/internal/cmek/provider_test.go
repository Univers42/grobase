/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   provider_test.go                                   :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 23:45:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 23:45:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package cmek

import "testing"

// TestProvidersImplementKMSProvider is the compile-time proof that both KMS
// providers satisfy KMSProvider: the typed blank declarations stop this package's
// tests compiling if either provider's method set drifts from the interface. It
// lives in a test (not a package-level var) so the package declares no global.
func TestProvidersImplementKMSProvider(t *testing.T) {
	var _ KMSProvider = (*VaultTransitProvider)(nil)
	var _ KMSProvider = (*LocalKMSProvider)(nil)
}
