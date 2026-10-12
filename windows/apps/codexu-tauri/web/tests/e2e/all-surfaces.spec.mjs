import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { test, expect } from '@playwright/test';
import { getRepositoryIdentity, loadLiveDashboard } from './support/live-data.mjs';
import { createVisualFixture } from './support/fixture-data.mjs';

test.setTimeout(240_000);

const SURFACES = [
  { id: 'overview', label: 'Overview' },
  { id: 'tasks', label: 'Tasks' },
  { id: 'leadership', label: 'AI Leadership' },
  { id: 'usage', label: 'Usage' },
  { id: 'inference', label: 'Inference', tabLabel: 'Inference performance' },
  { id: 'projects', label: 'Projects' },
  { id: 'skills', label: 'Skills' },
  { id: 'settings', label: 'Settings' },
];

test('captures the fixed eight Web surfaces with deterministic visual data', async ({ page }, testInfo) => {
  const selectedSurface = process.env.CODEXU_VISUAL_SURFACE?.trim() || null;
  const selectedSurfaces = selectSurfaces(SURFACES, process.env.CODEXU_VISUAL_SURFACE);
  const visualData = process.env.CODEXU_VISUAL_LIVE === '1'
    ? await loadLiveDashboard()
    : createVisualFixture();
  const identity = await getRepositoryIdentity();
  const runId = process.env.CODEXU_VISUAL_RUN_ID ?? 'run-' + new Date().toISOString().replaceAll(/[^0-9]/g, '');
  const evidenceRoot = path.join(testInfo.outputDir, 'evidence', runId);
  const observations = [];

  await page.addInitScript((data) => {
    window.__CODEXU_VISUAL_DATA__ = data;
  }, visualData);

  for (const surface of selectedSurfaces) {
    await page.goto('/visual-test.html?surface=' + surface.id);
    const harness = page.locator('[data-testid="visual-test-surface"]');
    await expect(harness).toHaveAttribute('data-surface', surface.id);
    await expect(harness.locator('h2.sr-only')).toHaveText(surface.label);

    const focused = await enterSurface(page, surface);
    await expect(focused).toBeVisible();
    await assertSurfaceInteraction(page, surface);

    const focusedPath = path.join(evidenceRoot, surface.id, 'focused.png');
    const pagePath = path.join(evidenceRoot, surface.id, 'page.png');
    await mkdir(path.dirname(focusedPath), { recursive: true });
    await focused.screenshot({ path: focusedPath });
    await page.screenshot({ path: pagePath, fullPage: true });

    const observedState = await observeDataState(page, surface, visualData.dashboard);
    observations.push({
      surface: surface.id,
      focused: 'focused.png',
      page: 'page.png',
      result: observedState === 'populated' ? 'PASS' : 'NOT OBSERVED',
      data_state: observedState,
      capture_api: 'playwright-locator-and-page-screenshot',
      native_evidence: 'not_run',
    });
  }

  const manifest = {
    suite_id: 'codexu-windows-web-playwright-inference',
    run_id: runId,
    source_candidate: {
      branch: identity.branch,
      head: identity.head,
    },
    mode: visualData.source.mode,
    provider: visualData.source.provider,
    scope: selectedSurface ? 'single' : 'all',
    selected_surface: selectedSurface,
    browser: 'chromium',
    viewport: { width: 960, height: 760 },
    locale: 'en-US',
    theme: 'light',
    screenshot_contract: {
      focused: 'Playwright locator.screenshot()',
      page: 'Playwright page.screenshot({ fullPage: true })',
      comparison: 'none',
    },
    data_summary: summarizeDashboard(visualData.dashboard),
    observations,
    generated_at: new Date().toISOString(),
  };
  await writeFile(path.join(evidenceRoot, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

  assert.equal(observations.length, selectedSurfaces.length);
  assert.deepEqual(observations.map((item) => item.surface), selectedSurfaces.map((item) => item.id));
  if (visualData.source.mode === 'fixture') {
    assert.deepEqual(
      observations.map((item) => item.result),
      selectedSurfaces.map(() => 'PASS'),
      'every deterministic fixture surface must be observed as populated',
    );
  }
});

test('classifies a tools-only Skills surface as populated', async ({ page }) => {
  const visualData = createVisualFixture();
  visualData.dashboard.codex.snapshot.local.skill_usages = [];
  assert.ok(visualData.dashboard.codex.snapshot.local.tool_usages.length > 0);

  await page.addInitScript((data) => {
    window.__CODEXU_VISUAL_DATA__ = data;
  }, visualData);
  await page.goto('/visual-test.html?surface=skills');

  const surface = SURFACES.find((item) => item.id === 'skills');
  const focused = await enterSurface(page, surface);
  await expect(focused).toBeVisible();
  await expect.poll(() => observeDataState(page, surface, visualData.dashboard)).toBe('populated');
});

function selectSurfaces(surfaces, requestedSurface) {
  const selectedSurface = requestedSurface?.trim();
  if (!selectedSurface) return surfaces;

  const surface = surfaces.find((item) => item.id === selectedSurface);
  if (!surface) {
    throw new Error(`Unknown visual surface: ${selectedSurface}. Expected one of ${surfaces.map((item) => item.id).join(', ')}`);
  }
  return [surface];
}

async function enterSurface(page, surface) {
  if (surface.id === 'settings') {
    await expect(page.locator('h1').filter({ hasText: 'Settings' })).toBeVisible();
    return page.locator('[data-glass-surface="page"]');
  }

  await expect(page.locator('.dashboard-home')).toBeVisible();
  if (surface.id === 'overview') {
    await expect(page.locator('.dashboard-home-overview')).toBeVisible();
    return page.locator('.dashboard-home-overview');
  }

  const tab = page.getByRole('tab', { name: surface.tabLabel ?? surface.label, exact: true });
  await tab.click();
  await expect(tab).toHaveAttribute('aria-selected', 'true');
  const panel = page.locator('#dashboard-home-panel-' + surface.id);
  await expect(panel).toBeVisible();
  return panel;
}

async function assertSurfaceInteraction(page, surface) {
  if (surface.id === 'inference') {
    const periodTab = page.getByRole('tab', { name: '7d avg', exact: true });
    await periodTab.click();
    await expect(periodTab).toHaveAttribute('aria-selected', 'true');
    const point = page.locator('.inference-scatter-point').first();
    await point.hover();
    const tooltip = page.getByRole('tooltip');
    await expect(tooltip).toBeVisible();
    await expect(tooltip).toContainText('Daily calls');
    await expect(tooltip).toContainText('Reasoning tokens');
    await point.focus();
    await expect(point).toBeFocused();
    await expect(tooltip).toBeVisible();
    return;
  }

  if (surface.id === 'settings') {
    const dark = page.getByRole('button', { name: 'Dark', exact: true });
    const refresh = page.getByRole('button', { name: 'Refresh now', exact: true });
    await expect(dark).toBeVisible();
    await expect(refresh).toBeVisible();
    assert.equal(await dark.isDisabled(), true, 'Web-only Settings must not write through Tauri');
  }
}

async function observeDataState(page, surface, dashboard) {
  const focused = surface.id === 'settings'
    ? page.locator('[data-glass-surface="page"]')
    : surface.id === 'overview'
      ? page.locator('.dashboard-home-overview')
      : page.locator('#dashboard-home-panel-' + surface.id);
  const text = await focused.innerText();
  const hasVisibleContent = text.trim().length >= 80;
  const hasVisibleValue = surface.id === 'settings'
    ? await focused.locator('input').evaluateAll(inputs => inputs.length >= 2 && inputs.every(input => input.value.trim().length > 0))
    : /\d/.test(text);
  return hasVisibleContent && hasVisibleValue && hasLiveDataForSurface(surface.id, dashboard)
    ? 'populated'
    : 'empty';
}

function hasLiveDataForSurface(surface, dashboard) {
  const snapshot = dashboard.codex.snapshot;
  const local = snapshot.local;
  if (surface === 'settings') return true;
  if (surface === 'overview') return local !== null && local.thread_count > 0;
  if (surface === 'tasks') return snapshot.task_board?.columns.some((column) => column.items.length > 0) ?? false;
  if (surface === 'leadership') {
    return dashboard.leadership.report?.reports.some(
      (report) => report.dimensions.length > 0 || report.daily_points.length > 0 || report.projects.length > 0,
    ) ?? false;
  }
  if (!local) return false;
  if (surface === 'usage') return local.usage_trend !== null || local.detailed_usage !== null;
  if (surface === 'inference') {
    return Object.values(local.inference_performance ?? {}).some((period) => period?.groups?.length > 0);
  }
  if (surface === 'projects') return (local.project_board?.all_projects.length ?? 0) > 0;
  if (surface === 'skills') return local.skill_usages.length > 0 || local.tool_usages.length > 0;
  return false;
}

function summarizeDashboard(dashboard) {
  const snapshot = dashboard.codex.snapshot;
  const local = snapshot.local;
  return {
    local_usage: Boolean(local),
    thread_count: local?.thread_count ?? 0,
    task_count: snapshot.task_board?.columns.reduce((sum, column) => sum + column.items.length, 0) ?? 0,
    project_count: local?.project_board?.all_projects.length ?? 0,
    skill_count: local?.skill_usages.length ?? 0,
    tool_count: local?.tool_usages.length ?? 0,
    has_usage_trend: Boolean(local?.usage_trend),
    has_inference_history: Boolean(local?.inference_performance),
    has_leadership_report: Boolean(dashboard.leadership.report),
  };
}
