/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   admin.ts                                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/03 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/03 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/**
 * Guard for privileged admin surfaces (webhooks / tenants / provision /
 * migrate). These gateway routes are internal-only (ip-restriction + service
 * token); the SDK must send the service-role key as both `apikey` and bearer.
 * Centralizes the "missing key" message so it is not scattered per-client.
 */
export function requireAdminKey(serviceRoleKey: string | undefined, surface: string): string {
  if (!serviceRoleKey) {
    throw new Error(
      `Missing service role key for admin ${surface} operation. ` +
        'Construct the client with { serviceRoleKey } — this surface is internal/server-side only.',
    );
  }
  return serviceRoleKey;
}
