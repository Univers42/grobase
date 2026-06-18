/**
 * useShell - Shell terminal state management
 */

import { useState, useCallback, useRef } from 'react';
import { executeCommand } from './api';
import type { HistoryEntry } from './types';

export function useShell() {
  const [lines, setLines] = useState<string[]>([welcome()]);
  const [input, setInput] = useState('');
  const [history, setHistory] = useState<HistoryEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [cwd, setCwd] = useState('~');
  const historyIdx = useRef(-1);

  const run = useCallback(async () => {
    const cmd = input.trim();
    if (!cmd) return;

    setLines((prev) => [...prev, `${cwd} $ ${cmd}`]);
    setInput('');
    setLoading(true);
    historyIdx.current = -1;

    // Handle built-in commands
    if (cmd === 'clear') {
      setLines([]);
      setLoading(false);
      return;
    }

    const result = await executeCommand(cmd);
    const entry: HistoryEntry = { id: Date.now(), command: cmd, ...result };

    // Update cwd if it was a cd command
    if (cmd.startsWith('cd ') || cmd === 'cd') {
      const pwdResult = await executeCommand('pwd');
      if (pwdResult.exitCode === 0) {
        const newCwd = pwdResult.output.trim().replace(/^\/home\/[^/]+/, '~');
        setCwd(newCwd);
      }
    }

    setLines((prev) => [...prev, result.output]);
    setHistory((prev) => [entry, ...prev].slice(0, 100));
    setLoading(false);
  }, [input, cwd]);

  const navigateHistory = useCallback(
    (dir: 'up' | 'down') => {
      if (history.length === 0) return;
      const newIdx =
        dir === 'up'
          ? Math.min(historyIdx.current + 1, history.length - 1)
          : Math.max(historyIdx.current - 1, -1);
      historyIdx.current = newIdx;
      setInput(newIdx >= 0 ? history[newIdx].command : '');
    },
    [history],
  );

  const clear = useCallback(() => setLines([]), []);

  return { lines, input, loading, cwd, setInput, run, navigateHistory, clear };
}

const welcome = () => `Welcome to Cloud Shell
Type any command - full shell access enabled
`;
