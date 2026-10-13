import { test, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { createVisualFixture } from './support/fixture-data.mjs';

async function load(page, { language = 'en', theme = 'light', windows = true, succeeded = true } = {}) {
  const data = createVisualFixture();
  data.settings.config.language = language;
  data.settings.config.theme = theme;
  data.dashboard.codex.snapshot.quota_read_succeeded = succeeded;
  if (windows) {
    data.dashboard.codex.snapshot.five_hour_quota.used_percent = 0;
    data.dashboard.codex.snapshot.monthly_quota = { used_percent: 10, window_duration_mins: 43200, resets_at: Date.now() + 86400000 };
  } else {
    for (const key of ['five_hour_quota', 'seven_day_quota', 'monthly_quota']) data.dashboard.codex.snapshot[key] = null;
  }
  await page.addInitScript(data => { window.__CODEXU_VISUAL_DATA__ = data; }, data);
  await page.goto('/visual-test.html?surface=overview');
  await expect(page.locator('.dashboard-home')).toBeVisible();
}

for (const language of ['en', 'zh-Hans']) {
  for (const theme of ['light', 'dark']) {
    for (const width of [640, 960, 1440]) {
      test(`quota values fit without a success explainer: ${language} ${theme} ${width}`, async ({ page }, info) => {
        await page.setViewportSize({ width, height: 760 });
        await load(page, { language, theme });
        const quota = page.locator('.dashboard-home-quota');
        await expect(quota.getByRole('meter')).toHaveCount(3);
        for (const meter of await quota.getByRole('meter').all()) await expect(meter).toBeInViewport();
        await expect(quota).toContainText(language === 'en' ? '0% used' : '已用 0%');
        await expect(quota).toContainText(language === 'en' ? 'Resets' : '重置');
        await expect(quota).not.toContainText(language === 'en' ? 'Only confirmed' : '这里只显示');
        await expect(quota.locator('.quota-overview-state')).toHaveCount(0);
        const badge = quota.locator('.dashboard-overview-status');
        await expect(badge).toHaveText(language === 'en' ? 'Official' : '官方');
        expect(await badge.evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
        const folder = path.join(info.outputDir, 'evidence');
        await mkdir(folder, { recursive: true });
        await page.locator('.dashboard-home-overview').screenshot({ path: path.join(folder, 'overview.png') });
      });
    }
  }
}

test('first read remains retryable without fabricated quota values', async ({ page }) => {
  await load(page, { windows: false, succeeded: false });
  const quota = page.locator('.dashboard-home-quota');
  await expect(quota.getByRole('meter')).toHaveCount(0);
  await expect(quota.getByRole('button', { name: 'Retry quota check' })).toBeVisible();
});

test('confirmed empty quota is not shown as zero', async ({ page }) => {
  await load(page, { windows: false, succeeded: true });
  const quota = page.locator('.dashboard-home-quota');
  await expect(quota).toContainText('No active official quota limits');
  await expect(quota.getByRole('meter')).toHaveCount(0);
  await expect(quota.getByRole('button')).toHaveCount(0);
});

test('previous official quota remains labeled as saved after a failed read', async ({ page }) => {
  await load(page, { succeeded: false });
  const quota = page.locator('.dashboard-home-quota');
  await expect(quota.getByRole('meter')).toHaveCount(3);
  await expect(quota).toContainText('Official · saved');
  await expect(quota.locator('.dashboard-overview-status-confirmed')).toHaveCount(0);
});

test('short history keeps its daily readings and has a compact heatmap', async ({ page }) => {
  await load(page);
  await page.getByRole('tab', { name: 'Usage', exact: true }).click();
  const grid = page.locator('#dashboard-home-panel-usage').getByRole('grid');
  await expect(grid).toBeVisible();
  await expect(grid.getByRole('gridcell')).toHaveCount(7);
  expect((await grid.boundingBox()).height).toBeLessThan(240);
  await expect(grid.getByRole('gridcell').first()).toHaveAttribute('title', /Token|tokens/);
});
