// "What are you building?" — the public-facing entry point. Each use-case maps to
// the edition that fits it, branded with that tier's colour. No competitor framing:
// this is about what YOU make, not how we stack up against anyone. Tier numbers come
// from tiers.ts (the single source of truth); keep the tier ids in sync.
import type { TierId } from './tiers';

export interface UseCase {
	id: string;
	/** the thing the visitor is making */
	building: string;
	/** one plain-language line — no jargon */
	blurb: string;
	/** two concrete, human benefits */
	points: [string, string];
	tier: TierId;
	tierName: string;
	price: string;
	href: string;
}

export const USE_CASES: UseCase[] = [
	{
		id: 'prototype',
		building: 'A landing page or prototype',
		blurb: 'Ship a quick idea today. One tiny file, runs anywhere — even a Raspberry Pi.',
		points: ['A 5 MB binary that starts in milliseconds', 'Free and open-source — nothing to sign up for'],
		tier: 'nano',
		tierName: 'Nano',
		price: 'Free · self-host',
		href: '/pricing/#nano',
	},
	{
		id: 'internal',
		building: 'An internal tool',
		blurb: 'A private app for your team on a $5 box — with per-person access built in.',
		points: ['Each user only sees their own data, by default', 'Cheap to run, nothing to babysit'],
		tier: 'basic',
		tierName: 'Basic',
		price: 'from $9 / mo',
		href: '/pricing/#basic',
	},
	{
		id: 'app',
		building: 'A web or mobile app',
		blurb: "Your app's whole backend — accounts, data, files and live updates — under 1 GB.",
		points: ['Sign-in, database, realtime and storage, built in', 'One simple API your frontend calls directly'],
		tier: 'essential',
		tierName: 'Essential',
		price: 'from $25 / mo',
		href: '/pricing/#essential',
	},
	{
		id: 'saas',
		building: 'A multi-tenant SaaS',
		blurb: 'Serve thousands of customers from one stack — each kept separate, with realtime built in.',
		points: ['Thousands of tenants share one set of servers', 'Realtime, several databases, and isolation you choose'],
		tier: 'pro',
		tierName: 'Pro',
		price: 'from $59 / mo',
		href: '/pricing/#pro',
	},
	{
		id: 'data',
		building: 'A data API over many databases',
		blurb: 'One API in front of Postgres, MySQL, Mongo, Redis and more — plus search and analytics.',
		points: ['8 engines behind one /query API — no rewrites', 'Full-text + vector search, analytics and audit included'],
		tier: 'max',
		tierName: 'Max',
		price: 'from $149 / mo',
		href: '/pricing/#max',
	},
];
