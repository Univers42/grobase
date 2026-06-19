import { test, expect } from '@playwright/test';

test.describe('Landing — resilience & accessibility', () => {
	test('reduced-motion: backdrop stays calm, content is fully readable', async ({ browser }) => {
		const ctx = await browser.newContext({ reducedMotion: 'reduce' });
		const page = await ctx.newPage();
		await page.goto('/');
		await expect(page.getByRole('heading', { level: 1 })).toContainText('One backend');
		await expect(page.getByRole('heading', { name: 'What are you building?' })).toBeVisible();
		await expect(page.locator('.gb-uc')).toHaveCount(5);
		await ctx.close();
	});

	test('no-JS: the static starfield + the condensed content still render', async ({ browser }) => {
		const ctx = await browser.newContext({ javaScriptEnabled: false });
		const page = await ctx.newPage();
		await page.goto('/');
		await expect(page.locator('.gb-galaxy__fallback')).toHaveCount(1);
		await expect(page.getByRole('heading', { level: 1 })).toContainText('One backend');
		await expect(page.getByRole('heading', { name: 'What are you building?' })).toBeVisible();
		await expect(page.locator('.gb-uc')).toHaveCount(5); // cards are server-rendered, no JS needed
		await ctx.close();
	});

	test('console + CSP clean across a full scroll', async ({ page }) => {
		const errors: string[] = [];
		page.on('console', (m) => {
			if (m.type() === 'error') errors.push(m.text());
		});
		page.on('pageerror', (e) => errors.push(String(e)));
		await page.addInitScript(() => {
			(window as Record<string, unknown>).__csp = [];
			document.addEventListener('securitypolicyviolation', (e) => ((window as Record<string, unknown>).__csp as string[]).push((e as SecurityPolicyViolationEvent).violatedDirective));
		});
		await page.goto('/');
		const total = await page.evaluate(() => document.body.scrollHeight);
		for (let y = 0; y <= total; y += Math.max(300, Math.round(total / 12))) {
			await page.evaluate((yy) => window.scrollTo(0, yy), y);
			await page.waitForTimeout(150);
		}
		await page.waitForTimeout(800);
		const csp = (await page.evaluate(() => (window as Record<string, unknown>).__csp ?? [])) as string[];
		expect(csp, `CSP violations: ${csp.join(', ')}`).toEqual([]);
		expect(errors, `console errors: ${errors.join(' | ')}`).toEqual([]);
	});

	test('the node graph is a purely decorative, non-interactive background', async ({ page }) => {
		await page.goto('/');
		await expect(page.locator('#galaxy-canvas')).toHaveCount(1);
		await expect(page.locator('.gb-galaxy[aria-hidden="true"]')).toHaveCount(1);
		await expect(page.locator('#galaxy-explorer')).toHaveCount(0);
		await expect(page.locator('#galaxy-card')).toHaveCount(0);
	});
});
