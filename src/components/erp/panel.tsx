import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { ErpError, callErp } from "../../lib/erp";
import { EmptyState, Prose } from "./page";

/**
 * A panel backed by one `public.erp_*` call.
 *
 * Loading, error and empty are three different states and are rendered as
 * three different things. Collapsing error into empty is the specific mistake
 * worth avoiding here: a screen that shows "nothing to report" when the query
 * failed is actively misleading on exactly the screens where being misled
 * matters — an operations view whose whole purpose is to tell you when
 * something is wrong.
 *
 * There is no per-card refresh. Each panel still polls on its own timer, and
 * the page carries one control that refetches whatever it has mounted — see
 * RefreshButton. A column of identical Refresh buttons was most of the header
 * width on a phone, and none of them did anything the others did not.
 */
export function DataPanel<T>({
  title,
  description,
  fn,
  args,
  empty,
  emptyAction,
  loading,
  children,
}: {
  title: string;
  description?: string;
  fn: string;
  args?: Record<string, unknown>;
  empty: string;
  /**
   * What to do about the emptiness, where there is something to do. Omitted on
   * panels that are empty precisely because nothing is wrong.
   */
  emptyAction?: ReactNode;
  /**
   * What to say while it loads, where a bare "Loading…" would read as stuck.
   * A panel that runs every structural assertion against the database takes
   * the best part of a minute, and saying so is the difference between waiting
   * and reloading.
   */
  loading?: string;
  children: (rows: T[]) => ReactNode;
}) {
  const { data, isPending, error } = useQuery({
    queryKey: [fn, args ?? {}],
    queryFn: () => callErp<T[]>(fn, args ?? {}),
    // Not while it is failing. A refusal polled every thirty seconds is a
    // refusal repeated for as long as the screen is open, and the answer will
    // not have changed.
    refetchInterval: (q) => (q.state.error ? false : 30_000),
  });

  // A refusal is not a fault. A panel the account may not read says so in the
  // ordinary voice of the page rather than in red, because nothing is broken:
  // this is simply somebody else's panel.
  const refused = error instanceof ErpError && error.isPermissionDenied;

  return (
    // min-w-0 so a wide table inside cannot stretch this section past the
    // column it sits in; the table scrolls itself instead.
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{title}</h2>
        {description ? (
          <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
        ) : null}
      </header>

      <div className="px-4 py-4 sm:px-5">
        {isPending ? (
          <p role="status" className="text-sm text-muted-foreground">
            {loading ?? "Loading…"}
          </p>
        ) : refused ? (
          <p role="status" className="text-sm text-muted-foreground">
            This account does not hold the permission this panel needs, so there is nothing to show
            here.
          </p>
        ) : error ? (
          <div role="alert">
            <p className="text-sm font-medium text-destructive">This did not load.</p>
            <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
          </div>
        ) : !data || data.length === 0 ? (
          <EmptyState message={empty} action={emptyAction} />
        ) : (
          children(data)
        )}
      </div>
    </section>
  );
}

export function Table({ columns, children }: { columns: string[]; children: ReactNode }) {
  return (
    // The table keeps its minimum width and scrolls within this box. That is
    // deliberate: a seven-column operational table reflowed into a phone width
    // is unreadable, and a horizontal scroll confined to the table is much
    // better than one that moves the whole page.
    <div className="w-full max-w-full overflow-x-auto">
      <table className="w-full min-w-[36rem] text-left text-sm">
        <thead>
          <tr className="border-b border-border">
            {columns.map((c, i) => (
              <th
                key={`${c}-${i}`}
                scope="col"
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
