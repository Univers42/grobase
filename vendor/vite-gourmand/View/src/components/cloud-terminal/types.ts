/**
 * Terminal Types
 */

export interface CommandResult {
  output: string;
  exitCode: number;
}

export interface HistoryEntry {
  id: number;
  command: string;
  output: string;
  exitCode: number;
}
