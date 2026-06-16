# Incident Response Policy

> **POLICY — review by counsel/management before formal adoption.** Points to enforced controls.

## Purpose & scope
Define how Grobase prepares for, detects, responds to, and learns from information-security
incidents, including personal-data breaches. (ISO/IEC 27001 Annex A A.5.24–A.5.27; SOC 2 CC7.3–7.5;
GDPR Art. 33–34.)

## Process
1. **Preparation.** Roles, on-call, and the event-reporting channel are defined; the operational
   procedures live in [`../../operations-runbook.md`](../../operations-runbook.md).
2. **Detection & triage.** Observability (Prometheus/Grafana/Loki/Tempo) plus the tamper-evident
   audit log surface anomalies; severity is assigned on triage. Forensic evidence is the
   hash-chained audit chain — enforced: gate `m104`.
3. **Containment, eradication, recovery.** Contain the blast radius (isolation is per-request, so a
   compromised path does not cross tenants — gate `m46`); recover from backups / point-in-time
   restore — gate `m87`, gate `m99`.
4. **Breach notification (GDPR).** Where personal data is affected, the **controller** notifies the
   supervisory authority (Art. 33) and data subjects (Art. 34); as **processor**, Grobase notifies
   affected controllers without undue delay and supplies the forensic record. See
   [`../gdpr-article-matrix.md`](../gdpr-article-matrix.md).
5. **Post-incident learning.** Root-cause and corrective actions feed the risk register
   ([`../risk-register.md`](../risk-register.md)) and the residuals runbook
   ([`../../security-residuals-runbook.md`](../../security-residuals-runbook.md)).

## Pending infra (stated honestly)
Public vulnerability disclosure intake (`security.txt`) and SIEM shipping with cross-tenant-404
anomaly alerting are tracked as open risks (R-DISCLOSE, R-SIEM) — defined, not yet stood up.

## Review
At least annually and after every significant incident.
