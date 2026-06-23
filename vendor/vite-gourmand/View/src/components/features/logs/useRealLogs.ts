import { useCallback, useEffect, useState } from 'react';
import { apiRequest } from '../../../services/api';
import type { DevLogEntry } from './types';

interface LogsResponse {
  success?: boolean;
  data?: DevLogEntry[];
}

export function useRealLogs() {
  const [logs, setLogs] = useState<DevLogEntry[]>([]);
  const [connected, setConnected] = useState(false);

  const clear = useCallback(() => {
    setLogs([]);
    void apiRequest('/api/logs', { method: 'DELETE' }).catch(() => undefined);
  }, []);

  useEffect(() => {
    let closed = false;

    void apiRequest<LogsResponse | DevLogEntry[]>('/api/logs?limit=100')
      .then((response) => {
        if (closed) return;
        setLogs(Array.isArray(response) ? response : (response.data ?? []));
      })
      .catch(() => undefined);

    // ponytail: no live log-stream on Grobase — the NestJS `/api/logs/stream` SSE
    //   endpoint doesn't exist, so the panel shows the snapshot fetch only (no
    //   EventSource → no text/html MIME error). Wire a realtime mount if needed.
    return () => {
      closed = true;
      setConnected(false);
    };
  }, []);

  return { logs, connected, clear };
}
