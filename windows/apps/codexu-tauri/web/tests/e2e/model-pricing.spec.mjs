import { test, expect } from '@playwright/test';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { createVisualFixture } from './support/fixture-data.mjs';

for (const language of ['en', 'zh-Hans']) {
  for (const reference of [false, true]) {
    test(`pricing source remains visible: ${language}, reference=${reference}`, async ({ page }) => {
      const data = createVisualFixture();
      data.settings.config.language = language;
      const detailed = data.dashboard.codex.snapshot.local.detailed_usage;
      for (const usage of Object.values(detailed)) {
        if (usage && typeof usage === 'object' && 'estimated_cost_usd' in usage) {
          usage.estimated_cost_usd = 123.45;
          usage.uses_reference_pricing = reference;
        }
      }
      await page.addInitScript(data => { window.__CODEXU_VISUAL_DATA__ = data; }, data);
      await page.goto('/visual-test.html?surface=overview');
      const month = page.locator('.dashboard-home-monthly-progress');
      await expect(month).toContainText('123.45');
      await expect(month).not.toContainText(language === 'en' ? 'no usage' : '尚无用量');
      if (reference) {
        await expect(month).toContainText(language === 'en' ? 'reference estimate' : '参考估算');
        await expect(month).toContainText('≈');
      } else {
        await expect(month).not.toContainText('≈');
      }
    });
  }
}

test('shows a real local monthly recomputation', async ({ page }, info) => {
  test.skip(!process.env.CODEXU_PRICING_REAL_USAGE, 'Read-only production evidence is explicitly opt-in');
  const local = JSON.parse(await readFile(process.env.CODEXU_PRICING_REAL_USAGE, 'utf8'));
  const data = createVisualFixture();
  data.settings.config.language = 'zh-Hans';
  data.settings.config.theme = 'dark';
  // Only real aggregate statistics enter this capture; fixture navigation stays isolated.
  data.dashboard.codex.snapshot.local.detailed_usage = local.detailed_usage;
  data.dashboard.codex.snapshot.local.today_tokens = local.today_tokens;
  data.dashboard.codex.snapshot.local.seven_day_tokens = local.seven_day_tokens;
  data.dashboard.codex.snapshot.local.lifetime_tokens = local.lifetime_tokens;
  await page.addInitScript(data => { window.__CODEXU_VISUAL_DATA__ = data; }, data);
  await page.goto('/visual-test.html?surface=overview');
  const month = page.locator('.dashboard-home-monthly-progress');
  const cost = local.detailed_usage.month.estimated_cost_usd;
  expect(cost).toBeGreaterThan(0);
  await expect(month).toContainText(cost.toFixed(2));
  await expect(month).not.toContainText('尚无用量');
  const folder = process.env.CODEXU_PRICING_EVIDENCE ?? path.join(info.outputDir,'evidence');
  await mkdir(folder,{recursive:true});
  await month.screenshot({path:path.join(folder,'real-month-after.png')});
});
