import { test, expect } from '@playwright/test';

test.describe('Landing — condensed, public, use-case first', () => {
	test('the page is condensed: hero + 5 use-cases + 4 value props + roadmap + CTA', async ({ page }) => {
		await page.goto('/');
		await expect(page.getByRole('heading', { level: 1 })).toContainText('One backend');
		await expect(page.getByRole('heading', { name: 'What are you building?' })).toBeVisible();
		await expect(page.locator('.gb-uc')).toHaveCount(5);
		await expect(page.locator('.gb-value')).toHaveCount(4);
		await expect(page.getByText('The honest roadmap.')).toBeVisible();
	});

	test('use-case cards route to the matching plan anchor', async ({ page }) => {
		await page.goto('/');
		const expected = ['#nano', '#basic', '#essential', '#pro', '#max'];
		const hrefs = await page.locator('.gb-uc__link').evaluateAll((els) =>
			els.map((e) => (e as HTMLAnchorElement).getAttribute('href') ?? ''),
		);
		for (const anchor of expected) {
			expect(hrefs.some((h) => h.includes(`/pricing/${anchor}`))).toBeTruthy();
		}
	});

	test('no competitor framing anywhere on the page (public, not vs-X)', async ({ page }) => {
		await page.goto('/');
		const body = (await page.locator('body').innerText()).toLowerCase();
		for (const name of ['supabase', 'firebase', 'pocketbase', 'dreamfactory']) {
			expect(body, `found competitor mention: ${name}`).not.toContain(name);
		}
		// the Compare nav entry is gone
		await expect(page.locator('.gb-header__nav a[href="/compare/"]')).toHaveCount(0);
	});

	test('the galaxy is an ambient, decorative, non-interactive backdrop', async ({ page }) => {
		await page.goto('/');
		await page.waitForFunction(() => typeof (window as Record<string, unknown>).__galaxyState === 'string', null, { timeout: 8000 });
		await expect(page.locator('#galaxy-canvas')).toHaveCount(1);
		await expect(page.locator('.gb-galaxy[aria-hidden="true"]')).toHaveCount(1);
		// the scroll-driven morph + Big Bang were retired: no trigger sentinel remains
		await expect(page.locator('[data-bigbang-trigger]')).toHaveCount(0);
		await expect(page.locator('[data-galaxy-state]')).toHaveCount(0);
	});
});
