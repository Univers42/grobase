# Grobase Wiki

The engineering, product, and compliance knowledge base for Grobase. Start here.

> The wiki was reorganized from a flat root into topical sections. If you're
> looking for a page that used to sit at the wiki root, find it under the
> matching section below.

## 🏗 architecture/
Core system design — read the numbered series in order.
- [00 — Overview](architecture/00-overview.md) → [01 — Gap analysis](architecture/01-gap-analysis.md) → [02 — Layer & edition model](architecture/02-layer-edition-model.md) → [03 — Control plane](architecture/03-control-plane.md) → [04 — Data plane](architecture/04-data-plane.md) → [05 — Orchestration & observability](architecture/05-orchestration-observability-roadmap.md) → [06 — Product assessment](architecture/06-product-assessment.md) → [07 — Commercial viability](architecture/07-commercial-viability-report.md)
- [Cloud Edition design](architecture/cloud-edition-design.md)
- **contracts/** — [API versioning](architecture/contracts/api-versioning-policy.md) · [transaction contract](architecture/contracts/txn-contract.md) · [orgs / RBAC](architecture/contracts/orgs-rbac-design.md) · [DynamoDB HTAP engine](architecture/contracts/dynamodb-htap-engine.md) · [engineering capability matrix](architecture/contracts/engineering-capability-matrix.md)

## 🧭 product-plan/
The product-completion plan — see [product-plan/README.md](product-plan/README.md) (read 01 → 09).

## 📘 guides/
Integration & how-to docs — index at [guides/README.md](guides/README.md).
- Docker: [best practices](guides/docker-best-practices.md) · [commands](guides/docker-commands-reference.md) · [container purposes](guides/docker-container-purposes.md) · [slim footprint](guides/docker-slim-footprint.md) · [fast first build](guides/fast-first-build.md)
- Kong: [gateway configuration](guides/kong-gateway-configuration.md) · [auth integration](guides/kong-database-authentication-integration.md)
- [Realtime engine](guides/realtime-engine-guide.md) · [Infrastructure](guides/infrastructure.md) · [MVP schema](guides/mvp-schema-specification.md) · [New services API](guides/new-services.md)
- Migrate from [Firebase](guides/migrate-from-firebase.md) / [Supabase](guides/migrate-from-supabase.md) · [osionos real-data guide](guides/osionos-real-data-guide.md)

## 🔌 integrations/
Cross-product contracts & research: [graph contract](integrations/graph-contract.md) · [odysseus integration](integrations/odysseus-integration.md)

## ⚔️ competitive/
Comparisons & benchmarks: [benchmark report](competitive/competitive-benchmark-report.md) · [parity matrix](competitive/competitive-matrix.md) · [3-way vs PocketBase](competitive/competitive-3way-binocle-vs-pocketbase.md) ([generated data](assets/competitive-3way/report.md)) · [nano vs PocketBase](competitive/nano-vs-pocketbase.md) · vs Supabase ([offer](competitive/grobase-vs-supabase-offer.md), [analysis](competitive/supabase-vs-grobase.md), [comparison](competitive/offer-vs-supabase.md)) · [vs MongoDB Atlas](competitive/offer-vs-mongodb-atlas.md)

## 💰 cost-and-tiers/
[cost analysis](cost-and-tiers/cost-analysis.md) · [cost model](cost-and-tiers/cost-model.md) · [service tiers](cost-and-tiers/service-tiers.md) · [nano edition](cost-and-tiers/nano-edition.md) · [pricing honesty audit](cost-and-tiers/pricing-honesty-audit.md)

## 🚀 go-to-market/
[roadmap to market](go-to-market/roadmap-to-market.md) · [master plan](go-to-market/grobase-master-plan.md) · [marketability](go-to-market/marketability-readiness.md) · [GA-readiness scorecard](go-to-market/ga-readiness-scorecard.md) · [human atoms](go-to-market/go-to-market-human-atoms.md) · [offer sheet v2](go-to-market/offer-sheet-v2.md)

## 🛠 operations/
[runbook](operations/operations-runbook.md) · [scale SLO](operations/scale-slo.md) · [status & SLA](operations/status-sla.md) · [SLA draft](operations/sla-draft.md) · [partner demo runbook](operations/partner-demo-runbook.md) · [share-pools finding](operations/finding-share-pools-default-off.md)

## 🔒 security/
[security audit](security/security-audit.md) · [ASVS control map](security/security-audit-asvs.md) · [residuals runbook](security/security-residuals-runbook.md) · [network controls](security/network-controls.md) · [trust center](security/trust-center.md)

## ✅ compliance/
SOC 2 / GDPR / ISO 27001 pack — see [compliance/README.md](compliance/README.md), the [ISMS security policies](compliance/security-policies/00-index.md), and the [compliance posture](compliance/compliance-posture.md).

## ⚖️ legal/
[Terms of Service](legal/terms-of-service.md) · [Acceptable Use](legal/acceptable-use-policy.md) · [Data Processing Addendum](legal/data-processing-addendum.md) · [Privacy](legal/privacy-policy.md) · [SLA](legal/sla.md) · [Subprocessors](legal/subprocessors.md)

## 🎓 dossier/
French 42 / DWWM school deliverables: [dossier de projet](dossier/dossier-projet.md) · [projet back-end](dossier/projet-back.md) · [Osionos dossier](dossier/osionos-dossier-projet.md)

## 🗄 archive/
Ephemeral / historical snapshots (dated status, completion, blocker, and validation dumps). Kept for provenance; **not** part of the live reading order.
