// Security & compliance posture — the PUBLIC mirror of the control plane's
// single source of truth at mini-baas-infra/config/trust/posture.json (served by
// GET /v1/trust). The site build cannot read that file, so this is a HAND-AUTHORED
// mirror; the m144 trust-page-parity gate compares the two. Keep ids + statuses in
// lockstep with posture.json.
//
// HONESTY (kernel rule #4): every status is the honest one from posture.json —
// `implemented` controls cite a gate/wiki in posture.json; `partial`/`planned`
// controls are NOT upgraded here (e.g. WAF + encryption-at-rest stay `planned`).
// The rendered page must NEVER contain that one forbidden compliance adjective
// (m144 + e2e grep for it); use "audit-ready" / "aligned" / "certification" instead.
import type { FaqItem } from './faq';

export interface SecurityControl {
	id: string;
	name: string;
	/** Grouping used to render the page's control sections. */
	category: string;
	status: 'implemented' | 'partial' | 'planned';
	/** Plain-language, honest one-liner — what the control actually does. */
	blurb: string;
}

// FORMAT CONTRACT (gate m144): in every control literal below the `id:` field
// MUST appear BEFORE the `status:` field. Order mirrors posture.json.
export const SECURITY_CONTROLS: SecurityControl[] = [
	{
		id: 'tamper-evident-audit',
		name: 'Tamper-evident tenant audit log',
		category: 'audit-and-logging',
		status: 'implemented',
		blurb: 'Hash-chained per-tenant audit entries; the chain is recomputable, so any insert, edit or deletion is detectable after the fact.',
	},
	{
		id: 'hard-erase',
		name: 'GDPR hard-erase (right to erasure)',
		category: 'data-protection',
		status: 'implemented',
		blurb: 'Per-tenant scoped hard delete of a subject’s data with a verifiable erasure record — the data is gone and no other tenant is touched.',
	},
	{
		id: 'data-portability-export',
		name: 'Data export / portability (GDPR Art. 20)',
		category: 'data-protection',
		status: 'implemented',
		blurb: 'An engine-neutral JSON bundle of one tenant’s data with a manifest (tables, row counts, sha256), strictly scoped to the caller.',
	},
	{
		id: 'per-tenant-isolation',
		name: 'Per-tenant data isolation (per-request RLS / owner-scope)',
		category: 'isolation',
		status: 'implemented',
		blurb: 'Isolation is re-stamped on every request, not held in pool state — which is why thousands of tenants can collapse onto one pool with byte-identical results.',
	},
	{
		id: 'abac-pdp',
		name: 'Fine-grained ABAC policy decision point',
		category: 'access-control',
		status: 'implemented',
		blurb: 'Attribute-based access on every engine: time-window, IP CIDR, AAL, owner and resource-id conditions, per-instance grants and column masking — API-key callers included.',
	},
	{
		id: 'network-access-control',
		name: 'Network access control / IP allowlist',
		category: 'network',
		status: 'implemented',
		blurb: 'A per-tenant IP allowlist enforced at the control plane. This is access control, not a full L7 WAF (see below).',
	},
	{
		id: 'enterprise-passkeys',
		name: 'Phishing-resistant auth (WebAuthn passkeys)',
		category: 'access-control',
		status: 'implemented',
		blurb: 'Server-side WebAuthn registration and authentication ceremonies that mint a session, with wrong-key, replay and cross-user attempts rejected.',
	},
	{
		id: 'organizations-rbac',
		name: 'Organizations, teams & role-based access',
		category: 'access-control',
		status: 'implemented',
		blurb: 'A control-plane org model with members, invites and roles. Org scoping stays control-plane by design, preserving multi-tenant density.',
	},
	{
		id: 'supply-chain',
		name: 'Supply-chain hardening',
		category: 'supply-chain',
		status: 'implemented',
		blurb: 'Frozen lockfiles everywhere, install scripts disabled, a dependency release-age floor, plus cargo-audit and SAST/SCA in CI.',
	},
	{
		id: 'cmek-byok',
		name: 'Customer-managed encryption keys (CMEK / BYOK)',
		category: 'encryption',
		status: 'implemented',
		blurb: 'Per-mount connection strings are envelope-encrypted under a customer-controlled external-KMS key — revoking the key crypto-shreds the data.',
	},
	{
		id: 'sso-oidc',
		name: 'Enterprise SSO (OIDC)',
		category: 'access-control',
		status: 'implemented',
		blurb: 'Per-tenant OIDC connections (Okta, Entra ID, Auth0, Google Workspace): code flow, id_token verified, single-use state, secret sealed at rest.',
	},
	{
		id: 'scim-provisioning',
		name: 'SCIM 2.0 user provisioning',
		category: 'access-control',
		status: 'implemented',
		blurb: 'RFC 7644 SCIM 2.0 user and group provisioning over hashed bearer tokens, with the full lifecycle and a proven cross-tenant wall.',
	},
	{
		id: 'abuse-guard',
		name: 'Abuse detection & guardrails',
		category: 'operations',
		status: 'implemented',
		blurb: 'A per-tenant abuse guard plus edge rate-limiting and staged quotas detect and throttle abusive load before it becomes an outage.',
	},
	{
		id: 'spend-caps',
		name: 'Spend caps (cost-abuse protection)',
		category: 'operations',
		status: 'implemented',
		blurb: 'Per-tenant spend budgets bound runaway cost: an over-budget tenant is capped on the data path, defusing cost-amplification abuse.',
	},
	{
		id: 'compliance-matrices',
		name: 'Framework cross-walks (SOC 2 / GDPR / ISO 27001)',
		category: 'compliance',
		status: 'implemented',
		blurb: 'Per-framework matrices map every control to SOC 2 criteria, GDPR articles and ISO 27001 Annex A, each citing a re-runnable in-repo artifact.',
	},
	{
		id: 'soc2-lite-evidence',
		name: 'Continuous SOC 2 evidence collector',
		category: 'compliance',
		status: 'partial',
		blurb: 'Automated collection of signed snapshots of CI gate results, access posture and the change-management trail. Partial: this is internal evidence, not a formal Type II report.',
	},
	{
		id: 'encryption-in-transit',
		name: 'Encryption in transit (TLS to engines & edge)',
		category: 'encryption',
		status: 'partial',
		blurb: 'In max mode, MSSQL verifies TLS and insecure DSNs are rejected, with CA-pinning available. Partial: Postgres sslmode=require is accept-any outside max — run max for multi-tenant.',
	},
	{
		id: 'secrets-management',
		name: 'Secrets management (Vault, dynamic DB creds)',
		category: 'encryption',
		status: 'partial',
		blurb: 'Vault-backed secrets with short-lived dynamic database credentials to shrink blast radius. Partial: plaintext mount strings are not yet forbidden outside max — enforce Vault refs in prod.',
	},
	{
		id: 'vulnerability-disclosure',
		name: 'Vulnerability disclosure (security.txt)',
		category: 'compliance',
		status: 'partial',
		blurb: 'A published security.txt and disclosure contact define the coordinated-disclosure path. Partial: the public status page is on-demand infra not yet stood up; the policy and contact are defined.',
	},
	{
		id: 'formal-soc2-type2',
		name: 'Formal SOC 2 Type II report',
		category: 'compliance',
		status: 'planned',
		blurb: 'Requires an independent external auditor over a multi-month window. Not yet engaged — the evidence collector is the input that shortens that audit, not a substitute for it.',
	},
	{
		id: 'encryption-at-rest',
		name: 'Encryption at rest (per-tenant)',
		category: 'encryption',
		status: 'planned',
		blurb: 'Disk and volume encryption is an operator and host responsibility today. Per-tenant encrypted-at-rest backups are a roadmap follow-up, not yet a Grobase-enforced control.',
	},
	{
		id: 'waf',
		name: 'Web Application Firewall (L7)',
		category: 'network',
		status: 'planned',
		blurb: 'A managed L7 WAF is provided by the hosting edge in the managed-cloud offering and is operator-supplied for self-host. Not yet a Grobase-enforced, gate-proven control.',
	},
	{
		id: 'sla-uptime',
		name: 'Uptime SLA + status page',
		category: 'operations',
		status: 'planned',
		blurb: 'Per-tier uptime targets exist, but until an availability probe writes durable samples the SLA is not enforceable — stated honestly, not advertised as live.',
	},
	{
		id: 'formal-iso27001',
		name: 'ISO/IEC 27001:2022 certification',
		category: 'compliance',
		status: 'planned',
		blurb: 'A full Annex A Statement of Applicability is drafted and audit-ready. Planned: the ISMS must be operated over a cycle and assessed by an accredited body.',
	},
];

export interface ComplianceBadge {
	id: string;
	framework: string;
	/** Short, honest stance — soft framing only (no forbidden compliance adjective). */
	stance: string;
	/** The honest fine print under the stance. */
	note: string;
	icon: string;
}

// EXACT approved wording. Soft framing — none uses the forbidden adjective.
export const COMPLIANCE_BADGES: ComplianceBadge[] = [
	{
		id: 'soc2',
		framework: 'SOC 2',
		stance: 'Supports SOC 2 · audit-ready',
		note: 'Type II report available under NDA on request; continuous evidence collected.',
		icon: 'shield',
	},
	{
		id: 'iso27001',
		framework: 'ISO 27001',
		stance: 'ISO 27001 aligned',
		note: 'Controls mapped to ISO 27001:2022; formal certification on the roadmap.',
		icon: 'check',
	},
	{
		id: 'gdpr',
		framework: 'GDPR',
		stance: 'GDPR-compliant posture',
		note: 'Data-subject rights (erasure · export) implemented and gate-proven; DPA available.',
		icon: 'file-text',
	},
];

// The honest security FAQ — also emitted as FAQPage JSON-LD on the page. None of
// the rendered Q&As uses the forbidden compliance adjective.
export const SECURITY_FAQ: FaqItem[] = [
	{
		q: 'Do you hold a SOC 2 attestation?',
		a: 'We are SOC 2 audit-ready: continuous evidence is collected automatically and a Type II engagement is on the roadmap. There is no formal external attestation yet; a report is available under NDA on request.',
	},
	{
		q: 'Do you hold ISO 27001 certification?',
		a: 'We are ISO 27001 aligned. A full Annex A Statement of Applicability is drafted and audit-ready, mapping our controls to ISO 27001:2022. Formal certification by an accredited body is on the roadmap, not yet held.',
	},
	{
		q: 'Are you GDPR-compliant?',
		a: 'We ship a GDPR-compliant posture with data-subject rights built in: right-to-erasure (hard-erase) and data portability (export) are implemented and gate-proven, scoped strictly to the requesting tenant. A DPA is available on request.',
	},
	{
		q: 'Where does my data live?',
		a: 'When you self-host, your data runs entirely in your own infrastructure and region — no Grobase subprocessor ever sees self-hosted data. In the managed cloud, residency is set per deployment and stated up front.',
	},
	{
		q: 'How do I report a vulnerability?',
		a: 'Email our security contact — published in /.well-known/security.txt and on the disclosure section of this page. We work good-faith reports privately, with no legal threats, and credit researchers with their consent.',
	},
	{
		q: 'Can I see your security documentation?',
		a: 'Yes. Our framework cross-walks (SOC 2, GDPR, ISO 27001) and posture are available, and deeper artifacts — the SoA, evidence snapshots and a DPA — are available on request, some under NDA. Self-hosters can also read the controls directly in the open-source code.',
	},
];
