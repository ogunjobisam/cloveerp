import { useQuery } from "@tanstack/react-query";
import { useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { permissionName } from "../../lib/permission-name";
import {
  awaitsDecision,
  exceptionReasonProblem,
  isProhibitedPairing,
  readDutiesReport,
  toReview,
  type DutiesReport,
  type DutySeverity,
} from "../../lib/separation-of-duties";
import { ActionButton, ErrorNote } from "./action";
import { Prose } from "./page";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Separation of duties on People and permissions.
 *
 * The database applies the organisation's rules whenever somebody is given a
 * role (erp.settle_duties, 20260914065000): once live, a prohibited pairing is
 * refused unless somebody who may promote configuration records why it is
 * accepted, and anything else is allowed and recorded. What this file shows
 * is convenience. Hiding the reason field from somebody without
 * administration.promote only saves them a refusal: the database asks for the
 * permission itself.
 */

export const SOD_CONFLICTS_KEY = ["erp_sod_conflicts"] as const;

function SeverityPill({ severity }: { severity: DutySeverity }) {
  const { ui } = useT();
  if (severity === "prohibited") return <Pill tone="bad">{ui("Prohibited")}</Pill>;
  if (severity === "material") return <Pill tone="warn">{ui("Material")}</Pill>;
  return <Pill tone="muted">{ui("Advisory")}</Pill>;
}

/** Permissions by the names a person reads, renamed wherever the organisation renamed them. */
function PermissionNames({ codes }: { codes: readonly string[] }) {
  const { resources } = useT();
  return <>{codes.map((code) => permissionName(code, resources)).join(", ")}</>;
}

function Pairing({ a, b }: { a: readonly string[]; b: readonly string[] }) {
  const { ui } = useT();
  return (
    <>
      <PermissionNames codes={a} />{" "}
      <span className="text-muted-foreground">{ui("together with")}</span>{" "}
      <PermissionNames codes={b} />
    </>
  );
}

/**
 * A grant the database refused, in its own words; and, when the refusal is a
 * prohibited pairing and the person may promote configuration, the reason that
 * records an exception and saves again.
 */
export function GrantRefusal({
  error,
  busy,
  onException,
}: {
  error: unknown;
  busy: boolean;
  onException: (reason: string) => void;
}) {
  const { session } = useErpSession();
  const { ui } = useT();
  const [reason, setReason] = useState("");
  const [tried, setTried] = useState(false);

  if (!error) return null;

  const offered = isProhibitedPairing(error);
  const mayRecord = hasPermission(session, "administration.promote");
  const problem = exceptionReasonProblem(reason);

  return (
    <div className="flex flex-col gap-3">
      <ErrorNote error={error} />
      {offered && mayRecord ? (
        <div className="flex flex-col gap-2">
          <label className="flex flex-col gap-1 text-sm">
            <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {ui("Reason for the exception")}
            </span>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={3}
              className="w-full rounded-md border border-input bg-background px-2 py-2 text-sm"
            />
            <span className="text-xs text-muted-foreground">
              {ui(
                "Why the organisation accepts one person holding both, and what checks the work instead. At least twenty characters; it is kept with the exception for whoever reviews access.",
              )}
            </span>
          </label>
          {tried && problem !== null ? (
            <p role="alert" className="text-xs text-destructive">
              {ui("The reason needs at least twenty characters.")}
            </p>
          ) : null}
          <div>
            <ActionButton
              busy={busy}
              onClick={() => {
                setTried(true);
                if (problem === null) onException(reason.trim());
              }}
            >
              {ui("Record the exception and save")}
            </ActionButton>
          </div>
        </div>
      ) : offered ? (
        <p className="text-xs text-muted-foreground">
          {ui("Only somebody who may promote configuration can record an exception.")}
        </p>
      ) : null}
    </div>
  );
}

/** After a save: the pairings the person now holds that were recorded for review. */
export function RecordedForReview({ conflicts }: { conflicts: unknown }) {
  const { ui } = useT();
  const open = toReview(conflicts);
  if (open.length === 0) return null;

  return (
    <div className="rounded-md border border-amber-500/30 bg-amber-500/5 p-3 text-xs">
      <p className="font-medium">
        {ui("Saved. What this person now holds is listed under Separation of duties to review:")}
      </p>
      <ul className="mt-1 list-disc pl-5">
        {open.map((c) => (
          <li key={c.rule_code}>
            {c.rule_name}: <Pairing a={c.permissions_a} b={c.permissions_b} />
          </li>
        ))}
      </ul>
    </div>
  );
}

function DutiesBody({ report }: { report: DutiesReport }) {
  const { ui } = useT();

  return (
    <>
      {report.rules === 0 ? (
        <p className="text-sm text-muted-foreground">
          {ui("The organisation has no separation rules yet. Applying the base pack brings them.")}
        </p>
      ) : report.conflicts.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {ui("Nobody holds both sides of a separation rule.")}
        </p>
      ) : (
        <Table columns={[ui("Person"), ui("Rule"), ui("Severity"), ui("Holds"), ui("Decision")]}>
          {report.conflicts.map((c) => (
            <tr
              key={`${c.app_user_id}-${c.rule_code}`}
              className="border-b border-border/50 align-top last:border-0"
            >
              <td className="py-2 pr-4">{c.person ?? c.email ?? c.app_user_id}</td>
              <td className="py-2 pr-4">{c.rule_name}</td>
              <td className="py-2 pr-4">
                <SeverityPill severity={c.severity} />
              </td>
              <td className="py-2 pr-4 text-xs">
                <Pairing a={c.permissions_a} b={c.permissions_b} />
              </td>
              <td className="py-2 text-xs">
                {awaitsDecision(c) ? (
                  <Pill tone="warn">{ui("To review")}</Pill>
                ) : (
                  <>
                    <Pill tone="muted">{ui("Exception recorded")}</Pill>
                    {c.exception_reason ? (
                      <span className="mt-1 block text-muted-foreground">{c.exception_reason}</span>
                    ) : null}
                    {c.exception_by ? (
                      <span className="block text-muted-foreground">
                        {c.exception_by}
                        {c.exception_at ? `, ${c.exception_at.slice(0, 10)}` : ""}
                      </span>
                    ) : null}
                  </>
                )}
              </td>
            </tr>
          ))}
        </Table>
      )}
      {report.administrators.length > 0 ? (
        <p className="text-xs text-muted-foreground">
          {ui(
            "Administrators hold every permission by design, so the rules do not flag them. Keep the role to the few people who set the organisation up:",
          )}{" "}
          <span className="text-foreground">
            {report.administrators.map((a) => a.person ?? a.app_user_id).join(", ")}
          </span>
        </p>
      ) : null}
    </>
  );
}

/** Who holds both sides of a rule, under administration.audit_read. */
export function DutiesPanel() {
  const { session } = useErpSession();
  const { ui } = useT();
  const allowed = hasPermission(session, "administration.audit_read");

  const { data, isPending, error } = useQuery({
    queryKey: SOD_CONFLICTS_KEY,
    queryFn: async () => readDutiesReport(await callErp<unknown>("erp_sod_conflicts")),
    enabled: allowed,
  });

  if (!allowed) return null;

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{ui("Separation of duties")}</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          {ui(
            "People who hold both sides of one of the organisation's separation rules. A prohibited pairing is refused once the organisation is live unless somebody records why it is accepted; anything else is allowed and listed here to review.",
          )}
        </Prose>
      </header>
      <div className="flex flex-col gap-3 px-4 py-4 sm:px-5">
        {isPending ? (
          <p className="text-sm text-muted-foreground">{ui("Loading…")}</p>
        ) : error ? (
          <div className="flex flex-col gap-2">
            <p className="text-sm font-medium text-destructive">
              {ui("Could not load the separation of duties.")}
            </p>
            <ErrorNote error={error} />
          </div>
        ) : data ? (
          <DutiesBody report={data} />
        ) : null}
      </div>
    </section>
  );
}
