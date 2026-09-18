import { createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { Pill } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/finance/reconciliation")({
  head: () => ({
    meta: [
      { title: "Do the books tie — Clove ERP" },
      {
        name: "description",
        content:
          "Whether this organisation's accounts agree with themselves: the trial balance, the ageings against their control accounts, the subledgers and the stock valuation.",
      },
      { property: "og:title", content: "Do the books tie — Clove ERP" },
      {
        property: "og:description",
        content:
          "Four ties, checked against the ledger as the screen is opened, each with what to do when it does not hold.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Reconciliation />
    </Gate>
  ),
});

/** Shaped by public.erp_book_ties(). */
type Tie = {
  code: string;
  tie: string;
  what_it_means: string;
  /** Three states: a check that could not be run is neither holding nor broken. */
  verdict: "holds" | "broken" | "unknown";
  summary: string | null;
  finding: string | null;
  next_action: string;
  seq: number;
};

type Ties = {
  checked_at: string;
  ties: Tie[];
  total: number;
  broken: number;
  unknown: number;
  all_hold: boolean;
};

/**
 * Whether the books tie, for the person's own organisation.
 *
 * The database has reconciled itself on every deploy since September and a
 * customer could not read a word of it. The checks were reachable —
 * erp_platform_assurance runs the tenant-scoped ones inside the caller's
 * organisation — but only on /operations/assurance, which lists every
 * structural assertion the product makes about itself, by the name of the
 * assertion, under a paragraph about the check register. That is the builder's
 * screen and it should stay one.
 *
 * This is the finance reading of the same four checks: what each means, whether
 * it holds right now, and — when it does not — the difference the check found
 * and where to go and fix it. Nothing else: no history, no run button, no count
 * of how many checks the platform has. A tie either holds or it does not, and
 * the only useful thing beside a broken one is what to do about it.
 */
function Reconciliation() {
  const { t, ui } = useT();

  const ties = useQuery({
    queryKey: ["erp_book_ties"],
    queryFn: () => callErp<Ties>("erp_book_ties", {}),
  });

  const data = ties.data;
  const rows = data?.ties ?? [];
  const failing = rows.filter((r) => r.verdict !== "holds");

  const tone = (verdict: Tie["verdict"]): "ok" | "warn" | "bad" =>
    verdict === "holds" ? "ok" : verdict === "unknown" ? "warn" : "bad";

  const label = (verdict: Tie["verdict"]): string =>
    verdict === "holds"
      ? ui("Holds")
      : verdict === "unknown"
        ? ui("Could not be checked")
        : ui("Does not hold");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.finance_reconciliation", "Do the books tie")}>
        Four things have to be true for these accounts to be right. Each is checked against the
        ledger as this screen is opened — for your organisation and no other — and the one that does
        not hold says by how much and what to do about it.
      </PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
        {ties.isPending ? (
          <p role="status" className="text-sm text-muted-foreground">
            {ui("Reading the ledger…")}
          </p>
        ) : (
          <>
            <p className="text-sm font-semibold">
              {data?.all_hold ? ui("All four ties hold.") : failing.map((r) => r.tie).join(" · ")}
            </p>
            <p className="mt-1 text-xs text-muted-foreground">
              {ui("Checked against the ledger just now.")}
            </p>
          </>
        )}
      </section>

      {rows.length > 0 ? (
        <ul className="flex min-w-0 flex-col gap-3">
          {rows.map((r) => (
            <li
              key={r.code}
              className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5"
            >
              <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                <h2 className="text-sm font-semibold">{r.tie}</h2>
                <Pill tone={tone(r.verdict)}>{label(r.verdict)}</Pill>
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{r.what_it_means}</p>

              {/* Only the failing one earns more of the screen. */}
              {r.verdict !== "holds" ? (
                <div className="mt-3 border-t border-border pt-3">
                  {r.finding ? (
                    <pre className="max-w-full overflow-x-auto whitespace-pre-wrap break-words text-xs text-destructive">
                      {r.finding}
                    </pre>
                  ) : null}
                  <p className="mt-2 text-xs">
                    <span className="font-medium">{ui("What to do")}</span>{" "}
                    <span className="text-muted-foreground">{r.next_action}</span>
                  </p>
                </div>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
