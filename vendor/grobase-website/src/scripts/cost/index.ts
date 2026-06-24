// Cost simulator — CSP-safe live recompute of "what an offer costs us, and why".
//
// PROGRESSIVE ENHANCEMENT: CostSimulator.astro renders the WHOLE calculator —
// the component-breakdown table, the per-tenant RAM math, the infra-cost lines,
// price + margin — as static server HTML for the DEFAULT selection (Pro on
// Fly.io, amortized). With no JS the page is still a complete, accessible,
// auditable cost sheet. This module only RECOMPUTES those values when the user
// changes an input, writing through `textContent` / `classList` / `dataset` /
// `style.setProperty` only — NEVER innerHTML / insertAdjacentHTML / eval, so it
// passes the strict CSP (trusted-types: require-trusted-types-for 'script').
//
// The cost data is a small JSON island the component emits (Astro hashes it
// under style/script-src 'self'); JSON.parse is not an HTML sink, so it is
// trusted-types-safe. The cost MATH below is the exact mirror of the pure
// functions in src/data/cost-model.ts — the numbers shown are the numbers gated.

export {};

// ── Shapes (mirror of the JSON island the component serializes) ───────────────
interface Comp {
	name: string;
	plane: string;
	mib: number;
	kind: 'measured' | 'mem_limit';
}
interface TierData {
	id: string;
	name: string;
	rps: number;
	editionRamIdleMib: number;
	componentRamSumMib: number;
	itemisedSumMib: number;
	comps: Comp[];
	tpnValue: number;
	tpnNodeRamGb: number;
	tpnBinding: string;
	nodeCost: Record<string, number>;
	storageDefault: number;
	egressDefault: number;
}
interface HosterData {
	id: string;
	name: string;
	isFly: boolean;
	ramGb: number;
	vcpu: number;
	flatMonthlyUsd: number;
	usdPerGbRam: number;
	usdPerVcpu: number;
	usdPerGbStorage: number;
	usdPerGbEgress: number;
}
interface Island {
	asOf: string;
	density: { perTenantMarginalMib: number; perTenantUnderloadMib: number };
	factors: {
		headroomPct: number;
		defaultMarginPct: number;
		concurrencyPeakFraction: number;
		rpsSinglePoolCeiling: number;
	};
	tiers: TierData[];
	hosters: HosterData[];
}

// ── Pure cost math — byte-identical to cost-model.ts (kept in sync; the m145
// gate guards the data, these helpers mirror its formulas). ───────────────────
// node_monthly = the canonical per-(tier × hoster) node cost (the gate-guarded
// infra_cost_usd_month constant), keyed by hoster id. Node RAM is not a tunable
// input here, so there is no override path — this returns the exact constant.
function nodeMonthly(t: TierData, h: HosterData): number {
	return t.nodeCost[h.id] ?? 0;
}
function tenantsPerNodeRps(rps: number, f: Island['factors']): number {
	return Math.floor(rps > 0 ? f.rpsSinglePoolCeiling / rps / f.concurrencyPeakFraction : 0);
}
function tenantsPerNodeRam(editionMib: number, nodeRamGb: number, perTenant: number, f: Island['factors']): number {
	const avail = nodeRamGb * 1024 * (1 - f.headroomPct) - editionMib;
	return avail <= 0 ? 0 : Math.floor(avail / perTenant);
}
// For max (the only multi-tenant tier) rps does NOT bind — the cap is the PROVEN
// 10,000-tenant validation, bounded by the (far larger) at-rest RAM ceiling. For
// the single-tenant tiers the binding constraint is min(rps, RAM). Mirrors
// cost-model.ts.tenantsPerNode exactly.
function tenantsPerNode(t: TierData, nodeRamGb: number, island: Island): number {
	const byRam = tenantsPerNodeRam(t.editionRamIdleMib, nodeRamGb, island.density.perTenantMarginalMib, island.factors);
	if (t.id === 'max') return Math.min(10000, byRam);
	return Math.min(tenantsPerNodeRps(t.rps, island.factors), byRam);
}

// ── Formatting helpers ────────────────────────────────────────────────────────
function usd(v: number): string {
	if (v === 0) return '$0';
	if (v < 0.01) return `$${v.toFixed(4)}`;
	if (v < 1) return `$${v.toFixed(3)}`;
	return `$${v.toFixed(2)}`;
}
function mib(v: number): string {
	return v >= 1024 ? `${(v / 1024).toFixed(2)} GiB` : `${v.toFixed(v < 10 ? 3 : 1)} MiB`;
}
function intc(v: number): string {
	return v.toLocaleString('en-US');
}

// ── DOM wiring ────────────────────────────────────────────────────────────────
function readIsland(root: HTMLElement): Island | null {
	const tag = root.querySelector<HTMLScriptElement>('[data-cost-island]');
	if (!tag || !tag.textContent) return null;
	try {
		return JSON.parse(tag.textContent) as Island;
	} catch {
		return null;
	}
}

function setText(root: HTMLElement, key: string, value: string): void {
	const el = root.querySelector<HTMLElement>(`[data-out="${key}"]`);
	if (el) el.textContent = value;
}

function clampNum(v: number, lo: number, hi: number): number {
	if (Number.isNaN(v)) return lo;
	if (v < lo) return lo;
	if (v > hi) return hi;
	return v;
}

function readNum(root: HTMLElement, name: string, fallback: number): number {
	const el = root.querySelector<HTMLInputElement>(`[data-input="${name}"]`);
	if (!el) return fallback;
	const v = Number(el.value);
	return Number.isFinite(v) ? v : fallback;
}

function readRadio(root: HTMLElement, name: string, fallback: string): string {
	const el = root.querySelector<HTMLInputElement>(`input[name="${name}"]:checked`);
	return el ? el.value : fallback;
}

interface State {
	tier: TierData;
	hoster: HosterData;
	model: 'dedicated' | 'amortized';
	nodeRamGb: number;
	vcpu: number;
	storageGb: number;
	egressGb: number;
}

function gather(root: HTMLElement, island: Island): State {
	const tierId = readRadio(root, 'sim-tier', 'pro');
	const hosterId = readRadio(root, 'sim-hoster', 'Fly.io');
	const tier = island.tiers.find((t) => t.id === tierId) ?? island.tiers[0];
	const hoster = island.hosters.find((h) => h.id === hosterId) ?? island.hosters[0];
	const model = (readRadio(root, 'sim-model', 'amortized') === 'dedicated' ? 'dedicated' : 'amortized') as State['model'];
	// Storage/egress sliders default to the tier defaults; when the tier changes
	// and a slider still holds the previous tier's default, snap it forward.
	const storageGb = clampNum(readNum(root, 'storage', tier.storageDefault), 0, 200);
	const egressGb = clampNum(readNum(root, 'egress', tier.egressDefault), 0, 500);
	return { tier, hoster, model, nodeRamGb: tier.tpnNodeRamGb, vcpu: Math.max(1, hoster.vcpu), storageGb, egressGb };
}

// Toggle the per-tier component rows + explainer + tenancy line.
function showTierContext(root: HTMLElement, tier: TierData): void {
	root.querySelectorAll<HTMLElement>('[data-tier-block]').forEach((el) => {
		const on = el.getAttribute('data-tier-block') === tier.id;
		el.hidden = !on;
	});
	// Drive the accent custom-property so the whole panel tints to the tier.
	root.style.setProperty('--sim-tier', `var(--gb-tier-${tier.id})`);
	root.setAttribute('data-active-tier', tier.id);
}

function recompute(root: HTMLElement, island: Island): void {
	const s = gather(root, island);
	showTierContext(root, s.tier);

	const f = island.factors;
	const node = nodeMonthly(s.tier, s.hoster);
	const storage = s.storageGb * s.hoster.usdPerGbStorage;
	const egress = s.egressGb * s.hoster.usdPerGbEgress;
	const tpn = tenantsPerNode(s.tier, s.nodeRamGb, island);
	const denom = s.model === 'amortized' && tpn > 0 ? tpn : 1;
	const nodeShare = node / denom;
	const infra = nodeShare + storage + egress;
	const price = s.tier.id === 'nano' ? 0 : infra / (1 - f.defaultMarginPct);
	const margin = price > 0 ? (price - infra) / price : 0;

	// per-tenant RAM math — both regimes, shown with their honest captions.
	const tenantsForMath = s.model === 'amortized' ? tpn : 1;
	const atRest = s.tier.componentRamSumMib + tenantsForMath * island.density.perTenantMarginalMib;
	const underLoad = s.tier.componentRamSumMib + tenantsForMath * f.concurrencyPeakFraction * island.density.perTenantUnderloadMib;

	// Outputs. comp-sum is the HONEST arithmetic sum of the itemised rows (NOT the
	// measured edition floor — those are shown as two distinct rows in the table).
	setText(root, 'comp-sum', mib(s.tier.itemisedSumMib));
	setText(root, 'edition-floor', mib(s.tier.editionRamIdleMib));
	setText(root, 'node-ram', `${s.nodeRamGb} GB`);
	setText(root, 'tpn', s.model === 'dedicated' ? '1 (dedicated)' : intc(tpn));
	setText(root, 'tpn-binding', s.tier.tpnBinding);
	setText(root, 'ram-atrest', mib(atRest));
	setText(root, 'ram-underload', mib(underLoad));
	setText(root, 'tenants-for-math', s.model === 'amortized' ? intc(tenantsForMath) : '1');

	setText(root, 'node-monthly', usd(node));
	setText(root, 'node-share', usd(nodeShare));
	setText(root, 'storage-cost', usd(storage));
	setText(root, 'egress-cost', usd(egress));
	setText(root, 'infra-cost', usd(infra));
	setText(root, 'price', s.tier.id === 'nano' ? '$0 (free tier)' : usd(price));
	setText(root, 'margin', s.tier.id === 'nano' ? '0% (by design)' : `${Math.round(margin * 100)}%`);

	// Echo the live formula strings (textContent, never HTML). Fly is a true
	// per-GB add-on so we show the arithmetic; Hetzner/AWS use the node-class
	// allocation (the gate-guarded constant).
	setText(root, 'f-node', s.hoster.isFly
		? `${s.nodeRamGb} GB × ${usd(s.hoster.usdPerGbRam)} + ${s.vcpu} vCPU × ${usd(s.hoster.usdPerVcpu)} = ${usd(node)}`
		: `${s.hoster.id} ${s.nodeRamGb} GB-class node = ${usd(node)}`);
	setText(root, 'f-share', s.model === 'amortized'
		? `${usd(node)} ÷ ${intc(denom)} tenants = ${usd(nodeShare)} / tenant`
		: `${usd(node)} (whole node, one app)`);
	setText(root, 'f-storage', `${s.storageGb} GB × ${usd(s.hoster.usdPerGbStorage)}/GB = ${usd(storage)}`);
	setText(root, 'f-egress', `${s.egressGb} GB × ${usd(s.hoster.usdPerGbEgress)}/GB = ${usd(egress)}`);
	setText(root, 'f-price', s.tier.id === 'nano'
		? 'free tier — price 0, margin 0 by product design'
		: `${usd(infra)} ÷ (1 − ${f.defaultMarginPct}) = ${usd(price)}`);

	// Bound-constraint badge + hoster note class for styling.
	const tpnEl = root.querySelector<HTMLElement>('[data-out="tpn"]');
	if (tpnEl) tpnEl.setAttribute('data-binding', s.tier.tpnBinding);

	// Update slider value read-outs.
	setText(root, 'storage-val', `${s.storageGb} GB`);
	setText(root, 'egress-val', `${s.egressGb} GB`);

	// Test-only telemetry: confirms a live recompute happened. Decorative global.
	(window as unknown as Record<string, unknown>).__costSim = {
		tier: s.tier.id,
		hoster: s.hoster.id,
		model: s.model,
		infraCost: Number(infra.toFixed(4)),
		price: Number(price.toFixed(4)),
		tenantsPerNode: tpn,
	};
}

function snapSlidersToTier(root: HTMLElement, island: Island): void {
	// When the tier changes, reset the usage sliders to that tier's defaults so
	// the storage/egress knobs always start at the honest per-tier baseline.
	const tierId = readRadio(root, 'sim-tier', 'pro');
	const tier = island.tiers.find((t) => t.id === tierId);
	if (!tier) return;
	const storage = root.querySelector<HTMLInputElement>('[data-input="storage"]');
	const egress = root.querySelector<HTMLInputElement>('[data-input="egress"]');
	if (storage) storage.value = String(tier.storageDefault);
	if (egress) egress.value = String(tier.egressDefault);
}

function init(): void {
	const root = document.querySelector<HTMLElement>('[data-cost-simulator]');
	if (!root) return;
	const island = readIsland(root);
	if (!island) return;

	root.addEventListener('change', (e) => {
		const target = e.target as HTMLElement | null;
		if (target && target.getAttribute('name') === 'sim-tier') snapSlidersToTier(root, island);
		recompute(root, island);
	});
	root.addEventListener('input', () => recompute(root, island));

	// First paint: recompute from the default selection so the live values match
	// the server-rendered ones (and JS-on telemetry is available immediately).
	recompute(root, island);
	root.setAttribute('data-cost-ready', '');
}

if (document.querySelector('[data-cost-simulator]')) {
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init, { once: true });
	} else {
		init();
	}
}
