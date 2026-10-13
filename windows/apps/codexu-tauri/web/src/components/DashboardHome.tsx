import { Activity, Calendar, TrendingUp } from 'lucide-react';
import { useRef, useState, type KeyboardEvent } from 'react';
import type { CodexLeadershipSignal, UsageSnapshot } from '../types/models';
import { InferencePerformancePanel } from './InferencePerformancePanel';
import { LeadershipOverviewCard, LeadershipPanel } from './LeadershipPanel';
import { MonthlyValueProgress } from './MonthlyValueProgress';
import { ProjectsPanel } from './ProjectsPanel';
import { QuotaOverview } from './QuotaOverview';
import { SkillsPanel } from './SkillsPanel';
import { TaskBoardPanel } from './TaskBoardPanel';
import { UsagePanel } from './UsagePanel';
import { StatCard } from './StatCard';
import { useI18n } from '../i18n/I18nProvider';
import type { MessageKey } from '../i18n/messages';
import { formatQuantity } from '../utils/formatQuantity';

interface DashboardHomeProps {
  snapshot: UsageSnapshot | null | undefined;
  quotaSourceLabel: string | null | undefined;
  leadershipSignal: CodexLeadershipSignal | null | undefined;
  onQuotaRefresh: () => void;
}

type DashboardContentTab = 'tasks' | 'leadership' | 'usage' | 'inference' | 'projects' | 'skills';

const DASHBOARD_TABS: Array<{ id: DashboardContentTab; title: string; titleKey: MessageKey }> = [
  { id: 'tasks', title: 'Tasks', titleKey: 'dashboard.tabs.tasks' },
  { id: 'leadership', title: 'AI Leadership', titleKey: 'dashboard.tabs.leadership' },
  { id: 'usage', title: 'Usage', titleKey: 'dashboard.tabs.usage' },
  { id: 'inference', title: 'Inference', titleKey: 'dashboard.tabs.inference' },
  { id: 'projects', title: 'Projects', titleKey: 'dashboard.tabs.projects' },
  { id: 'skills', title: 'Skills', titleKey: 'dashboard.tabs.skills' },
];

const formatUSD = (value: unknown): string => {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '--';
  return value.toFixed(Math.abs(value) >= 1_000 ? 0 : 2);
};

export function DashboardHome({ snapshot, quotaSourceLabel, leadershipSignal, onQuotaRefresh }: DashboardHomeProps) {
  const { t } = useI18n();
  const usage = snapshot?.local ?? null;
  const signal = leadershipSignal ?? null;
  const detailed = usage?.detailed_usage ?? null;
  const hasUsage = usage !== null;
  const costNote = t('dashboard.metrics.costNote');
  const referenceCostNote = `${costNote} · ${t('dashboard.metrics.referenceCostNote')}`;

  const [activeDashboardTab, setActiveDashboardTab] = useState<DashboardContentTab>('tasks');
  const tabRefs = useRef<Record<DashboardContentTab, HTMLButtonElement | null>>({
    tasks: null,
    leadership: null,
    usage: null,
    inference: null,
    projects: null,
    skills: null,
  });

  const focusTabButton = (tabId: DashboardContentTab) => {
    tabRefs.current[tabId]?.focus();
  };

  const handleLowerTabKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') {
      return;
    }

    const currentIndex = DASHBOARD_TABS.findIndex((item) => item.id === activeDashboardTab);
    if (currentIndex < 0) return;

    event.preventDefault();
    event.stopPropagation();

    const nextIndex =
      event.key === 'ArrowRight'
        ? (currentIndex + 1) % DASHBOARD_TABS.length
        : (currentIndex - 1 + DASHBOARD_TABS.length) % DASHBOARD_TABS.length;
    const nextTab = DASHBOARD_TABS[nextIndex].id;
    setActiveDashboardTab(nextTab);

    requestAnimationFrame(() => {
      focusTabButton(nextTab);
    });
  };

  return (
    <div className="space-y-4 dashboard-home">
      <div className="dashboard-home-overview">
        <LeadershipOverviewCard
          signal={signal}
          hasUsage={hasUsage}
          onOpen={() => setActiveDashboardTab('leadership')}
        />

        <QuotaOverview snapshot={snapshot} sourceLabel={quotaSourceLabel} onRefresh={onQuotaRefresh} />

        <section className="dashboard-home-metrics" aria-label={t('dashboard.aria.localTokenMetrics')}>
          <StatCard
            label={t('dashboard.metrics.today')}
            value={formatQuantity(hasUsage ? usage?.today_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.cost', { value: formatUSD(detailed.today.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            subValueTitle={detailed ? (detailed.today.uses_reference_pricing ? referenceCostNote : costNote) : undefined}
            icon={<Activity size={16} />}
            compact
            accent="primary"
          />
          <StatCard
            label={t('dashboard.metrics.sevenDay')}
            value={formatQuantity(hasUsage ? usage?.seven_day_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.cost', { value: formatUSD(detailed.seven_day.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            subValueTitle={detailed ? (detailed.seven_day.uses_reference_pricing ? referenceCostNote : costNote) : undefined}
            icon={<Calendar size={16} />}
            compact
            accent="secondary"
          />
          <StatCard
            label={t('dashboard.metrics.lifetime')}
            value={formatQuantity(hasUsage ? usage?.lifetime_tokens ?? null : null)}
            subValue={
              detailed
                ? t('dashboard.metrics.cost', { value: formatUSD(detailed.lifetime.estimated_cost_usd) })
                : t('dashboard.metrics.recordInsufficient')
            }
            subValueTitle={detailed ? (detailed.lifetime.uses_reference_pricing ? referenceCostNote : costNote) : undefined}
            icon={<TrendingUp size={16} />}
            compact
            accent="tertiary"
          />
        </section>

        <div className="dashboard-home-monthly">
          <MonthlyValueProgress usage={usage} />
        </div>
      </div>

      <div
        onKeyDown={handleLowerTabKeyDown}
        role="tablist"
        aria-label={t('dashboard.aria.lowerTabs')}
        className="flex items-center gap-1.5 flex-wrap rounded-2xl p-1 glass-toolbar"
      >
        {DASHBOARD_TABS.map((tab) => (
          <button
            key={tab.id}
            id={`dashboard-home-tab-${tab.id}`}
            role="tab"
            aria-selected={activeDashboardTab === tab.id}
            aria-controls={`dashboard-home-panel-${tab.id}`}
            tabIndex={activeDashboardTab === tab.id ? 0 : -1}
            ref={(element) => {
              tabRefs.current[tab.id] = element;
            }}
            onClick={() => setActiveDashboardTab(tab.id)}
            className={`px-3 py-2 rounded-xl text-sm transition-all min-w-[90px] ${
              activeDashboardTab === tab.id ? 'glass-button-solid' : 'text-secondary glass-button'
            }`}
          >
            {t(tab.titleKey)}
          </button>
        ))}
      </div>

      {activeDashboardTab === 'tasks' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-tasks"
          aria-labelledby="dashboard-home-tab-tasks"
        >
          <TaskBoardPanel taskBoard={snapshot?.task_board ?? null} />
        </section>
      )}

      {activeDashboardTab === 'leadership' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-leadership"
          aria-labelledby="dashboard-home-tab-leadership"
        >
          <LeadershipPanel signal={signal} />
        </section>
      )}

      {activeDashboardTab === 'usage' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-usage"
          aria-labelledby="dashboard-home-tab-usage"
        >
          <UsagePanel usage={usage} />
        </section>
      )}

      {activeDashboardTab === 'inference' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-inference"
          aria-labelledby="dashboard-home-tab-inference"
        >
          <InferencePerformancePanel inference={usage?.inference_performance ?? null} />
        </section>
      )}

      {activeDashboardTab === 'projects' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-projects"
          aria-labelledby="dashboard-home-tab-projects"
        >
          <ProjectsPanel
            projectBoard={usage?.project_board ?? null}
          />
        </section>
      )}

      {activeDashboardTab === 'skills' && (
        <section
          role="tabpanel"
          id="dashboard-home-panel-skills"
          aria-labelledby="dashboard-home-tab-skills"
        >
          <SkillsPanel
            skills={usage?.skill_usages ?? []}
            tools={usage?.tool_usages ?? []}
          />
        </section>
      )}
    </div>
  );
}
