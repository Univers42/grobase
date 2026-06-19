import { test, expect, type ConsoleMessage, type Page } from '@playwright/test';

const STAMP = Date.now();
const EMAIL = `e2e_${STAMP}@hypertube.test`;
const USERNAME = `e2e_${STAMP}`;
const PASSWORD = 'Sup3rSecret!';

/** attachConsoleGuard fails the test on any console error/warning (42 rule). */
function attachConsoleGuard(page: Page): string[] {
  const violations: string[] = [];
  page.on('console', (msg: ConsoleMessage) => {
    if (msg.type() === 'error' || msg.type() === 'warning') violations.push(`${msg.type()}: ${msg.text()}`);
  });
  page.on('pageerror', (err) => violations.push(`pageerror: ${err.message}`));
  return violations;
}

test('register → login → library → movie → comment → profile → logout', async ({ page }) => {
  const violations = attachConsoleGuard(page);

  await page.goto('/register');
  await page.getByLabel('Email', { exact: true }).fill(EMAIL);
  await page.getByLabel('Username').fill(USERNAME);
  await page.getByLabel('First name').fill('E2E');
  await page.getByLabel('Last name').fill('Tester');
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Register' }).click();

  await expect(page).toHaveURL(/\/library/, { timeout: 15_000 });

  const cards = page.getByTestId('movie-card');
  await expect(cards.first()).toBeVisible({ timeout: 15_000 });
  await cards.first().click();

  await expect(page.getByTestId('video-player')).toBeVisible({ timeout: 15_000 });
  const comment = `e2e comment ${STAMP}`;
  await page.getByLabel('Write a comment…').fill(comment);
  await page.getByRole('button', { name: 'Post' }).click();
  await expect(page.getByText(comment)).toBeVisible({ timeout: 10_000 });

  await page.getByRole('link', { name: 'Profile' }).click();
  await expect(page).toHaveURL(/\/profile\//);

  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });

  expect(violations, `console violations: ${violations.join(' | ')}`).toEqual([]);
});
