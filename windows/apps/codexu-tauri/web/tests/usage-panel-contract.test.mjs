import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const usagePanelPath = new URL('../src/components/UsagePanel.tsx', import.meta.url);
const trendChartPath = new URL('../src/components/TrendChart.tsx', import.meta.url);
const heatmapPath = new URL('../src/components/UsageHeatmap.tsx', import.meta.url);
const messagesPath = new URL('../src/i18n/messages.ts', import.meta.url);

test('builds Usage around local source quality, token layers, and the existing trend contract', async () => {
  const [usagePanel, trendChart, heatmap, messages] = await Promise.all([
    readFile(usagePanelPath, 'utf8'),
    readFile(trendChartPath, 'utf8'),
    readFile(heatmapPath, 'utf8'),
    readFile(messagesPath, 'utf8'),
  ]);

  assert.match(usagePanel, /<UsageHeatmap trend=\{trend\} \/>/);
  assert.match(usagePanel, /useI18n/);
  assert.match(usagePanel, /usage\.estimate/);
  assert.doesNotMatch(usagePanel, /usage\.localDetail/);
  assert.doesNotMatch(usagePanel, /usage\.notOfficial/);
  assert.doesNotMatch(messages, /localDetail:/);
  assert.doesNotMatch(messages, /notOfficial:/);
  assert.match(usagePanel, /TokenBreakdownBar/);
  assert.match(usagePanel, /source_quality/);

  assert.match(trendChart, /visibleTotalTokens/);
  assert.match(trendChart, /summary\.seven_day/);
  assert.match(trendChart, /daily_average_tokens/);
  assert.match(trendChart, /change_percent/);

  assert.match(trendChart, /const RANGES = \[\s*\{ label: '7D', days: 7 \}/);
  assert.match(
    trendChart,
    /\{ label: '7D', days: 7 \},\s*\{ label: '30D', days: 30 \},\s*\{ label: '90D', days: 90 \},\s*\{ label: '180D', days: 180 \},/,
  );
  assert.match(trendChart, /useState\(7\)/);

  assert.match(heatmap, /heatmap_weeks/);
  assert.match(heatmap, /heatmap_thresholds/);
  assert.match(heatmap, /is_future/);
  assert.match(heatmap, /usage\.noRecordedUsage/);
});
