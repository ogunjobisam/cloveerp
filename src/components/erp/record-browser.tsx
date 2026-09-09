import { useEffect, useRef, useState, type ReactNode } from "react";

import { ErrorNote } from "./action";
import { EmptyState, Prose } from "./page";

/**
 * A list that stays beside the record it opened.
 *
 * The master-data screen used to be two flat tables and nothing else: you
 * could see that a product existed and read five of its columns, and there
 * was no way to open one. Everything the database already knows about an item
 * — its group, its stock unit, whether it is batch, serial or expiry
 * controlled, how it is classified, who supplies it — was unreachable from
 * the screen whose whole job is products.
 *
 * The shape here is the one Sage X3 uses for the same problem, and the reason
 * it is worth copying is not that it looks like an ERP. It is that master data
 * is read by comparison: you are rarely after one product, you are after the
 * one of forty that is set up differently from the other thirty-nine. A record
 * page you reach by navigating away makes that a round trip each time. Keeping
 * the list mounted makes it one click, and the filter boxes stay where they
 * were while you walk down the rows.
 *
 * Two decisions worth stating, because both could reasonably have gone the
 * other way:
 *
 *   - The rows are buttons in a list, not cells in a table with a click
 *     handler. A <tr onClick> is unreachable from a keyboard and announces
 *     nothing about being selectable, and this product ships an accessibility
 *     statement with checks behind it. The grid template makes it read as a
 *     table anyway.
 *
 *   - What was recently opened lives in localStorage. It is a navigation
 *     convenience for one person at one browser — nobody else reads it back,
 *     and it is not worth a tenant-scoped table, a door and a suite. Every
 *     access is wrapped: a browser with site data blocked throws on the
 *     property itself, and the list must still render.
 */

export type BrowserColumn<T> = {
  key: string;
  header: string;
  /** The text a filter matches on, and the cell's content unless render says otherwise. */
  value: (row: T) => string;
  render?: (row: T) => ReactNode;
  /** Filterable columns get a box under the header, the way X3 puts one there. */
  filter?: boolean;
};

type Recent = { id: string; label: string; sub: string };

const RECENT_LIMIT = 6;

/**
 * Which filter box goes to the database.
 *
 * The doors take one `p_search` and match it against code OR name, so only one
 * box can be sent. The first filled one is, and every filled box also narrows
 * client-side — which is exact rather than approximate, because the server's
 * OR always returns a superset of what the client then narrows to:
 *
 *   code only  → server returns code-or-name matches; client keeps code matches
 *   name only  → server returns code-or-name matches; client keeps name matches
 *   both       → server returns code matches; client keeps code AND name
 *
 * The point of sending anything at all is the limit. A filter applied only to
 * the loaded page reports "no matches" for a product that exists just past it,
 * and a screen that says a thing does not exist when it does is worse than one
 * that is slow.
 */
export function serverSearchTerm<T>(
  columns: BrowserColumn<T>[],
  filters: Record<string, string>,
): string {
  const filled = columns.filter((c) => c.filter && (filters[c.key] ?? "").trim() !== "");
  return filled.length === 0 ? "" : (filters[filled[0]!.key] ?? "").trim();
}

/** Every filled box narrows, case-insensitively, on the column it sits under. */
export function narrow<T>(
  rows: T[],
  columns: BrowserColumn<T>[],
  filters: Record<string, string>,
): T[] {
  return rows.filter((row) =>
    columns.every((c) => {
      const term = (filters[c.key] ?? "").trim().toLowerCase();
      return term === "" || c.value(row).toLowerCase().includes(term);
    }),
  );
}

function readRecents(key: string): Recent[] {
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    // Written by an earlier version of this code, so it is ours — but it is
    // still parsed rather than trusted, because a half-written value survives
    // a crash and would otherwise render as undefined.
    return parsed
      .filter(
        (r): r is Recent =>
          typeof r === "object" &&
          r !== null &&
          typeof (r as Recent).id === "string" &&
          typeof (r as Recent).label === "string",
      )
      .slice(0, RECENT_LIMIT);
  } catch {
    return [];
  }
}

function writeRecents(key: string, next: Recent[]): void {
  try {
    window.localStorage.setItem(key, JSON.stringify(next.slice(0, RECENT_LIMIT)));
  } catch {
    // A private window, or site data blocked. The list is a convenience and
    // the screen is fully usable without it.
  }
}

export function RecordBrowser<T>({
  nounSingular,
  nounPlural,
  title,
  description,
  headerAction,
  columns,
  gridTemplate,
  rows,
  isPending,
  error,
  limit,
  onSearchChange,
  idOf,
  titleOf,
  subtitleOf,
  detail,
  recentsKey,
}: {
  nounSingular: string;
  nounPlural: string;
  title: string;
  description: string;
  headerAction?: ReactNode;
  columns: BrowserColumn<T>[];
  /**
   * The Tailwind grid-template-columns class for the list, e.g.
   * `grid-cols-[7rem_minmax(0,1fr)]`. It has to be a literal at the call site
   * rather than assembled here: Tailwind scans source text for class names,
   * and a string this component built at runtime would never be generated.
   */
  gridTemplate: string;
  rows: T[] | undefined;
  isPending: boolean;
  error: unknown;
  /** What the query asked for, so a full page can be reported as possibly truncated. */
  limit: number;
  /**
   * The search term the query should send to the door.
   *
   * The doors take one `p_search` and match it against code OR name, so the
   * first filled filter box is what goes to the server and every filled box
   * also narrows client-side. That is exact rather than approximate in all
   * three cases: one box filled means the server returns a superset (code or
   * name) which the client narrows to that column; both filled means the
   * server returns the code superset which the client narrows to both. The
   * point of sending anything at all is that a filter over only the loaded
   * page would report "no matches" for a product that exists past the limit.
   */
  onSearchChange: (search: string) => void;
  idOf: (row: T) => string;
  titleOf: (row: T) => string;
  subtitleOf: (row: T) => string;
  detail: (row: T) => ReactNode;
  recentsKey: string;
}) {
  const [filters, setFilters] = useState<Record<string, string>>({});
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [recents, setRecents] = useState<Recent[]>([]);

  // localStorage is not readable while rendering on the server, so the recents
  // arrive after mount rather than in the first paint.
  useEffect(() => setRecents(readRecents(recentsKey)), [recentsKey]);

  // Debounced, because every keystroke would otherwise be a round trip.
  const serverTerm = serverSearchTerm(columns, filters);
  const lastSent = useRef<string | null>(null);
  useEffect(() => {
    const timer = setTimeout(() => {
      if (lastSent.current === serverTerm) return;
      lastSent.current = serverTerm;
      onSearchChange(serverTerm);
    }, 250);
    return () => clearTimeout(timer);
  }, [serverTerm, onSearchChange]);

  const all = rows ?? [];
  const visible = narrow(all, columns, filters);

  // Resolved against everything loaded rather than against what survives the
  // filters. Typing in a filter box must not close the record you are reading
  // — that is the whole reason the list and the record are on one screen — and
  // narrowing to compare two rows is exactly when it would happen.
  const selected = all.find((r) => idOf(r) === selectedId) ?? null;
  const truncated = all.length >= limit;

  function open(row: T) {
    const id = idOf(row);
    setSelectedId(id);
    const entry: Recent = { id, label: titleOf(row), sub: subtitleOf(row) };
    const next = [entry, ...recents.filter((r) => r.id !== id)].slice(0, RECENT_LIMIT);
    setRecents(next);
    writeRecents(recentsKey, next);
  }

  /**
   * Reopen something from the recents list.
   *
   * The recents outlive the page, so an entry can name a record that is not in
   * the loaded set — it is past the limit, or the filters exclude it, or it was
   * archived last week. Setting the id alone would leave the button doing
   * visibly nothing, so when the record is not loaded this puts its code in the
   * first filter box instead: the search reaches the whole set, and if the
   * record has genuinely gone the list says "no matches" rather than staying
   * silent.
   */
  function reopen(r: Recent) {
    setSelectedId(r.id);
    if (all.some((row) => idOf(row) === r.id)) return;
    const first = columns.find((c) => c.filter);
    if (first) setFilters({ [first.key]: r.label });
  }

  const template = `grid items-center gap-3 ${gridTemplate}`;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold">{title}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
        </div>
        {headerAction}
      </header>

      <div className="grid min-w-0 lg:grid-cols-[minmax(0,20rem)_minmax(0,1fr)]">
        {/* ── The list ─────────────────────────────────────────────────── */}
        <div
          className={`min-w-0 border-border lg:border-r ${selected ? "hidden lg:block" : "block"}`}
        >
          <div className={`${template} border-b border-border px-4 py-2 sm:px-5`}>
            {columns.map((c) => (
              <span
                key={c.key}
                className="truncate text-[11px] font-medium uppercase tracking-wide text-muted-foreground"
              >
                {c.header}
              </span>
            ))}
          </div>

          <div className={`${template} border-b border-border px-4 py-2 sm:px-5`}>
            {columns.map((c) =>
              c.filter ? (
                <input
                  key={c.key}
                  type="search"
                  value={filters[c.key] ?? ""}
                  onChange={(e) => setFilters((f) => ({ ...f, [c.key]: e.target.value }))}
                  aria-label={`Filter ${nounPlural} by ${c.header.toLowerCase()}`}
                  placeholder="Filter"
                  className="min-w-0 rounded-md border border-border bg-background px-2 py-1 text-xs outline-none focus-visible:border-accent focus-visible:ring-2 focus-visible:ring-accent/30"
                />
              ) : (
                <span key={c.key} />
              ),
            )}
          </div>

          <div className="max-h-[32rem] overflow-y-auto">
            {isPending ? (
              <p role="status" className="px-4 py-4 text-sm text-muted-foreground sm:px-5">
                Loading…
              </p>
            ) : error ? (
              // ErrorNote rather than the title alone.
              //
              // This rendered friendlyError(error).title and stopped, so a
              // refusal arrived as "You do not have permission to do this."
              // and nothing else — while the engine had sent
              // "inventory.read is required to list items" and the hint "Ask
              // an administrator to grant inventory.read." friendlyError
              // assembles all of it and its own comment says the engine's hint
              // wins over the register; this component was throwing that away
              // on the main way anybody lists records. action.tsx, kpi.tsx and
              // profile.tsx already showed it, so this was an inconsistency
              // rather than a decision.
              <div className="px-4 py-4 sm:px-5">
                <ErrorNote error={error} />
              </div>
            ) : visible.length === 0 ? (
              <div className="px-4 py-4 sm:px-5">
                <EmptyState
                  message={
                    all.length === 0
                      ? `No ${nounPlural} yet.`
                      : `No ${nounPlural} match those filters.`
                  }
                />
              </div>
            ) : (
              <ul>
                {visible.map((row) => {
                  const id = idOf(row);
                  const isOpen = id === selectedId;
                  return (
                    <li key={id}>
                      <button
                        type="button"
                        onClick={() => open(row)}
                        aria-current={isOpen ? "true" : undefined}
                        className={`${template} w-full border-b border-border/50 px-4 py-2 text-left outline-none last:border-0 hover:bg-muted/60 focus-visible:bg-muted focus-visible:ring-2 focus-visible:ring-accent/40 sm:px-5 ${
                          isOpen ? "bg-muted" : ""
                        }`}
                      >
                        {columns.map((c) => (
                          <span key={c.key} className="min-w-0 truncate text-xs">
                            {c.render ? c.render(row) : c.value(row)}
                          </span>
                        ))}
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>

          <p className="border-t border-border px-4 py-2 text-[11px] text-muted-foreground sm:px-5">
            {visible.length} of {all.length} {all.length === 1 ? nounSingular : nounPlural}
            {/* Said plainly, because a filter that silently stops at the page
                boundary is a "no matches" for something that exists. */}
            {truncated ? ` — the first ${limit}. Filter to reach the rest.` : ""}
          </p>

          {recents.length > 0 ? (
            <div className="border-t border-border px-4 py-3 sm:px-5">
              <h3 className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                Recently opened
              </h3>
              <ul className="mt-1.5 grid gap-0.5">
                {recents.map((r) => (
                  <li key={r.id}>
                    <button
                      type="button"
                      onClick={() => reopen(r)}
                      className="w-full truncate rounded-md px-1.5 py-1 text-left text-xs text-muted-foreground outline-none hover:bg-muted hover:text-foreground focus-visible:bg-muted focus-visible:ring-2 focus-visible:ring-accent/40"
                    >
                      <span className="font-mono">{r.label}</span>
                      {r.sub ? <span className="ml-2">{r.sub}</span> : null}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>

        {/* ── The record ───────────────────────────────────────────────── */}
        <div className={`min-w-0 ${selected ? "block" : "hidden lg:block"}`}>
          {selected ? (
            <div className="min-w-0 px-4 py-4 sm:px-5">
              <button
                type="button"
                onClick={() => setSelectedId(null)}
                className="mb-3 rounded-md text-xs text-muted-foreground underline underline-offset-4 outline-none hover:text-foreground focus-visible:ring-2 focus-visible:ring-accent/40 lg:hidden"
              >
                ← All {nounPlural}
              </button>
              {detail(selected)}
            </div>
          ) : (
            <div className="px-4 py-10 sm:px-5">
              <p className="text-sm text-muted-foreground">
                Choose a {nounSingular} on the left to see everything recorded about it.
              </p>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

/** One labelled value in a record. */
export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </dt>
      <dd className="mt-0.5 truncate text-sm">{children}</dd>
    </div>
  );
}

/** A titled group of fields within an open record. */
export function RecordSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="mt-5 first:mt-0">
      <h3 className="border-b border-border pb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {title}
      </h3>
      <div className="pt-3">{children}</div>
    </section>
  );
}
