import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * The services beneath the reports. Specification v1.2 Part 19.
 *
 * §19.3: a run the budget deferred is produced as an extract through the
 * output subsystem, archived with its checksum. §19.4: subscriptions by person
 * or role on a cadence, delivered through Part 15; packs assembled with a
 * manifest. §19.5: governed views exposed as versioned contracts, read with a
 * credential that is scoped, expiring and revocable.
 */

export const Route = createFileRoute("/reporting/distribution")({
  head: () => ({ meta: [{ title: "Subscriptions, packs and extracts — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Distribution />
    </Gate>
  ),
});

type Extract = {
  run_id: string;
  report_code: string;
  report_name: string;
  version: number;
  parameters: Record<string, unknown> | null;
  run_at: string;
  run_by: string | null;
  extract_reason: string | null;
  status: string;
  row_count: number | null;
  failure_reason: string | null;
  produced_at: string | null;
  checksum: string | null;
  byte_size: number | null;
  job_enabled: boolean;
};

type Subscription = {
  id: string;
  report_code: string;
  report_name: string;
  subscriber_kind: string;
  subscriber: string | null;
  parameters: Record<string, unknown>;
  cadence: string;
  at_time: string;
  timezone: string;
  destination_kind: string;
  next_due_at: string;
  last_run_at: string | null;
  status: string;
};

type Pack = {
  code: string;
  name: string;
  description: string | null;
  status: string;
  items: {
    report_code: string;
    report_name: string;
    parameters: Record<string, unknown>;
    seq: number;
  }[];
  runs: { id: string; as_at: string; run_by: string | null; manifest: { items: ManifestItem[] } }[];
};

type ManifestItem = {
  seq: number;
  report: string;
  version: number;
  run_id: string;
  as_at: string;
  extract_status: string;
  checksum: string | null;
  row_count: string | null;
  reason: string | null;
};

type Contract = {
  views: {
    code: string;
    name: string;
    module_code: string | null;
    source: string;
    required_permission: string;
    is_exposed: boolean;
    contracts: {
      version: number;
      exposed_at: string;
      deprecated_at: string | null;
      deprecation_notice: string | null;
      retire_after: string | null;
      retired_at: string | null;
    }[];
  }[];
  credentials: {
    id: string;
    label: string;
    view_codes: string[] | null;
    expires_at: string;
    revoked_at: string | null;
    revoke_reason: string | null;
    last_used_at: string | null;
    created_at: string;
  }[];
  services_installed: boolean;
  findings: { finding: string; reference: string; detail: string }[];
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function Distribution() {
  const { ui } = useT();
  const { session } = useErpSession();
  const contract = useQuery({
    queryKey: ["erp_analytics_contract", {}],
    queryFn: () => callErp<Contract>("erp_analytics_contract"),
  });
  const install = useErpAction({
    fn: "erp_configure_reporting",
    invalidates: ["erp_analytics_contract", "erp_report_extracts", "erp_change_sets"],
  });

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Subscriptions, packs and extracts")}>
        {ui(
          "Governed views exposed to external tools as versioned contracts, deprecated on notice; credentials scoped to the organisation and to named views, expiring and revocable. Bulk export reads the same door incrementally.",
        )}
      </PageHeader>

      {contract.data && !contract.data.services_installed ? (
        <section className="rounded-xl border border-border bg-card p-4 sm:p-5">
          <p className="text-sm">
            {ui(
              "Reporting services are not installed. Installing them is a configuration change, approved and promoted like a module: the extract template a deferred run is produced through, and the two jobs that produce extracts and distribute subscriptions.",
            )}
          </p>
          {hasPermission(session, "administration.configure") ? (
            <div className="mt-3">
              <ActionButton
                onClick={() => install.mutate({})}
                disabled={install.isPending}
                variant="secondary"
              >
                {ui("Install reporting services")}
              </ActionButton>
            </div>
          ) : null}
          {install.error ? <ErrorNote error={install.error} /> : null}
        </section>
      ) : contract.data ? (
        <p className="text-sm text-muted-foreground">
          {ui(
            "Installed: deferred runs are produced as extracts and subscriptions are distributed by the scheduled jobs.",
          )}
        </p>
      ) : null}

      {contract.data && contract.data.findings.length > 0 ? (
        <ul
          role="alert"
          className="flex flex-col gap-1 rounded-xl border border-destructive/30 bg-destructive/5 p-4"
        >
          {contract.data.findings.map((f, i) => (
            <li key={`${f.finding}-${i}`} className="text-sm">
              <span className="font-medium">{f.finding}</span>{" "}
              <span className="font-mono text-xs">{f.reference}</span>{" "}
              <span className="text-muted-foreground">{f.detail}</span>
            </li>
          ))}
        </ul>
      ) : null}

      <ActionBar
        note="A subscription is your own unless you hold reporting.define; a pack is defined under it and assembled under reporting.export; the contract is administered under administration.integrate."
        actions={[
          {
            label: "Subscribe to a report",
            permission: "reporting.read",
            fn: "erp_subscribe_to_report",
            fields: [
              pickFrom(
                "erp_report_versions",
                "report_code",
                ["report_code", "report_name"],
                "p_report_code",
                "Report",
              ),
              {
                kind: "choice",
                name: "p_subscriber_kind",
                label: "Who",
                required: true,
                choices: [
                  { value: "person", label: "Me" },
                  { value: "role", label: "Everyone holding a role" },
                ],
              },
              {
                kind: "text",
                name: "p_role_code",
                label: "Role code",
                hint: "Only for a role subscription.",
              },
              {
                kind: "choice",
                name: "p_cadence",
                label: "Cadence",
                required: true,
                choices: [
                  { value: "daily", label: "Daily" },
                  { value: "weekly", label: "Weekly" },
                  { value: "monthly", label: "Monthly" },
                ],
              },
              { kind: "text", name: "p_at_time", label: "At", hint: "A time of day, e.g. 06:00." },
              {
                kind: "text",
                name: "p_timezone",
                label: "Time zone",
                hint: "An IANA name, e.g. Europe/London.",
              },
              {
                kind: "choice",
                name: "p_destination_kind",
                label: "Delivered by",
                required: true,
                choices: [
                  { value: "email", label: "Email" },
                  { value: "archive", label: "Archive only" },
                ],
              },
            ],
            invalidates: ["erp_report_subscriptions"],
          },
          {
            label: "Define a pack",
            permission: "reporting.define",
            fn: "erp_upsert_report_pack",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              { kind: "text", name: "p_description", label: "Description" },
            ],
            invalidates: ["erp_report_packs"],
          },
          {
            label: "Add a report to a pack",
            permission: "reporting.define",
            fn: "erp_add_report_pack_item",
            fields: [
              pickFrom("erp_report_packs", "code", ["code", "name"], "p_pack_code", "Pack"),
              pickFrom(
                "erp_report_versions",
                "report_code",
                ["report_code", "report_name"],
                "p_report_code",
                "Report",
              ),
              { kind: "number", name: "p_seq", label: "Order" },
            ],
            invalidates: ["erp_report_packs"],
          },
          {
            label: "Assemble a pack",
            permission: "reporting.export",
            fn: "erp_assemble_report_pack",
            fields: [pickFrom("erp_report_packs", "code", ["code", "name"], "p_pack_code", "Pack")],
            invalidates: ["erp_report_packs", "erp_report_extracts", "erp_report_runs"],
          },
          {
            label: "Expose a governed view",
            permission: "administration.integrate",
            fn: "erp_expose_governed_view",
            fields: [{ kind: "text", name: "p_view_code", label: "View code", required: true }],
            invalidates: ["erp_analytics_contract"],
          },
          {
            label: "Deprecate a contract on notice",
            permission: "administration.integrate",
            fn: "erp_revise_analytics_contract",
            fields: [
              { kind: "text", name: "p_view_code", label: "View code", required: true },
              { kind: "text", name: "p_deprecation_notice", label: "What changes", required: true },
              {
                kind: "date",
                name: "p_retire_after",
                label: "May be retired after",
                required: true,
              },
            ],
            invalidates: ["erp_analytics_contract"],
          },
          {
            label: "Retire a contract",
            permission: "administration.integrate",
            fn: "erp_retire_analytics_contract",
            fields: [
              { kind: "text", name: "p_view_code", label: "View code", required: true },
              { kind: "number", name: "p_version", label: "Version", required: true },
            ],
            invalidates: ["erp_analytics_contract"],
          },
          {
            label: "Revoke a credential",
            permission: "administration.integrate",
            fn: "erp_revoke_analytics_credential",
            fields: [
              { kind: "text", name: "p_credential_id", label: "Credential id", required: true },
              { kind: "text", name: "p_reason", label: "Why", required: true },
            ],
            invalidates: ["erp_analytics_contract"],
          },
        ]}
      />

      <Extracts />

      <DataPanel<Subscription>
        title={ui("Subscriptions")}
        description={ui(
          "By person or by role, on a cadence, delivered through the output subsystem. Each production checks that the recipient still holds the permission the report requires.",
        )}
        fn="erp_report_subscriptions"
        empty={ui("Nobody is subscribed to a report.")}
      >
        {(rows) => (
          <Table columns={["Report", "Subscriber", "Cadence", "Next due", "State", ""]}>
            {rows.map((s) => (
              <tr key={s.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {s.report_name}
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {s.report_code}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {s.subscriber}
                  <div className="mt-0.5 text-xs text-muted-foreground">{s.subscriber_kind}</div>
                </td>
                <td className="py-2 pr-4 text-xs">
                  {s.cadence} · {s.at_time} {s.timezone} · {s.destination_kind}
                </td>
                <td className="py-2 pr-4 text-xs">
                  {when(s.next_due_at)}
                  {s.last_run_at ? (
                    <div className="mt-0.5 text-muted-foreground">last {when(s.last_run_at)}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={s.status === "active" ? "ok" : "muted"}>{s.status}</Pill>
                </td>
                <td className="py-2">
                  <SubscriptionControls id={s.id} status={s.status} />
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Pack>
        title={ui("Packs")}
        description={ui(
          "A pack is a defined artefact with a manifest: which reports, which versions, which parameters, and the as-at time and checksum of each figure.",
        )}
        fn="erp_report_packs"
        empty={ui("No pack is defined.")}
      >
        {(rows) => (
          <ul className="flex flex-col gap-4">
            {rows.map((p) => (
              <li key={p.code} className="border-b border-border/50 pb-4 last:border-0 last:pb-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium">{p.name}</span>
                  <span className="font-mono text-xs text-muted-foreground">{p.code}</span>
                  <Pill tone={p.status === "active" ? "ok" : "muted"}>{p.status}</Pill>
                </div>
                {p.description ? (
                  <p className="mt-1 text-sm text-muted-foreground">{p.description}</p>
                ) : null}
                <p className="mt-1 text-xs text-muted-foreground">
                  {p.items.map((i) => `${i.seq}. ${i.report_name}`).join(" · ") || "—"}
                </p>
                {p.runs.length > 0 ? (
                  <ol className="mt-2 flex flex-col gap-2">
                    {p.runs.map((r) => (
                      <li key={r.id} className="rounded-lg bg-muted px-3 py-2 text-xs">
                        <div>
                          {when(r.as_at)}
                          {r.run_by ? ` · ${r.run_by}` : ""}
                        </div>
                        <ul className="mt-1 flex flex-col gap-0.5 font-mono">
                          {r.manifest.items.map((m) => (
                            <li key={m.run_id}>
                              {m.report} v{m.version} · {m.extract_status}
                              {m.checksum ? ` · ${m.checksum.slice(0, 12)}` : ""}
                              {m.row_count !== null ? ` · ${m.row_count} rows` : ""}
                              {m.reason ? ` · ${m.reason}` : ""}
                            </li>
                          ))}
                        </ul>
                      </li>
                    ))}
                  </ol>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </DataPanel>

      <AnalyticsContract contract={contract.data ?? null} error={contract.error} />
    </div>
  );
}

function SubscriptionControls({ id, status }: { id: string; status: string }) {
  const { ui } = useT();
  const set = useErpAction({
    fn: "erp_set_report_subscription_status",
    invalidates: ["erp_report_subscriptions"],
  });
  return (
    <div className="flex flex-wrap gap-1">
      <button
        type="button"
        className={`${TOUCH} rounded-md border border-input px-3 text-xs font-medium`}
        onClick={() =>
          set.mutate({ p_subscription_id: id, p_status: status === "active" ? "paused" : "active" })
        }
      >
        {status === "active" ? ui("Pause") : ui("Resume")}
      </button>
      <button
        type="button"
        className={`${TOUCH} rounded-md border border-input px-3 text-xs font-medium`}
        onClick={() => set.mutate({ p_subscription_id: id, p_status: "cancelled" })}
      >
        {ui("Cancel")}
      </button>
      {set.error ? <ErrorNote error={set.error} /> : null}
    </div>
  );
}

function Extracts() {
  const { ui } = useT();
  const [shown, setShown] = useState<{ run: string; content: string } | null>(null);

  async function show(runId: string) {
    const r = await callErp<{ produced: boolean; content: string | null }>(
      "erp_report_extract_content",
      {
        p_run_id: runId,
      },
    );
    setShown({ run: runId, content: r.content ?? "" });
  }

  return (
    <DataPanel<Extract>
      title={ui("Extracts")}
      description={ui(
        "Every run the interactive budget deferred, and what became of it. A produced extract is archived with its checksum, parameters and as-at time, so the figure can be reproduced.",
      )}
      fn="erp_report_extracts"
      empty={ui(
        "No run has been deferred. A run that exceeds its version's row cap or time budget lands here instead of failing.",
      )}
    >
      {(rows) => (
        <>
          <Table columns={["Run", "Why deferred", "State", "Artefact", ""]}>
            {rows.map((e) => (
              <tr key={e.run_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {e.report_name} v{e.version}
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {when(e.run_at)}
                    {e.run_by ? ` · ${e.run_by}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{e.extract_reason}</td>
                <td className="py-2 pr-4">
                  {e.status === "produced" ? (
                    <Pill tone="ok">{ui("Produced")}</Pill>
                  ) : e.status === "failed" ? (
                    <Pill tone="bad">{ui("Failed")}</Pill>
                  ) : (
                    <Pill tone="warn">{ui("Waiting")}</Pill>
                  )}
                  {e.failure_reason ? (
                    <div className="mt-1 text-xs text-muted-foreground">{e.failure_reason}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 font-mono text-xs text-muted-foreground">
                  {e.checksum
                    ? `${e.checksum.slice(0, 12)} · ${e.byte_size} B · ${e.row_count} rows`
                    : "—"}
                </td>
                <td className="py-2">
                  {e.status === "produced" ? (
                    <button
                      type="button"
                      className={`${TOUCH} rounded-md border border-input px-3 text-xs font-medium`}
                      onClick={() => void show(e.run_id)}
                    >
                      {ui("Show")}
                    </button>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
          {shown ? (
            <div className="mt-3">
              <label className="block text-xs font-medium">
                {ui("Download")}: RUN-{shown.run}
                <textarea
                  readOnly
                  rows={8}
                  className="mt-1 w-full rounded-md border border-input bg-background p-2 font-mono text-xs"
                  value={shown.content}
                />
              </label>
              <a
                className={`${TOUCH} mt-2 inline-flex items-center rounded-md border border-input px-3 text-xs font-medium`}
                download={`RUN-${shown.run}.csv`}
                href={`data:text/csv;charset=utf-8,${encodeURIComponent(shown.content)}`}
              >
                {ui("Download")}
              </a>
            </div>
          ) : null}
        </>
      )}
    </DataPanel>
  );
}

function AnalyticsContract({ contract, error }: { contract: Contract | null; error: unknown }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [token, setToken] = useState<{ token: string; expires_at: string } | null>(null);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold">{ui("Analytics contract")}</h2>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {ui(
                "Governed views exposed to external tools as versioned contracts, deprecated on notice; credentials scoped to the organisation and to named views, expiring and revocable. Bulk export reads the same door incrementally.",
              )}
            </p>
          </div>
          {hasPermission(session, "administration.integrate") ? (
            <ActionDialog
              trigger={<ActionButton variant="secondary">{ui("Issue a credential")}</ActionButton>}
              title="Issue a credential"
              description="Named for the tool that will hold it, scoped to exposed views, and shown once."
              fn="erp_issue_analytics_credential"
              fields={[
                { kind: "text", name: "p_label", label: "Label", required: true },
                {
                  kind: "text",
                  name: "p_view_codes",
                  label: "View codes",
                  hint: "Comma separated. Leave empty for every exposed view.",
                },
                {
                  kind: "date",
                  name: "p_expires_at",
                  label: "Expires",
                  hint: "Defaults to a year.",
                },
              ]}
              mapArgs={(v) => ({
                p_label: v["p_label"],
                p_view_codes: v["p_view_codes"]
                  ? v["p_view_codes"]
                      .split(",")
                      .map((s) => s.trim())
                      .filter(Boolean)
                  : null,
                p_expires_at: v["p_expires_at"] ? new Date(v["p_expires_at"]).toISOString() : null,
              })}
              invalidates={["erp_analytics_contract"]}
              submitLabel="Issue"
              onDone={(result) => {
                const r = result as { token: string; expires_at: string };
                setToken(r);
                void queryClient.invalidateQueries({ queryKey: ["erp_analytics_contract"] });
              }}
            />
          ) : null}
        </div>
      </header>
      <div className="flex flex-col gap-5 px-4 py-4 sm:px-5">
        {error ? <ErrorNote error={error} /> : null}
        {token ? (
          <div role="status" className="rounded-lg border border-primary/40 bg-primary/5 p-3">
            <p className="text-sm font-medium">{ui("Token")}</p>
            <p className="mt-1 text-xs text-muted-foreground">
              {ui(
                "This token is shown once. Give it to the tool that will hold it; it cannot be recovered, only revoked.",
              )}
            </p>
            <code className="mt-2 block break-all rounded bg-muted px-2 py-1 font-mono text-xs">
              {token.token}
            </code>
          </div>
        ) : null}

        {contract && contract.views.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {ui("No governed view is registered yet; installing a module registers its views.")}
          </p>
        ) : contract ? (
          <Table columns={["View", "Contract", "Versions"]}>
            {contract.views.map((v) => (
              <tr key={v.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {v.name}
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {v.code} · {v.source} · {v.required_permission}
                  </div>
                </td>
                <td className="py-2 pr-4">
                  {v.is_exposed ? (
                    <Pill tone="ok">{ui("Exposed")}</Pill>
                  ) : (
                    <Pill tone="muted">{ui("Not exposed")}</Pill>
                  )}
                </td>
                <td className="py-2 text-xs">
                  {v.contracts.length === 0
                    ? "—"
                    : v.contracts.map((c) => (
                        <div key={c.version}>
                          v{c.version} · {when(c.exposed_at)}
                          {c.retired_at
                            ? ` · ${ui("Retired")}`
                            : c.deprecated_at
                              ? ` · ${ui("Deprecated")}: ${c.deprecation_notice} (${c.retire_after})`
                              : ""}
                        </div>
                      ))}
                </td>
              </tr>
            ))}
          </Table>
        ) : null}

        {contract && contract.credentials.length === 0 ? (
          <p className="text-sm text-muted-foreground">{ui("No credential has been issued.")}</p>
        ) : contract ? (
          <Table columns={["Credential", "Views", "Expires", "Last used", "State"]}>
            {contract.credentials.map((c) => (
              <tr key={c.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {c.label}
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">{c.id}</div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {c.view_codes?.join(", ") ?? "every exposed view"}
                </td>
                <td className="py-2 pr-4 text-xs">{when(c.expires_at)}</td>
                <td className="py-2 pr-4 text-xs">{when(c.last_used_at)}</td>
                <td className="py-2">
                  {c.revoked_at ? (
                    <Pill tone="bad">{ui("Revoked")}</Pill>
                  ) : new Date(c.expires_at) < new Date() ? (
                    <Pill tone="muted">{ui("Expired")}</Pill>
                  ) : (
                    <Pill tone="ok">{ui("Live")}</Pill>
                  )}
                  {c.revoke_reason ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{c.revoke_reason}</div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        ) : null}
      </div>
    </section>
  );
}
