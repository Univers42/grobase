// ============================================================
// Realtime — Grobase agnostic-realtime over WebSocket (/realtime/v1/ws).
// A PostgreSQL LISTEN/NOTIFY producer publishes each row change on topic
// pg/<collection>/<op> (inserted|updated|deleted) with the FULL ROW in
// event.payload.data. Protocol: AUTH → AUTH_OK → SUBSCRIBE → EVENT.
// Cloned from savanna-zoo's client.js subscribe().
// ============================================================
const ENDPOINT = import.meta.env.VITE_BAAS_ENDPOINT ?? '';
const API_KEY = import.meta.env.VITE_BAAS_API_KEY || 'public-anon-key';

const BASE = ENDPOINT || (typeof window !== 'undefined' ? window.location.origin : 'http://localhost:5183');
const OP_TOPIC = { insert: ['inserted'], update: ['updated'], delete: ['deleted'] };

/**
 * Subscribe to live row changes on a collection. Returns an unsubscribe fn.
 * @param {string} collection table name (e.g. 'surf_reports')
 * @param {string} event 'insert' | 'update' | 'delete' | '*'
 * @param {(row:object)=>void} callback invoked with the full changed row
 */
export function subscribe(collection, event, callback) {
  const token = localStorage.getItem('baas_token') || API_KEY;
  const ops = OP_TOPIC[event] || ['inserted', 'updated', 'deleted'];
  const topics = ops.map((op) => `pg/${collection}/${op}`);
  const wsUrl =
    `${BASE.replace(/^http/, 'ws')}/realtime/v1/ws` +
    `?apikey=${encodeURIComponent(API_KEY)}&access_token=${encodeURIComponent(token)}`;

  let ws = null;
  let closed = false;
  let retry = 0;

  function connect() {
    if (closed) return;
    ws = new WebSocket(wsUrl);
    ws.onopen = () => { retry = 0; ws.send(JSON.stringify({ type: 'AUTH', token })); };
    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      if (msg.type === 'AUTH_OK') {
        topics.forEach((topic, i) =>
          ws.send(JSON.stringify({ type: 'SUBSCRIBE', sub_id: `${collection}-${i}`, topic })));
      } else if (msg.type === 'EVENT' || msg.type === 'ROW_CHANGED') {
        const row = msg.event?.payload?.data ?? msg.event?.payload ?? msg.payload ?? {};
        try { callback(row); } catch { /* ignore callback errors */ }
      }
    };
    ws.onerror = () => { try { ws.close(); } catch { /* noop */ } };
    ws.onclose = () => {
      if (closed) return;
      retry = Math.min(retry + 1, 6);
      setTimeout(connect, 500 * retry);
    };
  }

  connect();
  return () => { closed = true; if (ws) try { ws.close(); } catch { /* noop */ } };
}

export default { subscribe };
