import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { SeedDemoAction } from "../../components/erp/seed";

export const Route = createFileRoute("/operations/integrations")({
  head: () => ({ meta: [{ title: "Integrations — ERPWare" }] }),
  component: () => (
    <Gate>
      <Integrations />
    </Gate>
  ),
});

type Health = {
  system_code: string;
  system_status: string;
  is_killed: boolean;
  queued: number;
  in_flight: number;
  leases_expired: number;
  failed_waiting: number;
  dead: number;
  awaiting_approval: number;
  inbound_backlog: number;
  inbound_dead: number;
};

type Backlog = {
  kind: string;
  reference: string;
  system_code: string;
  operation: string;
  status: string;
  attempts: number;
  last_error: string | null;
  suggested_action: string;
};

function Integrations() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Integrations">
        Every outbound write goes through the gateway. Nothing here can send anything — it reports
        what the gateway is doing and what needs a person.
      </PageHeader>

      <DataPanel<Backlog>
        title="Needs a decision"
        description="Oldest first, each with the action that would resolve it."
        fn="erp_integration_backlog"
        empty="Nothing is waiting on a person."
      >
        {(rows) => (
          <Table columns={["", "System", "Operation", "Status", "Tries", "What to do"]}>
            {rows.map((r) => (
              <tr
                key={`${r.kind}-${r.reference}`}
                className="border-b border-border/50 last:border-0"
              >
                <td className="py-2 pr-4 text-xs text-muted-foreground">{r.kind}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.system_code}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.operation}</td>
                <td className="py-2 pr-4">
                  <Pill tone={r.status === "dead" ? "bad" : "warn"}>{r.status}</Pill>
                </td>
                <td className="py-2 pr-4">{r.attempts}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.suggested_action}
                  {r.last_error ? (
                    <span className="mt-0.5 block font-mono text-[11px] opacity-70">
                      {r.last_error}
                    </span>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Health>
        title="Connected systems"
        description="Queue depth and the state of each configured counterpart."
        fn="erp_integration_health"
        empty="No external systems are configured for this tenant yet."
        emptyAction={<SeedDemoAction />}
      >
        {(rows) => (
          <Table
            columns={[
              "System",
              "State",
              "Queued",
              "In flight",
              "Awaiting approval",
              "Dead",
              "Inbound",
            ]}
          >
            {rows.map((r) => (
              <tr key={r.system_code} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.system_code}</td>
                <td className="py-2 pr-4">
                  {r.is_killed ? (
                    <Pill tone="bad">Kill switch</Pill>
                  ) : r.system_status === "active" ? (
                    <Pill tone="ok">Active</Pill>
                  ) : (
                    <Pill tone="muted">{r.system_status}</Pill>
                  )}
                </td>
                <td className="py-2 pr-4">{r.queued}</td>
                <td className="py-2 pr-4">
                  {r.in_flight}
                  {r.leases_expired > 0 ? (
                    <span className="ml-1.5">
                      <Pill tone="warn">{r.leases_expired} stale</Pill>
                    </span>
                  ) : null}
                </td>
                <td className="py-2 pr-4">{r.awaiting_approval}</td>
                <td className="py-2 pr-4">{r.dead > 0 ? <Pill tone="bad">{r.dead}</Pill> : "0"}</td>
                <td className="py-2 pr-4 text-muted-foreground">
                  {r.inbound_backlog} queued
                  {r.inbound_dead > 0 ? `, ${r.inbound_dead} dead` : ""}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
