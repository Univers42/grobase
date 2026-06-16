# Grobase Compliance Documentation Pack

> **What this is.** The framework cross-walk layer of the Grobase trust story: per-standard
> control matrices that map every Grobase control to **SOC 2** (Trust Services Criteria),
> **GDPR** (article-by-article), and **ISO/IEC 27001:2022** (Annex A Statement of Applicability),
> plus the supporting risk register, Records of Processing, DPIA template, security policies, and
> the single index a SOC 2 auditor / ISO body / Vanta / Drata can be handed.
>
> **These documents CROSS-WALK; they do not restate status independently.** The status of every
> control is owned upstream (see source-of-truth hierarchy below). A matrix row says *which
> standard clause a control satisfies and how to verify it* — it never invents a new status.

---

## Honesty bar (kernel rule #4 — a claim without an artifact is not on this page)

Grobase is **AUDIT-READY**, never **"certified."** Audit-ready means: the controls *exist*, the
*evidence is in the repo* (a numbered gate `mNN`, a SQL migration, a source path, or a CI job), the
*standards mapping is explicit*, and *a CI gate keeps the mapping honest*. A formal SOC 2 Type 2
report, an ISO/IEC 27001 certificate, or a HIPAA BAA each needs an **external party over a
calendar-bound window** — those are labelled **planned**, never claimed, and the human/$$ atoms are
enumerated in [`auditor-handoff.md`](auditor-handoff.md).

Concretely, this pack obeys:

- **No invented numbers.** No uptime %, RTO, or RPO is asserted as live — uptime is `pending-infra`
  until the C7 uptime probe writes durable samples (`sla-uptime` is **planned** in `posture.json`).
- **Every backticked gate resolves.** A gate cited as `` `m104` `` corresponds to a real
  `mini-baas-infra/scripts/verify/m104-*.sh`. A milestone with no script is written as plain text
  (e.g. "milestone 18", the live-traffic discipline, which is a process not a script).
- **No placeholder / stub markers** (the usual unfinished-work words, or filler text) appear in the
  matrices, SoA, risk register, auditor handoff, or policies — every cell is a real decision. The one
  bracketed fill-me marker is permitted **only** in the two customer-fill templates,
  [`gdpr-ropa.md`](gdpr-ropa.md) and [`dpia-template.md`](dpia-template.md) (fields a controller
  completes for their deployment).

---

## Source-of-truth hierarchy (read top-down; the higher wins on conflict)

1. **`config/trust/posture.json`** — *canonical*. The machine-readable control catalog served at
   `GET /v1/trust`. If anything below disagrees with it, **the JSON is correct** and the doc is drift.
2. **[`../compliance-posture.md`](../compliance-posture.md)** — the human control matrix (ASVS ×
   SOC 2 × GDPR) and the headline honest caveat. Gate-kept by `m141`.
3. **These cross-walk matrices** ([`soc2-tsc-matrix.md`](soc2-tsc-matrix.md),
   [`gdpr-article-matrix.md`](gdpr-article-matrix.md), [`iso27001-soa.md`](iso27001-soa.md)) — the
   per-framework projections of (1) and (2). They add the framework clause mapping; they do not
   add status.

The underlying findings live in [`../security-audit.md`](../security-audit.md) (HIGH/MED/LOW) and
[`../security-audit-asvs.md`](../security-audit-asvs.md) (ASVS + open residuals); both feed
[`risk-register.md`](risk-register.md).

---

## Reading order

| # | Document | For |
|---|---|---|
| 1 | this README | the map + the honesty bar |
| 2 | [`soc2-tsc-matrix.md`](soc2-tsc-matrix.md) | SOC 2 Trust Services Criteria (CC1–CC9 + A/C/PI/P) |
| 3 | [`gdpr-article-matrix.md`](gdpr-article-matrix.md) | GDPR article-by-article + controller/processor split |
| 4 | [`iso27001-soa.md`](iso27001-soa.md) | ISO/IEC 27001:2022 Annex A Statement of Applicability (all 93 controls) |
| 5 | [`risk-register.md`](risk-register.md) | ISO clause 6 + SOC 2 CC3 risk register (seeded from the real residuals) |
| 6 | [`gdpr-ropa.md`](gdpr-ropa.md) | Art. 30 Records of Processing (processor + controller views) |
| 7 | [`dpia-template.md`](dpia-template.md) | Art. 35 DPIA template the controller fills |
| 8 | [`security-policies/00-index.md`](security-policies/00-index.md) | the thin ISMS policy set (counsel/management adopt) |
| 9 | [`auditor-handoff.md`](auditor-handoff.md) | the single index handed to an auditor / ISO body / Vanta / Drata |

---

## The gate that keeps this pack honest

`m143` (`mini-baas-infra/scripts/verify/m143-compliance-matrices.sh`) is this pack's own gate. It
parses these documents and fails if:

- the ISO SoA is missing any Annex A:2022 control token (all 93 must appear, one row each);
- any backticked `mNN` citation does not resolve to a real verify script;
- a placeholder / stub marker (an unfinished-work word or filler text) appears outside the two customer-fill templates;
- a control marked *implemented* in `posture.json` is not cited anywhere in the pack.

A matrix that drifts from `posture.json`, or cites a gate that does not exist, fails the gate — so
the cross-walk cannot rot away from reality. Run it:

```bash
bash mini-baas-infra/scripts/verify/m143-compliance-matrices.sh
```

It is the framework-cross-walk sibling of `m141` (posture matrix) and `m104` (the audit-chain spine).

---

## See also

- [`../compliance-posture.md`](../compliance-posture.md) — the ASVS × SOC 2 × GDPR control matrix
- [`../trust-center.md`](../trust-center.md) — the public, human-readable posture page
- [`../security-audit.md`](../security-audit.md) · [`../security-audit-asvs.md`](../security-audit-asvs.md) — the findings + residuals
- `config/trust/posture.json` — canonical machine-readable posture (`GET /v1/trust`)
