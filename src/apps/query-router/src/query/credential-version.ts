/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   credential-version.ts                              :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

/**
 * The Rust data plane keys its per-mount pool on
 * `tenant/project/mount/engine/credential_ref.version`. A mount whose version
 * never changes keeps ONE pool forever — so a rotated DSN would keep serving
 * from the stale pool on a busy mount. The fix is to forward the mount's
 * revision (adapter-registry's `/connect` reports it: 1 = never rotated) as
 * the credential version, so a rotation forks a fresh pool.
 *
 * `live` is kept for every revision that is not a rotation (absent on an older
 * registry, `null`, 1, 0, negative, non-integer, a string): the version string
 * is then exactly today's, so an unrotated mount keeps its existing pool key
 * and no pool is rebuilt at deploy time.
 */
export function credentialVersionFor(revision: unknown): string {
  if (typeof revision !== 'number' || !Number.isInteger(revision) || revision < 2) {
    return 'live';
  }
  return `r${revision}`;
}
