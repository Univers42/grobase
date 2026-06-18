/**
 * Terminal API - Execute shell commands via backend
 */

import { apiRequest } from '../../services/api';
import type { CommandResult } from './types';

export async function executeCommand(command: string): Promise<CommandResult> {
  try {
    const res = await apiRequest('/api/crud/shell', {
      method: 'POST',
      body: { command },
    });
    const data = (res as { data?: CommandResult }).data || res;
    return data as CommandResult;
  } catch (e) {
    return {
      output: e instanceof Error ? e.message : 'Command failed',
      exitCode: 1,
    };
  }
}
