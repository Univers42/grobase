import type { DevLogEntry } from './types';

interface LogViewerProps {
  logs: DevLogEntry[];
  connected: boolean;
  onClear: () => void;
}

export function LogViewer({ logs, connected, onClear }: Readonly<LogViewerProps>) {
  return (
    <section className="devboard-log-viewer" aria-label="Live logs">
      <div className="devboard-log-viewer__toolbar">
        <span>{connected ? 'Connecté' : 'Déconnecté'}</span>
        <button type="button" onClick={onClear}>
          Effacer
        </button>
      </div>
      <div className="devboard-log-viewer__list">
        {logs.length === 0 ? (
          <p>Aucun log disponible.</p>
        ) : (
          logs.map((log, index) => (
            <article key={`${log.timestamp}-${index}`} className="devboard-log-viewer__entry">
              <time dateTime={log.timestamp}>{new Date(log.timestamp).toLocaleTimeString()}</time>
              <strong>{log.level.toUpperCase()}</strong>
              <span>{log.source}</span>
              <p>{log.message}</p>
            </article>
          ))
        )}
      </div>
    </section>
  );
}
