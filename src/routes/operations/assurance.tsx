import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { ChevronDown } from "lucide-react";

import { Gate } from "../../components/erp/gate";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { checkFinding, checkName, readAssurance, type AssuranceCheck } from "../../lib/assurance";
import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";

export const Route = createFileRoute("/operations/assurance")({
  head: () => ({
    meta: [
      { title: "Assurance — Clove ERP" },
      {
        name: "description",
        content: "Automated assurance checks that prove the ledger, stock and postings agree.",
      },
      { property: "og:title", content: "Assurance — Clove ERP" },
      {
        property: "og:description",
        content: "Automated assurance checks that prove the ledger, stock and postings agree.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Assurance />
    </Gate>
  ),
});

/**
 * The verdict, then the failures, then — on request — the list.
 *
 * This screen is the last one both demonstration flows reach, and it used to
 * be a table of a hundred and some check names with a pill beside each. Every
 * row of it was true and none of it was the question: a person who has just
 * closed a period and read four numbers off four screens wants to know whether
 * everything reconciles, and, when it does not, which check and what to do.
 *
 * So the answer is a sentence, the failing ones are the only rows drawn by
 * default, and the full register is a press away with its count on the button.
 * Nothing is dropped — a check that holds is in the list under "Show every
 * check", exactly as it was, with the same three columns.
 */
function Assurance() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Checks and sign-off">
        Whether this database still agrees with itself. Every structural check the product makes of
        itself runs here, live, against this organisation — the whole-database reconciliation among
        them — and the answer is one line before it is a list.
      </PageHeader>

      <DataPanel<AssuranceCheck>
        title="Does everything reconcile?"
        description="Run against this database now, not read from a cached result — the same register the build runs."
        fn="erp_platform_assurance"
        loading="Running every check against this database. This takes up to a minute."
        empty="No checks were returned, which is itself unexpected."
      >
        {(rows) => <Verdict rows={rows} />}
      </DataPanel>
    </div>
  );
}

function Verdict({ rows }: { rows: AssuranceCheck[] }) {
  const { ui } = useT();
  const [showAll, setShowAll] = useState(false);
  const reading = readAssurance(rows);

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <div>
        <p
          className={`text-base font-semibold ${
            reading.state === "violated" ? "text-destructive" : "text-ok"
          }`}
        >
          {reading.state === "violated"
            ? reading.failed.length === 1
              ? ui("One check does not hold.")
              : fill(ui("{count} checks do not hold."), { count: reading.failed.length })
            : reading.state === "partial"
              ? ui("Everything that could run reconciles.")
              : ui("Everything reconciles.")}
        </p>
        <p className="mt-1 text-sm text-muted-foreground">
          {fill(ui("{count} checks held against this database."), { count: reading.held })}
          {reading.skipped > 0
            ? ` ${fill(
                ui(
                  "{count} need an organisation and were not run, because this session is not inside one.",
                ),
                { count: reading.skipped },
              )}`
            : ""}
        </p>
      </div>

      {/* The failing ones, in full. These are the only rows worth a reader's
          attention, so they are the only rows drawn until one is asked for. */}
      {reading.failed.length > 0 ? (
        <div className="flex min-w-0 flex-col gap-3">
          {reading.failed.map((check) => (
            <div
              key={check.check}
              className="min-w-0 rounded-lg border border-destructive/40 bg-destructive/5 p-3"
            >
              <p className="text-sm font-semibold">{check.title ?? check.check}</p>
              {check.blurb ? (
                <p className="mt-0.5 text-xs text-muted-foreground">{check.blurb}</p>
              ) : null}
              <p className="mt-2 break-words text-xs text-destructive">{checkFinding(check)}</p>
              <p className="mt-2 font-mono text-[11px] text-muted-foreground">
                {check.code ?? check.check}
              </p>
            </div>
          ))}
          <p className="text-xs text-muted-foreground">
            {ui(
              "Every one of these fails the build rather than warning, so a check that does not hold on a live database is something to report rather than something to work around. Quote the code under it: it names exactly what was compared and what was found.",
            )}
          </p>
        </div>
      ) : null}

      {/* The register itself. Kept whole, and out of the way until asked for. */}
      <div className="min-w-0 border-t border-border pt-2">
        <button
          type="button"
          onClick={() => setShowAll((v) => !v)}
          aria-expanded={showAll}
          className={`${TOUCH} flex w-full items-center justify-between gap-2 text-sm font-medium`}
        >
          <span>
            {showAll ? ui("Hide the checks") : ui("Show every check")}
            <span className="ml-2 font-normal tabular-nums text-muted-foreground">
              {reading.total}
            </span>
          </span>
          <ChevronDown
            className={`size-4 shrink-0 text-muted-foreground transition-transform ${
              showAll ? "rotate-180" : ""
            }`}
            aria-hidden="true"
          />
        </button>

        {showAll ? (
          <div className="mt-3">
            <Table columns={[ui("Check"), ui("Result"), ui("Detail")]}>
              {rows.map((r) => (
                <tr key={r.check} className="border-b border-border/50 align-top last:border-0">
                  <td className="py-2 pr-4">
                    <div className="text-sm">{checkName(r)}</div>
                    {r.blurb ? (
                      <div className="mt-0.5 text-xs text-muted-foreground">{r.blurb}</div>
                    ) : null}
                  </td>
                  <td className="py-2 pr-4">
                    {r.ok === null ? (
                      <Pill tone="muted">{ui("Needs an organisation")}</Pill>
                    ) : r.ok ? (
                      <Pill tone="ok">{ui("Holds")}</Pill>
                    ) : (
                      <Pill tone="bad">{ui("Violated")}</Pill>
                    )}
                  </td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{checkFinding(r)}</td>
                </tr>
              ))}
            </Table>
          </div>
        ) : null}
      </div>
    </div>
  );
}
