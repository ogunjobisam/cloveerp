import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { callErp } from "../../lib/erp";

/**
 * A panel backed by one `public.erp_*` call.
 *
 * Loading, error and empty are three different states and are rendered as
 * three different things. Collapsing error into empty is the specific mistake
 * worth avoiding here: a screen that shows "nothing to report" when the query
 * failed is actively misleading on exactly the screens where being misled
 * matters — an operations view whose whole purpose is to tell you when
 * something is wrong.
 */
export function DataPanel<T>({
  title,
  description,
  fn,
  args,
  empty,
  children,
}: {
  title: string;
  description?: string;
  fn: string;
  args?: Record<string, unknown>;
  empty: string;
  children: (rows: T[]) => ReactNode;
}) {
  const { data, isPending, error, refetch, isFetching } = useQuery({
    queryKey: [fn, args ?? {}],
    queryFn: () => callErp<T[]>(fn, args ?? {}),
    refetchInterval: 30_000,
  });

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="flex items-start justify-between gap-4 border-b border-border px-5 py-4">
        <div>
          <h2 className="text-sm font-semibold">{title}</h2>
          {description ? (
            <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
          ) : null}
        </div>
        <button
          onClick={() => refetch()}
          disabled={isFetching}
          className="shrink-0 rounded-md border border-input px-2.5 py-1 text-xs font-medium disabled:opacity-50"
        >
          {isFetching ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      <div className="px-5 py-4">
        {isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : error ? (
          <div role="alert">
            <p className="text-sm font-medium text-destructive">This did not load.</p>
            <p className="mt-1 text-xs text-muted-foreground">{(error as Error).message}</p>
          </div>
        ) : !data || data.length === 0 ? (
          <p className="text-sm text-muted-foreground">{empty}</p>
        ) : (
          children(data)
        )}
      </div>
    </section>
  );
}

export function Table({ columns, children }: { columns: string[]; children: ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[36rem] text-left text-sm">
        <thead>
          <tr className="border-b border-border">
            {columns.map((c) => (
              <th
                key={c}
                className="pb-2 pr-4 text-xs font-medium uppercase tracking-wide text-muted-foreground"
              >
                {c}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>{children}</tbody>
      </table>
    </div>
  );
}

export function Pill({
  tone,
  children,
}: {
  tone: "ok" | "warn" | "bad" | "muted";
  children: ReactNode;
}) {
  const cls = {
    ok: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
    warn: "bg-amber-500/10 text-amber-700 dark:text-amber-400",
    bad: "bg-destructive/10 text-destructive",
    muted: "bg-muted text-muted-foreground",
  }[tone];

  return (
    <span className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${cls}`}>
      {children}
    </span>
  );
}
