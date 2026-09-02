import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";

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

/** Shaped by erp.run_diagnostic(). `ok` is null for a check that needs an
 *  organisation and was run without one — neither passing nor failing. */
type Check = {
  check: string;
  code?: string;
  title?: string;
  blurb?: string;
  ok: boolean | null;
  summary?: string | null;
  detail: string | null;
};

function Assurance() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Assurance">
        Every structural check this product runs against itself, read from the same register CI runs
        and erp.assert_diagnostics_registered() polices — so a check added to the product appears
        here without a deployment. Each one fails the build rather than warning, so anything not
        green is something the platform would refuse to ship with.
      </PageHeader>

      <DataPanel<Check>
        title="Structural assertions"
        description="Run live against this database, not read from a cached result."
        fn="erp_platform_assurance"
        empty="No checks were returned, which is itself unexpected."
      >
        {(rows) => (
          <Table columns={["Check", "Result", "Detail"]}>
            {rows.map((r) => (
              <tr key={r.check} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.title ?? r.check}</div>
                  {r.blurb ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.blurb}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  {r.ok === null ? (
                    <Pill tone="muted">Needs an organisation</Pill>
                  ) : r.ok ? (
                    <Pill tone="ok">Holds</Pill>
                  ) : (
                    <Pill tone="bad">Violated</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.summary ?? r.detail ?? "—"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
