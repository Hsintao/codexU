import { test, expect } from '@playwright/test';
import { createVisualFixture } from './support/fixture-data.mjs';

async function load(page, language, tokens, cost) {
  const data = createVisualFixture();
  data.settings.config.language = language;
  data.settings.config.theme = 'dark';
  data.dashboard.codex.snapshot.local.detailed_usage.month = {
    tokens: { input_tokens: tokens, cached_input_tokens: 0, output_tokens: 0, reasoning_output_tokens: 0, total_tokens: tokens },
    estimated_cost_usd: cost,
  };
  await page.addInitScript(data => { window.__CODEXU_VISUAL_DATA__ = data; }, data);
  await page.goto('/visual-test.html?surface=overview');
  return page.locator('.dashboard-home-monthly-progress');
}

for (const language of ['en', 'zh-Hans']) {
  test(`unpriced monthly tokens are not presented as no usage: ${language}`, async ({ page }) => {
    const panel = await load(page, language, 1_715_228_353, 0);
    await expect(panel).toContainText('1.7B');
    await expect(panel).toContainText(language === 'en' ? 'Local estimate unavailable' : '本地估算不可用');
    await expect(panel).not.toContainText('$0.00');
    await expect(panel).not.toContainText(language === 'en' ? 'no usage' : '尚无用量');
    await expect(panel).not.toContainText('Plus $20');
  });
  test(`a genuinely empty month retains a zero estimate: ${language}`, async ({ page }) => {
    const panel = await load(page, language, 0, 0);
    await expect(panel).toContainText('$0.00');
    await expect(panel).toContainText(language === 'en' ? 'no usage yet this month' : '本月尚无用量');
    expect(await panel.locator('[style*="linear-gradient"]').evaluate(el => getComputedStyle(el).borderRightWidth)).toBe('0px');
  });
  test(`missing monthly cost retains observable token activity: ${language}`, async ({ page }) => {
    const panel = await load(page, language, 1_715_228_353, null);
    await expect(panel).toContainText('1.7B');
    await expect(panel).not.toContainText('$0.00');
  });
  for (const width of [640, 960, 1440]) {
    test(`monthly reference labels stay inside the card: ${language} ${width}`, async ({ page }) => {
      await page.setViewportSize({ width, height: 760 });
      const panel = await load(page, language, 3_100_000, 31);
      await expect(panel).toContainText('$31.00');
      const bounds = await panel.boundingBox();
      const labels = [];
      for (const [text, title] of [['$20', 'Plus $20'], ['$100', 'Pro100 $100'], ['$200', 'Pro200 $200'], ['$46.5K', 'Cap $46.5K']]) {
        const label = panel.getByText(text, { exact: true });
        await expect(label).toBeVisible();
        await expect(label.locator('xpath=..')).toHaveAttribute('title', title);
        const box = await label.boundingBox();
        expect(box.x).toBeGreaterThanOrEqual(bounds.x);
        expect(box.x + box.width).toBeLessThanOrEqual(bounds.x + bounds.width);
        labels.push(box);
      }
      for (let i = 1; i < labels.length; i++) expect(labels[i].x).toBeGreaterThanOrEqual(labels[i - 1].x + labels[i - 1].width);
    });
  }
}
