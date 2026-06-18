# Architecture

Core system design. Read the numbered 00–07 series in order; engine/data contracts live in contracts/.

- [00 — Overview: what the BaaS is and how it is wired](00-overview.md)
- [01 — Gap analysis: what is missing for a true layer-swappable BaaS](01-gap-analysis.md)
- [02 — Layer & edition model: changing layers according to need](02-layer-edition-model.md)
- [03 — Control plane plan (Go): tenancy, provisioning, secrets, gateway](03-control-plane.md)
- [04 — Data plane plan (Rust): capability-aware, isolation-pluggable execution](04-data-plane.md)
- [05 — Orchestration, observability, DX & roadmap](05-orchestration-observability-roadmap.md)
- [06 — Product assessment: is this a *good* BaaS product yet?](06-product-assessment.md)
- [07 — Capability & Commercial Viability Report](07-commercial-viability-report.md)
- [Grobase Cloud Edition + the m94 end-to-end funnel gate (DESIGN)](cloud-edition-design.md)

## contracts/

- [Grobase API versioning & deprecation policy](contracts/api-versioning-policy.md)
- [DynamoDB HTAP Engine — design (8th data-plane adapter)](contracts/dynamodb-htap-engine.md)
- [Grobase Engineering Capability Matrix — the polymorphic substrate, proven](contracts/engineering-capability-matrix.md)
- [Design D1 — Organizations / Teams / Members / Invites / RBAC](contracts/orgs-rbac-design.md)
- [Transaction contract — BaaS `/txn` (single-mount atomic writes)](contracts/txn-contract.md)

---

↑ [Wiki index](../README.md)
