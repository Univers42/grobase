# Independent Grobase status service

Optional standard-library Python service: HTTP synthetic checks, durable SQLite
samples, read-only public page and `/status.json`. No Docker socket, database
credentials, public write endpoint or additional application state tables.

1. Copy `targets.example.json` to `targets.json`; replace placeholders with
   **confirmed** public health URLs and their exact expected status codes.
   Validate them against your gateway configuration. Auth health routes
   may require an API key on some deployments; use a genuinely public
   readiness route instead. Do not mark 401/404 as healthy or expose a key in a
   URL. Targets measure only configured HTTP endpoints; they do not claim SQL
   readiness or WebSocket/message delivery. Add real probes separately for those.
2. Provide `deploy/status/tls/server.crt`, `server.key` and `ca.crt` from your
   certificate manager. Include `localhost` and the proxy's upstream hostname
   in the certificate SANs. Make the key readable only by container UID 65532;
   never commit private keys. Missing/invalid certificates stop startup, with no
   plaintext fallback. Deploy independently, preserving `status-history`:

   ```bash
   docker compose -f deploy/status/compose.yml up --build -d
   ```

3. Serve `https://127.0.0.1:8090` through your TLS reverse proxy at a status hostname.
   Verify the upstream certificate using its CA and matching hostname/SNI; never
   disable certificate verification. The public hostname must also enforce HTTPS.
   Only `/`, `/status.js`, `/status.css`, `/status.json` and `/health/ready` are served. `/health/ready` returns
   503 for down/unknown monitored components; the container healthcheck uses
   `/status.json` to distinguish an alive status server from a backend outage.
4. Set interval, timeout, stale threshold and history retention through the
   documented Compose variables. Defaults: 60s / 5s / 300s / 30 days. Changes
   to target config require a restart. Persist and separately back up the history.

Current state is operational/down/unknown per component; overall is
operational/degraded/unknown. Missing and stale samples never become uptime.
The page exposes last-check time, successful/total sampled checks and the most
recent 50 failed observations per component within the retained window, **not**
time-weighted uptime, confirmed incidents or a contractual SLA percentage.
Probe interruptions are missing measurements. Renaming a component starts a
new history. Target addresses, response bodies and exception details are never
published. Disk write failures leave samples stale; database read failures return
503/unknown. Restarted instances read the same durable history.

A status service on the failed backend host cannot report that host's outage.
Deploy independently and externally monitor the status service itself.

Tests: `make reliability-test`. Backup/recovery operations:
[disaster recovery](../../wiki/operations/disaster-recovery.md).
