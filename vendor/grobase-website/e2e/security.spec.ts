import { test, expect } from '@playwright/test';

test.describe('Security — honest, soft-framing, audit-ready posture', () => {
	test('the page renders: h1 + the key section headings', async ({ page }) => {
		await page.goto('/security/');
		await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
		// Section labels are kickers (<p class="gb-kicker">); the <h2> carries evocative copy.
		await expect(page.locator('.gb-kicker', { hasText: 'Enterprise security controls' })).toBeVisible();
		await expect(page.locator('.gb-kicker', { hasText: 'Access & identity' })).toBeVisible();
		await expect(page.locator('.gb-kicker', { hasText: 'Vulnerability disclosure' })).toBeVisible();
		await expect(page.locator('.gb-kicker', { hasText: 'Compliance posture' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Security FAQ' })).toBeVisible();
	});

	test('a "Security" nav link exists', async ({ page }) => {
		await page.goto('/security/');
		await expect(page.locator('.gb-header__nav a[href="/security/"]')).toHaveCount(1);
	});

	test('HONESTY: the body never contains the bare word "certified"', async ({ page }) => {
		await page.goto('/security/');
		const body = (await page.locator('body').innerText()).toLowerCase();
		expect(body, 'the forbidden literal "certified" must not appear').not.toContain('certified');
	});

	test('an element with id="disclosure" exists for the security.txt Policy link', async ({ page }) => {
		await page.goto('/security/');
		await expect(page.locator('#disclosure')).toHaveCount(1);
	});

	test('/.well-known/security.txt is reachable and is a valid RFC 9116 file', async ({ page }) => {
		const res = await page.request.get('/.well-known/security.txt');
		expect(res.ok()).toBeTruthy();
		const text = await res.text();
		expect(text).toContain('Contact:');
		expect(text).toContain('Expires:');
		expect(text).toContain('Policy:');
	});
});
