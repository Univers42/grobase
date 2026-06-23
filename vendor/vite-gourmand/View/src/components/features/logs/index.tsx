// ponytail: stub for the missing DevBoard QA logs feature — restore real impl if the dev dashboard is needed
export function LogViewer(_props: any) { return null; }
export function useRealLogs() { return { logs: [] as any[], connected: false, clear: () => {} }; }
