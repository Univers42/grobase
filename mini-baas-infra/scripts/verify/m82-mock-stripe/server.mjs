// Minimal zero-dep mock of the Stripe Meter Events API for the m82 gate.
// Records every POST /v1/billing/meter_events (form-encoded) in memory and serves
// the recorded list at GET /_events so the gate can assert — off the wire — that
// the billing reporter sent EXACTLY the right meter events (right customer, value,
// event_name, identifier) and is idempotent on re-tick. It deliberately does NOT
// implement Stripe's own identifier-dedup: the gate proves idempotency comes from
// the reporter's local sent-ledger (billing_reported), not from Stripe.
import http from 'node:http';

const events = [];

function parseForm(body) {
  const p = new URLSearchParams(body);
  const o = {};
  for (const [k, v] of p) o[k] = v;
  return o;
}

const srv = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url.startsWith('/v1/billing/meter_events')) {
    let b = '';
    req.on('data', (c) => (b += c));
    req.on('end', () => {
      const f = parseForm(b);
      events.push({
        event_name: f['event_name'] || '',
        customer: f['payload[stripe_customer_id]'] || '',
        value: f['payload[value]'] || '',
        identifier: f['identifier'] || '',
        timestamp: f['timestamp'] || '',
      });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ object: 'billing.meter_event' }));
    });
    return;
  }
  if (req.method === 'GET' && req.url.startsWith('/_events')) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ count: events.length, events }));
    return;
  }
  if (req.method === 'GET' && req.url.startsWith('/_health')) {
    res.writeHead(200);
    res.end('ok');
    return;
  }
  res.writeHead(404);
  res.end('nope');
});

const port = Number(process.env.PORT || 8080);
srv.listen(port, () => console.log('mock-stripe listening on ' + port));
