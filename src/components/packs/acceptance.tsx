import { useQuery } from "@tanstack/react-query";

import { ErrorNote } from "../erp/action";
import { Prose } from "../erp/page";
import { Pill } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * §13, measured rather than claimed.
 *
 * "Anything requiring a value the pack did not provide and onboarding did not
 * ask for is a gap in the pack, logged against the product." A gap is a
 * finding, and a finding needs somewhere to be read — so this is a screen and
 * not only a test.
 *
 * It says what each clause is short of, in the words of the thing that is
 * missing, which is the difference between "not ready" and something a person
 * can act on this afternoon.
 */

type Clause = {
  clause: number;
  requirement: string;
  ready: boolean;
  missing: string | null;
};

export function Acceptance() {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_pack_acceptance"],
    queryFn: () => callErp<Clause[]>("erp_pack_acceptance", {}),
  });

  const rows = q.data ?? [];
  const ready = rows.filter((c) => c.ready).length;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <div className="flex flex-wrap items-baseline justify-between gap-2">
          <h2 className="text-sm font-semibold">{ui("Readiness")}</h2>
          {rows.length > 0 ? (
            <span className="text-xs text-muted-foreground">
              {ready} of {rows.length} hold
            </span>
          ) : null}
        </div>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Seven things a new organisation should be able to do without further configuration. Where
          one does not hold, what it is short of is named — and something short of a feature is
          usually one switch rather than a project.
        </Prose>
      </header>

      {q.error ? (
        <div className="px-4 py-4 sm:px-5">
          <ErrorNote error={q.error} />
        </div>
      ) : q.isPending ? (
        <p className="px-4 py-6 text-sm text-muted-foreground sm:px-5">Measuring…</p>
      ) : (
        <ol className="divide-y divide-border">
          {rows.map((c) => (
            <li key={c.clause} className="flex flex-wrap gap-3 px-4 py-3 sm:px-5">
              <span className="mt-0.5 shrink-0">
                <Pill tone={c.ready ? "ok" : "warn"}>{c.ready ? ui("holds") : ui("short")}</Pill>
              </span>
              <div className="min-w-0 flex-1">
                <p className="text-sm">{c.requirement}</p>
                {c.missing ? (
                  <p className="mt-0.5 text-xs text-amber-700 dark:text-amber-400">{c.missing}</p>
                ) : null}
              </div>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
