import { BadgeDollarSign } from 'lucide-react';
import type { LocalUsage } from '../types/models';
import { useI18n } from '../i18n/I18nProvider';
import { formatQuantity } from '../utils/formatQuantity';

interface MonthlyValueProgressProps {
  usage: LocalUsage | null | undefined;
}

const REFERENCE_CAP = 46500;
const FLAT_THRESHOLD = 200;
const BASE_PROGRESS = 0.28;
const CAP_PROGRESS = 1;

export function MonthlyValueProgress({ usage }: MonthlyValueProgressProps) {
  const { t } = useI18n();
  const detailed = usage?.detailed_usage ?? null;

  if (detailed === null) {
    return (
      <section className="glass-panel p-4 sm:p-5 dashboard-home-monthly-progress">
        <h3 className="text-sm font-semibold text-primary">{t('monthly.title')}</h3>
        <p className="text-xs text-tertiary mt-1">{t('monthly.insufficient')}</p>
        <p className="mt-3 text-xs text-tertiary">{t('monthly.noDetailedData')}</p>
      </section>
    );
  }

  const monthCost = safeNonNegativeNumber(detailed.month?.estimated_cost_usd);
  const monthTokens = detailed.month ? Math.max(detailed.month.tokens.total_tokens, detailed.month.tokens.input_tokens + detailed.month.tokens.output_tokens) : null;
  if (monthCost === null || (monthCost === 0 && monthTokens !== null && monthTokens > 0)) {
    return (
      <section className="glass-panel p-4 sm:p-5 dashboard-home-monthly-progress">
        <h3 className="text-sm font-semibold text-primary">{t('monthly.title')}</h3>
        {monthTokens !== null && monthTokens > 0 ? <p className="mt-3 text-sm text-primary">{t('monthly.tokens', { value: formatQuantity(monthTokens) })}</p> : null}
        <p className="text-xs text-tertiary mt-1">{t('monthly.insufficient')}</p>
      </section>
    );
  }

  const markers = getMonthlyMarkers();
  const progressPercent = clamp(computeMonthlyProgress(monthCost), 0, 1) * 100;
  const progressValue = `${progressPercent.toFixed(1)}%`;

  return (
    <section className="glass-panel p-4 sm:p-5 dashboard-home-monthly-progress" aria-label={t('monthly.title')}>
      <div className="flex items-start justify-between gap-3 flex-wrap">
        <div>
          <h3 className="text-sm font-semibold text-primary">{t('monthly.title')}</h3>
          <p className="text-xs text-tertiary mt-1">{t('monthly.estimate')}</p>
        </div>
        <p className="text-xs text-tertiary text-right">{t('monthly.reference')}</p>
      </div>

      <div className="h-2 rounded-full mt-3 bg-surface border border-theme overflow-visible relative mb-7">
        <div
          className="h-full rounded-full"
          style={{
            width: progressValue,
            background: 'linear-gradient(90deg, var(--data-primary), var(--data-secondary), var(--data-tertiary))',
            borderRight: monthCost > 0 ? '1px solid color-mix(in oklab, var(--data-tertiary) 65%, transparent)' : 'none',
          }}
        />

        {markers.map((marker) => (
          <Marker key={marker.label} label={marker.label} value={marker.value} positionPercent={marker.positionPercent} />
        ))}
      </div>

      <p className="mt-2 text-xs text-primary">
        <span className="inline-flex items-center gap-1.5">
          <BadgeDollarSign size={14} />
          {t('monthly.estimated', {
            value: formatUSD(monthCost),
            suffix: monthCost === 0 ? t('monthly.noUsageSuffix') : '',
          })}
        </span>
      </p>
    </section>
  );
}

function safeNonNegativeNumber(value: number | null | undefined): number | null {
  if (value == null || !Number.isFinite(value) || value < 0) return null;
  return value;
}

function computeMonthlyProgress(monthCost: number): number {
  const v = clamp(monthCost, 0, REFERENCE_CAP);
  if (v <= FLAT_THRESHOLD) {
    return BASE_PROGRESS * (v / FLAT_THRESHOLD);
  }

  const numerator = Math.log1p((v - FLAT_THRESHOLD) / FLAT_THRESHOLD);
  const denominator = Math.log1p((REFERENCE_CAP - FLAT_THRESHOLD) / FLAT_THRESHOLD);
  const curved = numerator / Math.max(denominator, 1);
  return BASE_PROGRESS + (CAP_PROGRESS - BASE_PROGRESS) * clamp(curved, 0, 1);
}

function getMonthlyMarkers() {
  return [
    { label: 'Plus $20', value: '$20', positionPercent: computeMonthlyProgress(20) * 100 },
    { label: 'Pro100 $100', value: '$100', positionPercent: computeMonthlyProgress(100) * 100 },
    { label: 'Pro200 $200', value: '$200', positionPercent: computeMonthlyProgress(200) * 100 },
    { label: 'Cap $46.5K', value: '$46.5K', positionPercent: computeMonthlyProgress(REFERENCE_CAP) * 100 },
  ];
}

function Marker({ label, value, positionPercent }: { label: string; value: string; positionPercent: number }) {
  const left = `${clamp(positionPercent, 0, 100)}%`;
  return (
    <div
      className="absolute flex flex-col items-center"
      style={{ left, top: '0.45rem' }}
      aria-hidden="true"
      title={label}
    >
      <span className="h-2 w-px" style={{ backgroundColor: 'var(--text-tertiary)' }} />
      <span className="absolute top-2 mt-1 text-[10px] text-tertiary whitespace-nowrap" style={{ transform: positionPercent === 100 ? 'translateX(-100%)' : 'translateX(-50%)' }}>{value}</span>
    </div>
  );
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function formatUSD(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '--';
  return value.toFixed(2);
}
