// FAQ content — rendered as <details> AND emitted as FAQPage JSON-LD.
export interface FaqItem {
	q: string;
	a: string;
}

export const PRICING_FAQ: FaqItem[] = [
	{
		q: 'Why do you publish what each tier costs you to run?',
		a: 'Because the numbers are the product. Every RAM figure is measured live on the real stack (docker stats, reproducible via the footprint artifacts), and the Fly.io math is public rate-card arithmetic. If we hid the floor, you couldn\'t verify the margin — and verifiable claims are the whole brand.',
	},
	{
		q: 'What happens when I outgrow a tier?',
		a: 'You move up — and nothing else changes. Nano, Basic, Essential, Pro and Max run the same codebase and speak the same SDK. Graduating is a deployment decision, not a migration project. That is the core promise: you never have to migrate off Grobase.',
	},
	{
		q: 'Is Free really free?',
		a: 'Nano and Basic are free to self-host, forever — they are open shapes of the same stack. The paid prices are for the managed/supported offering. If you run it yourself, your only bill is your infrastructure (~$2–7/mo on Fly.io, under $2 idle with scale-to-zero).',
	},
	{
		q: 'How can Pro be "$59–99" if it only costs ~$21 to run?',
		a: 'The dedicated-stack cost is the worst case: one tenant carrying a whole stack. A single Pro host amortized across ~50 tenants costs $0.40–1.00 per tenant per month — the markup funds support, SLAs and development. We\'d rather show you that math than pretend it doesn\'t exist.',
	},
	{
		q: 'What do capability masks and rate limits mean in practice?',
		a: 'Each tier carries an explicit capability mask (read, write, upsert, batch, aggregate, transactions, DDL…) and a token-bucket rate limit. Operations outside your tier return an honest 403 capability_gated; bursts beyond your bucket return 429. No silent degradation, no surprise overage bills.',
	},
];

export const COMPARE_FAQ: FaqItem[] = [
	{
		q: 'Is Grobase production-ready?',
		a: 'The chassis is: the Rust data plane serves live traffic, the cutover gates (live traffic + shadow parity + CI) are enforced, and the tiers are measured shapes. Some features are still in flight — Postgres update/delete on the new plane, cost-routed OLAP/OLTP, HA clustering. The roadmap section lists exactly what we won\'t pretend is done.',
	},
	{
		q: 'Why three languages (TypeScript, Go, Rust)?',
		a: 'Each plane gets the language its job needs: TypeScript for fast-changing orchestration, Go for always-up control daemons (7–59 MiB each), Rust for the hot data path (3.3 MiB, 8 ms/req). The result is measurable: the old all-Node hot path needed 127 MiB and 40 ms.',
	},
	{
		q: 'Can I bring my own database?',
		a: 'Yes — that is the tenant_owned isolation model. Register your DSN as a mount (stored AES-256-GCM-encrypted), and your database joins the same /query/v1 API as every other engine, with mount-level access gating.',
	},
	{
		q: 'What does "engine-agnostic" actually mean?',
		a: 'The platform never needs to know the shape of your data. Engines implement a Rust EngineAdapter trait; adding one is a registration line, not a rewrite. One tenant can run Postgres, another MySQL, another their own MongoDB — same API, same SDK, same authorization.',
	},
];
