import { useQuery } from "@tanstack/react-query";
import { Boxes, Clock, FileText, Gauge, PoundSterling } from "lucide-react";

import { callErp } from "../../lib/erp";
import { friendlyError } from "../../lib/errors";
import { useT } from "../../lib/i18n";
import type { Chart, Kpi, Row } from "../../lib/modules";

/**
 * The numbers at the top of a module.
 *
 * A KPI here is derived in the browser from the same read the tables below use,
 * not from a separate aggregate. That is a deliberate constraint: a headline
 * figure that disagrees with the list under it destroys confidence in both, and
 * the cheapest way to guarantee agreement is to compute one from the other.
 *
 * Three states, three renderings, same as every other panel: loading is not
 * zero, and failure is not zero either. A tile that shows "0 overdue" because
 * the query failed is the worst possible lie for this kind of screen.
 */

const TONE = {
  ok: "text-emerald-600 dark:text-emerald-400",
  warn: "text-amber-600 dark:text-amber-400",
  bad: "text-destructive",
} as const;

/**
 * Which mark sits in the tile's amber disc.
 *
 * A figure reads faster with something to recognise beside it, and the label is
 * the only thing the tile knows about itself, so the mark is chosen from the
 * words: money, stock, time, documents, everything else.
 */
function markFor(label: string) {
  const l = label.toLowerCase();
  if (/(value|cost|cash|bank|payment|invoice|balance|price|£)/.test(l)) return PoundSterling;
  if (/(stock|item|quantity|batch|bin|location)/.test(l)) return Boxes;
  if (/(overdue|due|late|age|day)/.test(l)) return Clock;
  if (/(order|document|receipt|note|request)/.test(l)) return FileText;
  return Gauge;
}

export function KpiTile({ kpi }: { kpi: Kpi }) {
  const { ui } = useT();
  const { data, isPending, error } = useQuery({
    queryKey: [kpi.fn, kpi.args ?? {}],
    queryFn: () => callErp<Row[]>(kpi.fn, kpi.args ?? {}),
    refetchInterval: 60_000,
  });

  const result = data ? kpi.compute(data) : null;
  const label = ui(kpi.label);
  const Mark = markFor(label);

  return (
    <div className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 shadow-[var(--shadow-card)]">
      <div className="flex min-w-0 items-center gap-2.5">
        <span className="grid size-9 shrink-0 place-items-center rounded-full bg-accent-soft text-accent">
          <Mark className="size-4.5" aria-hidden="true" />
        </span>
        <p className="truncate text-sm font-medium">{label}</p>
      </div>

      {isPending ? (
        <div className="mt-3 h-8 w-24 animate-pulse rounded bg-muted" />
      ) : error ? (
        <>
          <p className="mt-2 text-3xl font-semibold text-muted-foreground">—</p>
          <p className="mt-1 truncate text-xs text-destructive">{friendlyError(error).title}</p>
        </>
      ) : result ? (
        <>
          <p
            className={`mt-2 font-display text-3xl font-semibold tabular-nums ${result.tone ? TONE[result.tone] : ""}`}
          >
            {result.value}
          </p>
          {result.hint ? (
            <p className="mt-1 truncate text-xs text-muted-foreground">{ui(result.hint)}</p>
          ) : null}
        </>
      ) : (
        <>
          <p className="mt-2 text-3xl font-semibold text-muted-foreground">—</p>
          <p className="mt-1 text-xs text-muted-foreground">Nothing recorded yet.</p>
        </>
      )}
    </div>
  );
}

export function KpiRow({ kpis }: { kpis: Kpi[] }) {
  if (kpis.length === 0) return null;
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {kpis.map((k) => (
        <KpiTile key={`${k.fn}-${k.label}`} kpi={k} />
      ))}
    </div>
  );
}

/**
 * One chart, drawn without a charting library.
 *
 * A horizontal bar per category is the whole requirement: these are small
 * categorical breakdowns — age bands, statuses, customers — and a bar whose
 * width is a percentage of the largest is honest about the comparison it is
 * making. Adding a chart runtime for that would be more code shipped than
 * insight gained.
 */
export function MiniBars({ chart }: { chart: Chart }) {
  const { ui } = useT();
  const { data, isPending, error } = useQuery({
    queryKey: [chart.fn, chart.args ?? {}],
    queryFn: () => callErp<Row[]>(chart.fn, chart.args ?? {}),
    refetchInterval: 60_000,
  });

  const grouped = new Map<string, number>();
  for (const row of data ?? []) {
    const label = chart.label(row);
    grouped.set(label, (grouped.get(label) ?? 0) + chart.value(row));
  }
  const bars = [...grouped.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);
  const max = bars.reduce((m, [, v]) => Math.max(m, v), 0);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{ui(chart.title)}</h2>
        {chart.description ? (
          <p className="mt-0.5 text-xs text-muted-foreground">{ui(chart.description)}</p>
        ) : null}
      </header>

      <div className="px-4 py-4 sm:px-5">
        {isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : error ? (
          <div role="alert">
            <p className="text-sm font-medium text-destructive">This did not load.</p>
            <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
          </div>
        ) : bars.length === 0 ? (
          <p className="text-sm text-muted-foreground">{ui(chart.empty)}</p>
        ) : (
          <ul className="flex flex-col gap-2">
            {bars.map(([label, value]) => (
              <li key={label} className="grid grid-cols-[8rem_1fr_4rem] items-center gap-3">
                <span className="truncate text-xs text-muted-foreground">{label}</span>
                <span className="h-2 rounded-full bg-muted">
                  <span
                    className="block h-2 rounded-full bg-primary"
                    style={{ width: `${max === 0 ? 0 : Math.max(2, (value / max) * 100)}%` }}
                  />
                </span>
                <span className="text-right text-xs tabular-nums">
                  {Math.round(value).toLocaleString()}
                  {chart.unit ?? ""}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
