import { createFileRoute } from "@tanstack/react-router";

import { ActionBar } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";

import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { SeedDemoAction } from "../../components/erp/seed";
import { publicApiOperations } from "../../lib/public-api-catalogue";

export const Route = createFileRoute("/operations/integrations")({
  head: () => ({
    meta: [
      { title: "Integrations — Clove ERP" },
      {
        name: "description",
        content: "Outbound and inbound integrations, endpoints and delivery history.",
      },
      { property: "og:title", content: "Integrations — Clove ERP" },
      {
        property: "og:description",
        content: "Outbound and inbound integrations, endpoints and delivery history.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
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
        Manage connected systems, review delivery health and use the versioned public API.
      </PageHeader>

      <section className="grid gap-4 lg:grid-cols-[minmax(0,1.4fr)_minmax(18rem,0.6fr)]">
        <div className="min-w-0 border border-border bg-card p-5">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-base font-semibold">REST API · v1</h2>
              <p className="mt-1 text-sm text-muted-foreground">
                A controlled API over the same permissions and business rules as the desk.
              </p>
            </div>
            <a
              className="text-sm font-medium text-primary underline-offset-4 hover:underline"
              href="/api/public/v1/openapi.json"
              target="_blank"
              rel="noreferrer"
            >
              Open API reference
            </a>
          </div>
          <div className="mt-4 overflow-x-auto">
            <Table columns={["Method", "Path", "Purpose", "Permission"]}>
              {publicApiOperations.map((operation) => (
                <tr key={operation.operationId} className="border-b border-border/50 last:border-0">
                  <td className="py-2 pr-4">
                    <Pill tone={operation.write ? "warn" : "ok"}>{operation.method}</Pill>
                  </td>
                  <td className="whitespace-nowrap py-2 pr-4 font-mono text-xs">
                    /v1{operation.path}
                  </td>
                  <td className="py-2 pr-4 text-sm">{operation.summary}</td>
                  <td className="whitespace-nowrap py-2 font-mono text-xs text-muted-foreground">
                    {operation.permission}
                  </td>
                </tr>
              ))}
            </Table>
          </div>
        </div>
        <div className="border border-border bg-card p-5">
          <h2 className="text-base font-semibold">API keys and webhooks</h2>
          <p className="mt-2 text-sm leading-6 text-muted-foreground">
            Keys belong to service accounts. Their scopes can only narrow existing role permissions.
            Webhooks are signed and keep a complete retry history.
          </p>
          <p className="mt-4 text-xs text-muted-foreground">
            Key and subscription controls appear here after the corresponding database release is
            deployed.
          </p>
        </div>
      </section>

      <ActionBar
        title="Replaying a message"
        note="Replaying a message is the one thing a person does to the gateway by hand."
        actions={[
          {
            label: "Replay a message",
            permission: "administration.integrate",
            fn: "erp_replay_message",
            fields: [
              {
                kind: "number",
                name: "p_message_id",
                label: "Message id",
                required: true,
                hint: "The number shown against the message in the backlog below.",
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                required: true,
                placeholder: "Their system was down; safe to send again",
                hint: "Recorded permanently against the replay.",
              },
            ],
            invalidates: ["erp_integration_backlog", "erp_integration_health"],
          },
          {
            label: "Reconcile an ambiguous command",
            description:
              "A command that was sent and never answered is ambiguous until a person says what the other side did. The evidence is kept.",
            permission: "administration.integrate",
            fn: "erp_reconcile_ambiguous_command",
            fields: [
              {
                kind: "text",
                name: "p_command_id",
                label: "Command id",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "Copy the id from the message shown in the backlog below.",
              },
              {
                kind: "choice",
                name: "p_outcome",
                label: "What happened",
                required: true,
                choices: [
                  { value: "succeeded", label: "It succeeded" },
                  { value: "failed", label: "It failed" },
                  { value: "requeue", label: "Send it again" },
                ],
              },
              {
                kind: "text",
                name: "p_evidence",
                label: "Evidence",
                required: true,
                hint: "What you saw on the other side.",
              },
            ],
            invalidates: ["erp_integration_backlog", "erp_integration_health"],
          },
          {
            label: "Cancel a queued command",
            permission: "administration.integrate",
            fn: "erp_cancel_command",
            fields: [
              {
                kind: "text",
                name: "p_command_id",
                label: "Command id",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "Copy the id from the message shown in the backlog below.",
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                required: true,
                placeholder: "Confirmed by phone that nothing was despatched",
                hint: "The evidence for what the other side actually did.",
              },
            ],
            invalidates: ["erp_integration_backlog", "erp_integration_health"],
          },
          {
            label: "Submit a command",
            description:
              "Queues one operation on a connected system for the worker to deliver. A dry run is settled as simulated and sends nothing.",
            permission: "administration.integrate",
            fn: "erp_submit_command",
            fields: [
              {
                kind: "text",
                name: "p_system_code",
                label: "System",
                required: true,
                placeholder: "WMS",
                hint: "The short code of the connected system, as it appears in the backlog.",
              },
              {
                kind: "text",
                name: "p_operation_code",
                label: "Operation",
                required: true,
                placeholder: "despatch.confirm",
                hint: "The operation that system accepts, as agreed with whoever runs it.",
              },
              {
                kind: "text",
                name: "p_payload",
                label: "Payload",
                required: true,
                hint: "JSON, validated against the operation's schema.",
              },
              {
                kind: "choice",
                name: "p_dry_run",
                label: "Dry run",
                required: true,
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
              },
              {
                kind: "text",
                name: "p_idempotency_key",
                label: "Idempotency key",
                hint: "Left empty, one is generated.",
              },
            ],
            mapArgs: (v) => ({
              p_system_code: v["p_system_code"],
              p_operation_code: v["p_operation_code"],
              p_payload: JSON.parse(v["p_payload"] ?? "{}"),
              p_dry_run: v["p_dry_run"] === "true",
              p_idempotency_key: v["p_idempotency_key"] || null,
            }),
            invalidates: ["erp_integration_backlog", "erp_integration_health"],
          },
        ]}
      />

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
        empty="No external systems are configured for this organisation yet."
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
