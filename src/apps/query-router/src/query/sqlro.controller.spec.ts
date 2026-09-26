/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   sqlro.controller.spec.ts                           :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// The repo's jest setup does not ship `@types/jest` — import globals explicitly.
import { describe, expect, it, jest } from '@jest/globals';
import type { VerifiedRequestIdentity } from '@mini-baas/common';
import { SqlRoController } from './sqlro.controller';
import type { SqlRoResult, SqlRoService } from './sqlro.service';

const DB = '11111111-1111-4111-8111-111111111111';

describe('SqlRoController', () => {
  it('scopes the run to the verified identity tenant — never a user-id fallback', async () => {
    const run = jest.fn(
      async (_dbId: string, _tenantId: string, _sql: string): Promise<SqlRoResult> => ({
        rows: [],
        truncated: false,
      }),
    );
    const controller = new SqlRoController({ run } as unknown as SqlRoService);
    const identity: VerifiedRequestIdentity = {
      tenantId: 'tenant-a',
      projectId: 'tenant-a',
      appId: 'api-key',
      userId: 'user-9',
      role: 'authenticated',
      roleNames: [],
      scopes: [],
      authMethod: 'kong-hmac',
    };
    await controller.run(identity, DB, { sql: 'SELECT 1' });
    expect(run).toHaveBeenCalledWith(DB, 'tenant-a', 'SELECT 1');
  });
});
