import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { test, expect } from '@playwright/test';
import { createVisualFixture } from './support/fixture-data.mjs';

test.setTimeout(120_000);

const DAY = 24 * 60 * 60 * 1000;

// History wider than the largest range so every range button changes the rendered point count.
function createTrendFixture(dayCount = 200) {
  const data = createVisualFixture();
  const now = Date.now();
  const trend = data.dashboard.codex.snapshot.local.usage_trend;
  const template = trend.day_buckets[0];
  trend.day_buckets = Array.from({ length: dayCount }, (_, index) => ({
    id: `trend-day-${index + 1}`,
    date: now - (dayCount - 1 - index) * DAY,
    usage: template.usage,
    source_quality: 'detailed',
  }));
  return data;
}

async function openUsageTrend(page) {
  await page.addInitScript((data) => {
    window.__CODEXU_VISUAL_DATA__ = data;
  }, createTrendFixture());
  await page.goto('/visual-test.html?surface=usage');
  await expect(page.locator('.dashboard-home')).toBeVisible();
  await page.getByRole('tab', { name: 'Usage', exact: true }).click();
  const panel = page.locator('#dashboard-home-panel-usage');
  await expect(panel).toBeVisible();
  const chart = panel.locator('.glass-panel').filter({ has: page.locator('.usage-trend-summary') });
  await expect(chart).toBeVisible();
  return chart;
}

function rangeButton(chart, label) {
  return chart.getByRole('button', { name: label, exact: true });
}

async function renderedPointCount(chart) {
  // The trend Area renders without dots, so the curve path segment count equals the
  // number of plotted daily points (one 'C' segment per point after the move command).
  const pathData = await chart.locator('.recharts-curve.recharts-area-curve').getAttribute('d');
  assert.ok(pathData, 'the trend area curve must be rendered');
  return pathData.split('C').length;
}

function xAxisTickLabels(chart) {
  // SVG <text>/<tspan> do not expose innerText, so read textContent instead.
  return chart
    .locator('.recharts-xAxis .recharts-cartesian-axis-tick-value tspan')
    .evaluateAll((nodes) => nodes.map((node) => node.textContent ?? ''));
}

// recharts thins X ticks to satisfy minTickGap, so the tick COUNT depends on the width of the
// rendered calendar labels and is not a range contract. Only assert that the axis is well formed:
// at least one tick, all of them parse as dates, and all of them stay inside the range window.
function assertAxisLabels(labels, days) {
  assert.ok(labels.length > 0, 'the range must render at least one date tick');
  const startOfToday = new Date();
  startOfToday.setHours(0, 0, 0, 0);
  const earliest = startOfToday.getTime() - (days - 1) * DAY;
  const latest = startOfToday.getTime() + DAY;
  for (const label of labels) {
    const text = label.trim();
    assert.match(text, /^[A-Z][a-z]{2} \d{1,2}$/, `unexpected date axis label: ${text}`);
    const parsed = Date.parse(`${text} ${new Date().getFullYear()}`);
    assert.ok(Number.isFinite(parsed), `unparseable date axis label: ${text}`);
    assert.ok(
      parsed >= earliest && parsed < latest,
      `date axis label ${text} falls outside the ${days}-day window`,
    );
  }
}

test('the trend range control offers 7D first and selects it on first render', async ({ page }, testInfo) => {
  const chart = await openUsageTrend(page);

  const labels = (await chart.locator('button').allInnerTexts()).map((label) => label.trim());
  assert.deepEqual(labels, ['7D', '30D', '90D', '180D']);

  const sevenDay = rangeButton(chart, '7D');
  await expect(sevenDay).toBeVisible();
  // The active range is the one carrying the solid glass button style.
  await expect(sevenDay).toHaveClass(/glass-button-solid/);
  for (const label of ['30D', '90D', '180D']) {
    await expect(rangeButton(chart, label)).not.toHaveClass(/glass-button-solid/);
  }

  const folder = path.join(testInfo.outputDir, 'evidence');
  await mkdir(folder, { recursive: true });
  await chart.screenshot({ path: path.join(folder, 'trend-range-default-7d.png') });
});

test('switching the trend range redraws the date axis with a different point count', async ({ page }, testInfo) => {
  const chart = await openUsageTrend(page);

  assert.equal(await renderedPointCount(chart), 7, 'the default 7D range must render seven daily points');
  const sevenDayAxis = await xAxisTickLabels(chart);
  assertAxisLabels(sevenDayAxis, 7);

  await rangeButton(chart, '30D').click();
  await expect(rangeButton(chart, '30D')).toHaveClass(/glass-button-solid/);
  await expect(rangeButton(chart, '7D')).not.toHaveClass(/glass-button-solid/);
  await expect.poll(() => renderedPointCount(chart)).toBe(30);

  const thirtyDayAxis = await xAxisTickLabels(chart);
  assert.notDeepEqual(thirtyDayAxis, sevenDayAxis, 'the rendered date axis must change with the range');
  assertAxisLabels(thirtyDayAxis, 30);

  const folder = path.join(testInfo.outputDir, 'evidence');
  await mkdir(folder, { recursive: true });
  await chart.screenshot({ path: path.join(folder, 'trend-range-switched-30d.png') });

  await rangeButton(chart, '90D').click();
  await expect.poll(() => renderedPointCount(chart)).toBe(90);
  const ninetyDayAxis = await xAxisTickLabels(chart);
  assert.notDeepEqual(ninetyDayAxis, thirtyDayAxis, 'switching to 90D must redraw the date axis');
  assertAxisLabels(ninetyDayAxis, 90);

  await rangeButton(chart, '180D').click();
  await expect.poll(() => renderedPointCount(chart)).toBe(180);
  const oneEightyDayAxis = await xAxisTickLabels(chart);
  assert.notDeepEqual(oneEightyDayAxis, ninetyDayAxis, 'switching to 180D must redraw the date axis');
  assertAxisLabels(oneEightyDayAxis, 180);

  await rangeButton(chart, '7D').click();
  await expect.poll(() => renderedPointCount(chart)).toBe(7);
  await expect(rangeButton(chart, '7D')).toHaveClass(/glass-button-solid/);
});
