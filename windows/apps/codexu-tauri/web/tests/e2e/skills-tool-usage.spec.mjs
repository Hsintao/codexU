import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { expect, test } from '@playwright/test';

test.setTimeout(240_000);

test('renders multiple tool names and counts in the Skills surface', async ({ page }, testInfo) => {
  const visualData = createSkillsFixture();

  await page.addInitScript((data) => {
    window.__CODEXU_VISUAL_DATA__ = data;
  }, visualData);
  await page.goto('/visual-test.html?surface=skills');

  const tab = page.getByRole('tab', { name: 'Skills', exact: true });
  await tab.click();
  await expect(tab).toHaveAttribute('aria-selected', 'true');

  const panel = page.locator('#dashboard-home-panel-skills');
  await expect(panel).toBeVisible();
  await expect(panel.getByRole('heading', { name: 'Skills', exact: true })).toBeVisible();
  await expect(panel.getByText('block-workflow', { exact: true })).toBeVisible();
  await expect(panel.getByRole('heading', { name: 'Tools', exact: true })).toBeVisible();
  await expect(panel).toContainText('2 total');
  await expect(panel).toContainText('read_file');
  await expect(panel).toContainText('apply_patch');
  await expect(panel).toContainText('2 calls');
  await expect(panel).toContainText('1 call');
  const tokenEstimate = panel.getByText('≈1.2K', { exact: true });
  await expect(tokenEstimate).toBeVisible();
  await tokenEstimate.hover();
  await expect(tokenEstimate).toHaveAttribute('title', 'Tokens allocated by tool call count.');
  await expect(panel.getByText('≈600', { exact: true })).toBeVisible();
  await expect(panel).not.toContainText('est.');
  await expect(panel).not.toContainText('% of top Skill');
  const skillBar = panel.locator('.skill-activity-bar').first();
  await skillBar.hover();
  await expect(skillBar).toHaveAttribute('title', '100% of top Skill');
  await expect(skillBar).toHaveAttribute('aria-label', 'Relative activity 100%');
  await expect(panel).not.toContainText('private-user');
  await expect(panel).not.toContainText('secret.txt');

  const screenshotPath = path.join(testInfo.outputDir, 'evidence', 'skills-multi-tool', 'focused.png');
  await mkdir(path.dirname(screenshotPath), { recursive: true });
  await panel.screenshot({ path: screenshotPath });
});

function createSkillsFixture() {
  const refreshedAt = Date.now();
  return {
    dashboard: {
      refreshed_at: refreshedAt,
      codex: {
        scope: 'codex',
        status: 'local_only',
        quota_source_label: 'Codex local fixture',
        snapshot: {
          refreshed_at: refreshedAt,
          account: { type: 'codex-local', plan_type: null, email_present: false },
          limit_id: 'codex-local',
          limit_name: 'Codex local fixture',
          quota_read_succeeded: false,
          five_hour_quota: null,
          seven_day_quota: null,
          monthly_quota: null,
          local: {
            lifetime_tokens: 150,
            today_tokens: 150,
            seven_day_tokens: 150,
            thread_count: 1,
            last_updated_at: refreshedAt,
            daily_buckets: [],
            recent_threads: [],
            detailed_usage: null,
            usage_trend: null,
            inference_performance: null,
            project_board: null,
            tool_usages: [
              {
                id: 'read_file',
                name: 'read_file',
                category: 'docs',
                call_count: 2,
                estimated_tokens: 1200,
                estimated_cost_usd: null,
              },
              {
                id: 'apply_patch',
                name: 'apply_patch',
                category: 'edit',
                call_count: 1,
                estimated_tokens: 600,
                estimated_cost_usd: null,
              },
            ],
            skill_usages: [
              {
                id: 'block-workflow',
                name: 'block-workflow',
                source_label: 'Local project',
                load_count: 1,
                thread_count: 1,
                last_loaded_at: refreshedAt,
              },
            ],
          },
          task_board: null,
          messages: [],
        },
      },
      leadership: {
        score: null,
        evidence_coverage: 0,
        active_day_count: 0,
        period: 'today',
        model_version: 'fixture',
        report: null,
      },
      messages: [],
    },
    settings: {
      config: {
        codex_root: '<fixture Codex data>',
        cache_dir: '<fixture codexU cache>',
        theme: 'light',
        refresh_interval_secs: 60,
        tray_density: 'classic',
        language: 'en',
        palette_id: 'codexu.default',
      },
      app_data_dir: '<fixture codexU app data>',
    },
    source: { mode: 'live-readonly', provider: 'fixture' },
  };
}
