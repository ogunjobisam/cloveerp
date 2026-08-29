import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";

export const Route = createFileRoute("/operations/assurance")({
  head: () => ({ meta: [{ title: "Assurance — ERPWare" }] }),
  component: () => (
    <Gate>
      <Assurance />
    </Gate>
  ),
});

type Check = { check: string; ok: boolean; detail: string | null };

function Assurance() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Assurance">
        The structural checks that run on every push. Each one fails the build rather than warning,
        so anything not green here is something the platform would refuse to ship with — shown
        against this database as it stands right now.
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
              <tr key={r.check} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.check}</td>
                <td className="py-2 pr-4">
                  {r.ok ? <Pill tone="ok">Holds</Pill> : <Pill tone="bad">Violated</Pill>}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{r.detail ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
