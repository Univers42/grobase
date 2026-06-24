// @ts-nocheck
// Grobase marketing site — Astro config.
// CSP pattern borrowed from apps/opposite-osiris/astro.config.mjs: Astro emits a
// per-page <meta> CSP with SHA-256 hashes for every inline script/style it
// generates, so script-src/style-src stay strict ('self' + hashes, NO
// 'unsafe-inline'). scripts/audit/csp-check.mjs proves it in headless Chromium.
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { loadEnv } from 'vite';

const env = loadEnv(process.env.NODE_ENV ?? 'development', process.cwd(), '');

// Astro does NOT inject a CSP during `astro dev`, so the dev server sends an
// HMR-friendly policy itself (unsafe-inline/eval + ws: for Vite live reload).
function devContentSecurityPolicy() {
	return [
		"default-src 'self'",
		"base-uri 'self'",
		"object-src 'none'",
		"form-action 'self'",
		"img-src 'self' data:",
		"media-src 'self'",
		"worker-src 'self'",
		"manifest-src 'self'",
		"font-src 'self'",
		"style-src 'self' 'unsafe-inline'",
		"script-src 'self' 'unsafe-inline' 'unsafe-eval'",
		"connect-src 'self' http://localhost:* ws://localhost:* http://127.0.0.1:* ws://127.0.0.1:*",
	].join('; ');
}

export default defineConfig({
	// Canonical origin for sitemap + <link rel="canonical">. Compose/CI override
	// with PUBLIC_SITE_URL; the default is the future public domain.
	site: env.PUBLIC_SITE_URL ?? 'https://grobase.dev',
	integrations: [sitemap()],
	devToolbar: { enabled: false },
	// Inline all page CSS into <style> tags instead of render-blocking <link>s —
	// Astro's security.csp auto-hashes them so style-src stays strict.
	build: { inlineStylesheets: 'always' },
	// No markdown on this site; the default Shiki highlighter is dead weight and
	// emits inline styles that would trip the CSP. Code samples are plain <pre>.
	markdown: { syntaxHighlight: false },
	security: {
		csp: {
			directives: [
				"default-src 'self'",
				"base-uri 'self'",
				"object-src 'none'",
				// frame-ancestors intentionally absent: browsers ignore it in <meta>
				// CSPs. Clickjacking is enforced at the HTTP layer (docker/default.conf
				// sets X-Frame-Options + a real CSP header in the nginx prod image).
				"form-action 'self'",
				"img-src 'self' data:",
				"media-src 'self'",
				"worker-src 'self'",
				"manifest-src 'self'",
				"font-src 'self'",
				"connect-src 'self'",
				"trusted-types grobase-static",
				"require-trusted-types-for 'script'",
			],
			scriptDirective: { resources: ["'self'"] },
			styleDirective: { resources: ["'self'"] },
		},
	},
	server: {
		host: env.ASTRO_DEV_HOST ?? '0.0.0.0',
		port: Number(env.ASTRO_DEV_PORT ?? 4324),
	},
	vite: {
		server: {
			headers: {
				'Content-Security-Policy': devContentSecurityPolicy(),
				'X-Grobase-CSP-Mode': 'development',
			},
		},
	},
});
