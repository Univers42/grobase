// Astro 5+/6 content layer config (glob loaders). Two collections back the
// /docs and /blog sections; pages query them via getCollection('docs'|'blog').
// Markdown is plain (astro.config sets syntaxHighlight: false) so no inline
// styles leak into the strict CSP. Keep at least one entry per collection so the
// build stays valid (see the placeholder files created alongside this config).
import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// Documentation: sectioned, ordered reference + guide pages.
const docs = defineCollection({
	loader: glob({ pattern: '**/*.md', base: './src/content/docs' }),
	schema: z.object({
		title: z.string(),
		description: z.string(),
		/** which docs section this page belongs to (e.g. "Getting started") */
		section: z.string(),
		/** sort order within the section */
		order: z.number(),
	}),
});

// Blog: dated posts with an author and optional tags.
const blog = defineCollection({
	loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
	schema: z.object({
		title: z.string(),
		description: z.string(),
		date: z.coerce.date(),
		author: z.string(),
		tags: z.array(z.string()).optional(),
	}),
});

export const collections = { docs, blog };
