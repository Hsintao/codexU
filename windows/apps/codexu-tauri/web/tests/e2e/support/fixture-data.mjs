export function createVisualFixture() {
  const now = Date.now();
  const day = 24 * 60 * 60 * 1000;
  const usageDays = Array.from({ length: 7 }, (_, index) => {
    const total = 120_000 + index * 18_000;
    return {
      id: `fixture-day-${index + 1}`,
      date: now - (6 - index) * day,
      usage: pricedUsage(total),
      source_quality: 'detailed',
    };
  });
  const heatmapDays = usageDays.map((bucket) => ({
    id: bucket.id,
    date: bucket.date,
    usage: bucket.usage,
    is_future: false,
  }));
  const inferenceGroups = [
    inferenceGroup('sol-high', 'gpt-5.6-sol', 'high', 32, 8.4, 13.8, 18),
    inferenceGroup('terra-medium', 'gpt-5.6-terra', 'medium', 24, 10.2, 17.6, 12),
    inferenceGroup('luna-low', 'gpt-5.6-luna', 'low', 18, 6.1, 9.7, 9),
  ];
  const inferencePeriod = {
    period: 'today',
    coverage_day_count: 1,
    groups: inferenceGroups,
    total_call_count: inferenceGroups.reduce((sum, group) => sum + group.call_count, 0),
  };
  const projects = [
    project('project-alpha', 'Atlas', 540_000, 4, now - 18 * 60 * 1000),
    project('project-beta', 'Beacon', 360_000, 3, now - 2 * 60 * 60 * 1000),
  ];

  return {
    dashboard: {
      refreshed_at: now,
      codex: {
        scope: 'codex',
        status: 'local_only',
        quota_source_label: 'Repository fixture',
        usage_source_label: 'Synthetic local records',
        snapshot: {
          refreshed_at: now,
          account: { type: 'fixture', plan_type: null, email_present: false },
          limit_id: 'fixture-local',
          limit_name: 'Repository fixture',
          quota_read_succeeded: true,
          five_hour_quota: { used_percent: 36, window_duration_mins: 300, resets_at: now + day },
          seven_day_quota: { used_percent: 48, window_duration_mins: 10_080, resets_at: now + 4 * day },
          monthly_quota: null,
          local: {
            lifetime_tokens: 8_400_000,
            today_tokens: 420_000,
            seven_day_tokens: 1_260_000,
            thread_count: 24,
            last_updated_at: now,
            daily_buckets: usageDays.map((bucket) => ({
              id: bucket.id,
              label: new Date(bucket.date).toISOString().slice(0, 10),
              tokens: bucket.usage.tokens.total_tokens,
            })),
            recent_threads: [],
            detailed_usage: {
              today: pricedUsage(420_000),
              seven_day: pricedUsage(1_260_000),
              month: pricedUsage(3_100_000),
              lifetime: pricedUsage(8_400_000),
              parsed_file_count: 12,
              token_event_count: 96,
            },
            usage_trend: {
              day_buckets: usageDays,
              heatmap_weeks: [heatmapDays],
              heatmap_thresholds: [80_000, 140_000, 200_000, 260_000],
              summary: {
                seven_day: pricedUsage(1_260_000),
                daily_average_tokens: 180_000,
                peak_day: usageDays.at(-1),
                change_percent: 14,
                is_new_activity: false,
              },
              model_trends: null,
              month: pricedUsage(3_100_000),
              projected_month_cost_usd: 28.4,
              active_day_count: 7,
              source_quality: 'detailed',
            },
            inference_performance: {
              recording_started_at: now - 28 * day,
              today: inferencePeriod,
              seven_days: { ...inferencePeriod, period: 'seven_days', coverage_day_count: 7 },
              twenty_eight_days: { ...inferencePeriod, period: 'twenty_eight_days', coverage_day_count: 28 },
            },
            project_board: { recent_projects: projects, all_projects: projects },
            tool_usages: [
              { id: 'read-file', name: 'read_file', category: 'read', call_count: 14, estimated_tokens: 21_000, estimated_cost_usd: 0.21 },
              { id: 'apply-patch', name: 'apply_patch', category: 'edit', call_count: 6, estimated_tokens: 9_000, estimated_cost_usd: 0.09 },
            ],
            skill_usages: [
              { id: 'review-skill', name: 'review-skill', source_label: 'Repository fixture', load_count: 5, thread_count: 3, last_loaded_at: now },
            ],
          },
          task_board: {
            refreshed_at: now,
            columns: [
              taskColumn('active', 'Active', task('task-active', 'Review dashboard layout', 'recentlyActive', now)),
              taskColumn('pending', 'Pending', task('task-pending', 'Verify local aggregation', 'continueLater', now - 60_000)),
              taskColumn('scheduled', 'Scheduled', task('task-scheduled', 'Run release checks', 'scheduled', now + day)),
              taskColumn('done', 'Archived', task('task-done', 'Confirm privacy boundary', 'archived', now - day)),
            ],
          },
          messages: [],
        },
      },
      leadership: {
        score: 42,
        evidence_coverage: 0.92,
        active_day_count: 7,
        period: 'twentyEightDays',
        model_version: 'fixture-v1',
        report: {
          model_version: 'fixture-v1',
          refreshed_at: now,
          reports: [leadershipReport(now)],
        },
      },
      messages: [],
    },
    settings: {
      config: {
        codex_root: '<fixture data>',
        cache_dir: '<fixture cache>',
        theme: 'light',
        refresh_interval_secs: 60,
        tray_density: 'classic',
        language: 'en',
        palette_id: 'codexu.default',
      },
      app_data_dir: '<fixture app data>',
    },
    source: { mode: 'fixture', provider: 'fixture' },
  };
}

function pricedUsage(total) {
  const output = Math.round(total * 0.24);
  const input = total - output;
  return {
    tokens: {
      input_tokens: input,
      cached_input_tokens: Math.round(input * 0.35),
      cache_write_input_tokens: 0,
      output_tokens: output,
      reasoning_output_tokens: Math.round(output * 0.42),
      total_tokens: total,
    },
    estimated_cost_usd: Number((total / 100_000).toFixed(2)),
    uses_reference_pricing: false,
  };
}

function inferenceGroup(id, model, effort, throughput, p50, p90, calls) {
  const outputTokens = Math.round(throughput * p50 * calls);
  return {
    id,
    model,
    effort,
    call_count: calls,
    average_daily_call_count: Number((calls / 7).toFixed(1)),
    average_duration_seconds: Number(((p50 + p90) / 2).toFixed(1)),
    p50_duration_seconds: p50,
    p90_duration_seconds: p90,
    effective_output_tokens_per_second: throughput,
    output_tokens: outputTokens,
    reasoning_output_tokens: Math.round(outputTokens * 0.38),
  };
}

function project(id, name, tokens, threadCount, lastActiveAt) {
  return {
    id,
    name,
    full_path: `<fixture ${name}>`,
    tokens,
    estimated_cost_usd: Number((tokens / 100_000).toFixed(2)),
    thread_count: threadCount,
    last_active_at: lastActiveAt,
    source_quality: 'detailed',
  };
}

function taskColumn(id, title, item) {
  return { id, title, count: 1, items: [item] };
}

function task(id, title, displayState, updatedAt) {
  return {
    id,
    code: 'FIXTURE',
    title,
    detail: 'Repository fixture',
    chip: displayState,
    updated_at: updatedAt,
    tokens: null,
    kind: 'fixture',
    thread_id: null,
    runtime_state: 'recorded',
    source_kind: 'fixture',
    display_state: displayState,
    state_basis: 'fixture',
    raw_status: null,
    next_run_at: displayState === 'scheduled' ? updatedAt : null,
  };
}

function leadershipReport(now) {
  return {
    period: 'twentyEightDays',
    score: 42,
    core_score: 40,
    title: { level: 3, name: '协作领航员', english_name: 'Collaboration Navigator', lower_bound: 36, upper_bound: 50 },
    dimensions: [
      { kind: 'span', score: 44, confidence: 0.94, summary_value: 18 },
      { kind: 'leverage', score: 41, confidence: 0.9, summary_value: 2.6 },
      { kind: 'orchestration', score: 39, confidence: 0.88, summary_value: 3 },
      { kind: 'autonomy', score: 43, confidence: 0.91, summary_value: 6.2 },
    ],
    maturity: 0.78,
    evidence_coverage: 0.92,
    active_day_count: 7,
    agent_count: 18,
    ai_hours: 22.5,
    autonomous_hours: 6.2,
    average_parallelism: 2.6,
    peak_concurrency: 5,
    project_count: 2,
    daily_points: [
      { day: now - 2 * 86_400_000, agent_count: 8, ai_hours: 5.2, peak_concurrency: 3 },
      { day: now - 86_400_000, agent_count: 12, ai_hours: 7.8, peak_concurrency: 4 },
      { day: now, agent_count: 18, ai_hours: 9.5, peak_concurrency: 5 },
    ],
    projects: [
      { project_id: 'project-alpha', project_name: 'Atlas', agent_count: 11, ai_hours: 13.5, autonomous_hours: 3.8 },
      { project_id: 'project-beta', project_name: 'Beacon', agent_count: 7, ai_hours: 9, autonomous_hours: 2.4 },
    ],
  };
}
