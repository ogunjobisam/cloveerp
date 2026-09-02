import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { ErrorNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

export const Route = createFileRoute("/operations/continuity")({
  head: () => ({
    meta: [
      { title: "Continuity and incidents — Clove ERP" },
      { name: "description", content: "Continuity planning, incident records and recovery evidence." },
      { property: "og:title", content: "Continuity and incidents — Clove ERP" },
      { property: "og:description", content: "Continuity planning, incident records and recovery evidence." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Continuity />
    </Gate>
  ),
});

/** Shaped by erp.continuity_report(). `state` is one of proved, overdue or
 *  never drilled — §16.5 counts a backup nobody has restored as a hope. */
type Commitment = {
  commitment_code: string;
  title: string;
  cadence_days: number;
  last_drill: string | null;
  days_since: number | null;
  state: string;
};

/** Shaped by erp.incident_report(). `overdue` is true when a live incident has
 *  gone longer than its own severity's cadence without an update — §17.3's
 *  silence, which is invisible from the incident row alone. */
type Incident = {
  code: string;
  severity_code: string;
  title: string;
  state: string;
  declared_at: string;
  resolved_at: string | null;
  commander: string;
  communications_owner: string;
  scribe: string;
  scope: string | null;
  affects_all_tenants: boolean | null;
  is_data_integrity: boolean;
  review_url: string | null;
  updates: number;
  minutes_since_update: number | null;
  cadence_minutes: number;
  overdue: boolean;
};

/** Shaped by erp.support_access_report(). */
type Access = {
  granted_at: string;
  expires_at: string;
  staff_email: string;
  staff_role: string;
  reason: string;
  request_reference: string | null;
  write_access: boolean;
  is_extension: boolean;
  still_live: boolean;
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

/** Shaped by erp.service_notices(): only what touches this organisation. */
type Notices = {
  maintenance: {
    code: string;
    title: string;
    detail: string | null;
    starts_at: string;
    ends_at: string;
    announced_at: string;
    is_emergency: boolean;
    emergency_reason: string | null;
    state: string;
  }[];
  incidents: {
    code: string;
    title: string;
    severity_code: string;
    state: string;
    declared_at: string;
    scope: string | null;
    is_data_integrity: boolean;
    is_security: boolean;
    affects_all_tenants: boolean;
    updates: { posted_at: string; body: string; is_no_change: boolean }[];
    obligations: {
      obligation_code: string;
      title: string;
      obliged_party: string;
      basis: string;
      due_at: string;
      notified_at: string | null;
      overdue: boolean;
    }[];
  }[];
};

/**
 * §17.3 and §17.4 from the organisation's side. Everything here was scoped by
 * the database: a window for this organisation or for everyone, an incident it
 * was named in or that reached everyone once contained, and its own
 * obligations on a security incident. Nothing about anybody else arrives.
 */
function ServiceNotices() {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_service_notices", {}],
    queryFn: () => callErp<Notices>("erp_service_notices"),
  });

  if (q.error) return <ErrorNote error={q.error} />;
  const n = q.data;

  return (
    <section className="flex flex-col gap-4">
      <h2 className="font-display text-lg font-semibold">{ui("Service notices")}</h2>

      <div className="surface-card rounded-xl border border-border bg-card p-5">
        <h3 className="text-sm font-semibold">{ui("Maintenance windows")}</h3>
        {!n || n.maintenance.length === 0 ? (
          <p className="mt-2 text-sm text-muted-foreground">
            {ui(
              "Nothing is planned. Maintenance is announced here at least two days ahead; an emergency says so and says why.",
            )}
          </p>
        ) : (
          <ul className="mt-3 flex flex-col gap-3">
            {n.maintenance.map((w) => (
              <li key={w.code} className="border-b border-border/50 pb-3 last:border-0 last:pb-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium">{w.title}</span>
                  {w.is_emergency ? (
                    <Pill tone="bad">{ui("Emergency")}</Pill>
                  ) : w.state === "in_progress" ? (
                    <Pill tone="warn">{ui("In progress")}</Pill>
                  ) : w.state === "past" ? (
                    <Pill tone="muted">{ui("Past")}</Pill>
                  ) : (
                    <Pill tone="ok">{ui("Planned")}</Pill>
                  )}
                </div>
                <div className="mt-0.5 text-xs text-muted-foreground">
                  {when(w.starts_at)} — {when(w.ends_at)}
                </div>
                {w.detail ? <p className="mt-1 text-sm">{w.detail}</p> : null}
                {w.emergency_reason ? (
                  <p className="mt-1 text-sm text-muted-foreground">{w.emergency_reason}</p>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="surface-card rounded-xl border border-border bg-card p-5">
        <h3 className="text-sm font-semibold">{ui("Incidents affecting you")}</h3>
        {!n || n.incidents.length === 0 ? (
          <p className="mt-2 text-sm text-muted-foreground">
            {ui(
              "No incident has been declared that reached this organisation. You are told here the moment the platform names you, never by a broadcast meant for somebody else.",
            )}
          </p>
        ) : (
          <ul className="mt-3 flex flex-col gap-4">
            {n.incidents.map((i) => (
              <li key={i.code} className="border-b border-border/50 pb-4 last:border-0 last:pb-0">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium">{i.title}</span>
                  <span className="font-mono text-xs text-muted-foreground">{i.severity_code}</span>
                  {i.state === "resolved" ? (
                    <Pill tone="ok">{ui("Resolved")}</Pill>
                  ) : i.state === "contained" ? (
                    <Pill tone="muted">{ui("Contained")}</Pill>
                  ) : (
                    <Pill tone="bad">{ui("Live")}</Pill>
                  )}
                  {i.is_security ? <Pill tone="bad">{ui("Security incident")}</Pill> : null}
                  {i.is_data_integrity ? <Pill tone="bad">{ui("Data integrity")}</Pill> : null}
                </div>
                <div className="mt-0.5 text-xs text-muted-foreground">
                  {when(i.declared_at)}
                  {i.scope ? ` · ${i.scope}` : ""}
                  {i.affects_all_tenants ? ` · ${ui("Every organisation")}` : ""}
                </div>
                {i.updates.length > 0 ? (
                  <ol className="mt-2 flex flex-col gap-1">
                    {i.updates.map((u) => (
                      <li key={u.posted_at} className="text-sm">
                        <span className="text-xs text-muted-foreground">
                          {when(u.posted_at)} · {u.is_no_change ? ui("No change") : ui("Update")}
                        </span>
                        <div>{u.body}</div>
                      </li>
                    ))}
                  </ol>
                ) : null}
                {i.obligations.length > 0 ? (
                  <div className="mt-3">
                    <h4 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      {ui("Your obligations")}
                    </h4>
                    <ul className="mt-1 flex flex-col gap-1">
                      {i.obligations.map((o) => (
                        <li key={o.obligation_code} className="text-sm">
                          <span className="font-medium">{o.title}</span>{" "}
                          <span className="text-xs text-muted-foreground">
                            {o.obliged_party} · {ui("Due")} {when(o.due_at)}
                          </span>{" "}
                          {o.notified_at ? (
                            <Pill tone="ok">{ui("Told")}</Pill>
                          ) : o.overdue ? (
                            <Pill tone="bad">{ui("Overdue")}</Pill>
                          ) : null}
                          <div className="text-xs text-muted-foreground">{o.basis}</div>
                        </li>
                      ))}
                    </ul>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

function Continuity() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Continuity and incidents">
        What this platform has promised about staying up and getting back, and what has happened
        when it did not. Every row is read live from the registers the assertions police — a
        commitment reads as proved only when a drill actually restored and ran the invariant checks
        against the restored data, and a live incident reads as overdue the moment it passes its own
        severity&rsquo;s update cadence.
      </PageHeader>

      <ServiceNotices />

      <DataPanel<Commitment>
        title="Continuity commitments"
        description="Proved by drill, not by log. A backup that has never been restored is a hope, so a commitment with no drill says so rather than showing green."
        fn="erp_platform_continuity"
        empty="No continuity commitments are registered, which is itself unexpected."
      >
        {(rows) => (
          <Table columns={["Commitment", "Cadence", "Last drill", "State"]}>
            {rows.map((r) => (
              <tr
                key={r.commitment_code}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.title}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">{r.commitment_code}</div>
                </td>
                <td className="py-2 pr-4 text-sm">Every {r.cadence_days} days</td>
                <td className="py-2 pr-4 text-sm">
                  {when(r.last_drill)}
                  {r.days_since !== null ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {r.days_since} days ago
                    </div>
                  ) : null}
                </td>
                <td className="py-2">
                  {r.state === "proved" ? (
                    <Pill tone="ok">Proved</Pill>
                  ) : r.state === "overdue" ? (
                    <Pill tone="bad">Overdue</Pill>
                  ) : (
                    <Pill tone="bad">Never drilled</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Incident>
        title="Incidents"
        description="Declared with a commander, a communications owner and a scribe, because deciding who is writing things down at three in the morning is the wrong time to decide it. A severity 1 or 2 cannot be resolved without its blameless review."
        fn="erp_platform_incidents"
        empty="No incident has been declared."
      >
        {(rows) => (
          <Table columns={["Incident", "Severity", "State", "Communication", "Roles"]}>
            {rows.map((r) => (
              <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.title}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {r.code} · declared {when(r.declared_at)}
                  </div>
                  {r.scope ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      Scope: {r.scope}
                      {r.affects_all_tenants ? " · every organisation" : ""}
                    </div>
                  ) : null}
                  {r.is_data_integrity ? (
                    <div className="mt-1">
                      <Pill tone="bad">Data integrity</Pill>
                    </div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-sm uppercase">{r.severity_code}</td>
                <td className="py-2 pr-4">
                  {r.state === "resolved" ? (
                    <Pill tone="ok">Resolved</Pill>
                  ) : r.state === "contained" ? (
                    <Pill tone="muted">Contained</Pill>
                  ) : (
                    <Pill tone="bad">Live</Pill>
                  )}
                  {r.review_url ? (
                    <div className="mt-1 text-xs text-muted-foreground">Review written</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  <div className="text-sm">
                    {r.updates} update{r.updates === 1 ? "" : "s"}
                  </div>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    Every {r.cadence_minutes} min
                    {r.minutes_since_update !== null
                      ? ` · last ${r.minutes_since_update} min ago`
                      : ""}
                  </div>
                  {r.overdue ? (
                    <div className="mt-1">
                      <Pill tone="bad">Overdue an update</Pill>
                    </div>
                  ) : null}
                </td>
                <td className="py-2 text-xs text-muted-foreground">
                  <div>Commander: {r.commander}</div>
                  <div>Comms: {r.communications_owner}</div>
                  <div>Scribe: {r.scribe}</div>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Access>
        title="Support access"
        description="Standing access does not exist. Every grant is bounded to at most a week, carries the reason it was asked for, and an extension is a fresh act rather than a longer expiry."
        fn="erp_platform_support_access"
        empty="No support access has been granted to any organisation."
      >
        {(rows) => (
          <Table columns={["Granted", "Who", "Reason", "Access", "State"]}>
            {rows.map((r) => (
              <tr
                key={`${r.staff_email}-${r.granted_at}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4 text-sm">
                  {when(r.granted_at)}
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    Expires {when(r.expires_at)}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.staff_email}
                  <div className="mt-0.5 text-xs text-muted-foreground">{r.staff_role}</div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.reason}
                  {r.request_reference ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      {r.request_reference}
                    </div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  {r.write_access ? <Pill tone="bad">Write</Pill> : <Pill tone="muted">Read</Pill>}
                  {r.is_extension ? (
                    <div className="mt-1 text-xs text-muted-foreground">Extension</div>
                  ) : null}
                </td>
                <td className="py-2">
                  {r.still_live ? <Pill tone="bad">Live</Pill> : <Pill tone="ok">Expired</Pill>}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
