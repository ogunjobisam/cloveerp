import type { ReactNode } from "react";

import { DataPanel, Pill, Table } from "./panel";

/**
 * The plain reporting panel.
 *
 * Most of the ERP's read surface is a function that returns rows and a screen
 * that shows them. Writing that by hand eleven times produces eleven slightly
 * different tables; declaring the columns produces one. Anything that needs a
 * bespoke cell keeps using DataPanel directly.
 */

export type Column<T> = {
  header: string;
  /** Key on the row, or a function for anything derived. */
  cell: keyof T | ((row: T) => ReactNode);
  /** Right-align numbers so columns of figures line up. */
  numeric?: boolean;
};

export function AutoPanel<T extends Record<string, unknown>>({
  title,
  description,
  fn,
  args,
  empty,
  columns,
  rowKey,
}: {
  title: string;
  description?: string;
  fn: string;
  args?: Record<string, unknown>;
  empty: string;
  columns: Column<T>[];
  rowKey: (row: T, index: number) => string;
}) {
  return (
    <DataPanel<T>
      title={title}
      {...(description ? { description } : {})}
      fn={fn}
      {...(args ? { args } : {})}
      empty={empty}
    >
      {(rows) => (
        <Table columns={columns.map((c) => c.header)}>
          {rows.map((row, i) => (
            <tr key={rowKey(row, i)} className="border-b border-border/50 last:border-0">
              {columns.map((c) => (
                <td
                  key={c.header}
                  className={`py-2 pr-4 ${c.numeric ? "text-right tabular-nums" : ""}`}
                >
                  {typeof c.cell === "function" ? c.cell(row) : render(row[c.cell])}
                </td>
              ))}
            </tr>
          ))}
        </Table>
      )}
    </DataPanel>
  );
}

function render(value: unknown): ReactNode {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

/** A status word, coloured by whether it is a good one. */
export function StatusPill({ value }: { value: unknown }) {
  const s = String(value ?? "").toLowerCase();
  const bad = ["failed", "error", "rejected", "blocked", "quarantined", "overdue", "breached"];
  const warn = ["pending", "open", "draft", "planned", "proposed", "on_hold", "held", "partial"];
  const ok = ["active", "closed", "posted", "released", "completed", "approved", "applied", "ok"];
  const tone = bad.some((x) => s.includes(x))
    ? "bad"
    : ok.some((x) => s === x || s.includes(x))
      ? "ok"
      : warn.some((x) => s.includes(x))
        ? "warn"
        : "muted";
  return <Pill tone={tone}>{String(value ?? "—")}</Pill>;
}

/** A date, shown short, never invented when absent. */
export function shortDate(value: unknown): string {
  if (!value) return "—";
  const d = new Date(String(value));
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "2-digit" });
}
