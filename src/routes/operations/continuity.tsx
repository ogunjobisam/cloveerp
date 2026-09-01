import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";

export const Route = createFileRoute("/operations/continuity")({
  head: () => ({ meta: [{ title: "Continuity and incidents — ERPWare" }] }),
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
