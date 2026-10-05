import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useRef, useState, type ReactNode } from "react";

import { ErpError, callErp } from "../../lib/erp";
import { EmptyState, LoadingRows, Prose } from "./page";

/** A read that took longer than this is asked again only when somebody asks. */
const SLOW_READ_MS = 5_000;

/**
 * Whether a panel has come into view, or near it.
 *
 * Opening Finance's Reports tab asked for all nine reports at once; they queued
 * behind each other in the database and each took five to eight seconds
 * (J-136). A lazy panel is read the first time it comes within a screen's
 * reach and stays read after. Not a fetch: it only says when the query may run.
 * Where the browser cannot say what is in view, every panel is read, as before.
 */
function useSeen(lazy: boolean) {
  const ref = useRef<HTMLElement>(null);
  const [seen, setSeen] = useState(!lazy);
  const observable = typeof IntersectionObserver !== "undefined";
  useEffect(() => {
    const el = ref.current;
    if (seen || !observable || !el) return;
    const watch = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setSeen(true);
          watch.disconnect();
        }
      },
      { rootMargin: "200px 0px" },
    );
    watch.observe(el);
    return () => watch.disconnect();
  }, [seen, observable]);
  return { ref, seen: seen || !observable };
}

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
  lazy = false,
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
  /** Read only once the panel scrolls into view, for a page of many panels. */
  lazy?: boolean;
  children: (rows: T[]) => ReactNode;
}) {
  const { ref, seen } = useSeen(lazy);
  // How long the last read took. A slow read is not repeated on a timer: the
  // checks screen runs every structural check against the database, twenty
  // seconds of it, and asked again every thirty for as long as the screen
  // stood open. On live that was 228 runs, and while one ran every other
  // screen's reads met the statement timeout (found 4 October 2026). The
  // Refresh button still asks again.
  const took = useRef(0);
  const { data, isPending, error } = useQuery({
    queryKey: [fn, args ?? {}],
    queryFn: async () => {
      const started = performance.now();
      try {
        return await callErp<T[]>(fn, args ?? {});
      } finally {
        took.current = performance.now() - started;
      }
    },
    // Not while it is failing. A refusal polled every thirty seconds is a
    // refusal repeated for as long as the screen is open, and the answer will
    // not have changed.
    refetchInterval: (q) => (q.state.error || took.current > SLOW_READ_MS ? false : 30_000),
    refetchOnWindowFocus: () => took.current <= SLOW_READ_MS,
    enabled: seen,
  });

  // A refusal is not a fault. A panel the account may not read says so in the
  // ordinary voice of the page rather than in red, because nothing is broken:
  // this is simply somebody else's panel.
  const refused = error instanceof ErpError && error.isPermissionDenied;

  // Read, and nothing came back. An empty panel used to print its description,
  // a rule, and then an empty sentence that mostly said the description again.
  // It is now one block: the title, the empty sentence and the way to fix it.
  // Loading, a refusal and a fault are none of them empty, and keep the header.
  const isEmpty = !isPending && !error && (!data || data.length === 0);

  return (
    // min-w-0 so a wide table inside cannot stretch this section past the
    // column it sits in; the table scrolls itself instead.
    <section ref={ref} className="min-w-0 rounded-xl border border-border bg-card">
      <header
        className={isEmpty ? "px-4 pt-4 sm:px-5" : "border-b border-border px-4 py-4 sm:px-5"}
      >
        <h2 className="text-sm font-semibold">{title}</h2>
        {description && !isEmpty ? (
          <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
        ) : null}
      </header>

      <div className={isEmpty ? "px-4 pb-4 pt-2 sm:px-5" : "px-4 py-4 sm:px-5"}>
        {isPending ? (
          // A slow read says what it is doing in words; anything else shows the
          // shape of what is coming, the same as every other panel.
          loading ? (
            <p role="status" className="text-sm text-muted-foreground">
              {loading}
            </p>
          ) : (
            <LoadingRows />
          )
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
    // better than one that moves the whole page. A shadow at an edge says
    // there is more that way, which a clipped column never did (J-88).
    <div className="scroll-shadow-x w-full max-w-full overflow-x-auto">
      <table className="w-full min-w-[36rem] text-left text-sm">
        <thead>
          <tr className="border-b border-border">
            {columns.map((c, i) => (
              <th
                key={`${c}-${i}`}
                scope="col"
                className="whitespace-nowrap pb-2 pr-4 text-xs font-medium uppercase tracking-wide text-muted-foreground"
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
