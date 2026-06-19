// ── DOCS NAV — build the sidebar tree + flat order from the `docs` collection.
//
// One source of truth for the docs information architecture: the content
// collection itself (frontmatter `section` + `order`). The sidebar, breadcrumb,
// prev/next and section landing pages all derive from these helpers, so adding a
// markdown file under src/content/docs/ wires it into navigation automatically —
// no list to maintain by hand.
//
// HONESTY/structure: section display order is fixed below (the reading order a
// newcomer should follow); within a section, pages sort by `order` then title.
import type { CollectionEntry } from 'astro:content';

export type DocEntry = CollectionEntry<'docs'>;

/** A single sidebar link (one doc page). */
export interface DocNavItem {
	title: string;
	/** site path, e.g. /docs/guides/realtime/ */
	href: string;
	/** the collection slug, e.g. guides/realtime */
	slug: string;
	order: number;
}

/** A sidebar group (one frontmatter `section`). */
export interface DocNavSection {
	section: string;
	/** the top folder this section lives under, e.g. "guides" — its index path */
	href: string;
	items: DocNavItem[];
}

// Reading order for the sidebar groups. Sections not listed here fall to the end,
// alphabetically — so a new section still renders, just appended.
const SECTION_ORDER = ['Getting started', 'Guides', 'Self-hosting', 'Security'];

/** Map a collection entry to its public docs URL (trailing slash, like the site). */
export function docHref(slug: string): string {
	return `/docs/${slug}/`;
}

/** The top folder of a slug ("guides/realtime" → "guides"); its section index path. */
export function topFolder(slug: string): string {
	return slug.split('/')[0] ?? '';
}

function sectionRank(section: string): number {
	const i = SECTION_ORDER.indexOf(section);
	return i === -1 ? SECTION_ORDER.length : i;
}

/** Build the grouped, ordered sidebar tree from all docs entries. */
export function buildNav(entries: DocEntry[]): DocNavSection[] {
	const groups = new Map<string, DocNavSection>();

	for (const entry of entries) {
		const section = entry.data.section;
		if (!groups.has(section)) {
			groups.set(section, {
				section,
				href: `/docs/${topFolder(entry.id)}/`,
				items: [],
			});
		}
		groups.get(section)!.items.push({
			title: entry.data.title,
			href: docHref(entry.id),
			slug: entry.id,
			order: entry.data.order,
		});
	}

	const sections = [...groups.values()];
	for (const g of sections) {
		g.items.sort((a, b) => a.order - b.order || a.title.localeCompare(b.title));
	}
	sections.sort(
		(a, b) => sectionRank(a.section) - sectionRank(b.section) || a.section.localeCompare(b.section),
	);
	return sections;
}

/** Flatten the nav into reading order — the basis for prev/next. */
export function flatten(sections: DocNavSection[]): DocNavItem[] {
	return sections.flatMap((s) => s.items);
}

/** prev / next neighbours of `slug` in flat reading order (null at the ends). */
export function neighbours(
	sections: DocNavSection[],
	slug: string,
): { prev: DocNavItem | null; next: DocNavItem | null } {
	const flat = flatten(sections);
	const i = flat.findIndex((d) => d.slug === slug);
	if (i === -1) return { prev: null, next: null };
	return { prev: flat[i - 1] ?? null, next: flat[i + 1] ?? null };
}
