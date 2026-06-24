// Site-wide constants. The single place that knows the product's name.
export const SITE = {
	name: 'Grobase',
	tagline: 'One backend for everything you build.',
	description:
		'Grobase is an open-source backend you self-host: accounts, database, realtime, files, search and functions over any database engine. Start on a 5 MB binary, grow to thousands of customers on one stack, and never rewrite.',
	repoUrl: 'https://github.com/Univers42',
} as const;

export const NAV = [
	{ href: '/', label: 'Product' },
	{ href: '/pricing/', label: 'Pricing' },
	{ href: '/security/', label: 'Security' },
] as const;
