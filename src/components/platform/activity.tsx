import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { ClipboardList, KeyRound } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import type { PlatformAuditRow } from "../../lib/platform";
import { Card, Fail, INPUT } from "./kit";

/**
 * Every platform action, including each entry into a customer company.
 *
 * This panel used to borrow ActionBar from the tenant shell to offer the
 * support-action form. ActionBar renders ActionDialog, which reads
 * useErpSession() — a context that only exists inside the authenticated shell —
 * so the whole Activity view threw the moment it mounted. The console is
 * deliberately outside that shell, so the form is written here, natively, and
 * takes the access as a choice rather than as an id typed in by hand.
 */

type SupportAccess = {
  id: string;
  tenant_code: string | null;
  tenant_name: string | null;
  reason: string | null;
  request_reference: string | null;
  is_write_access: boolean;
  granted_at: string;
  expires_at: string;
  is_live: boolean;
  actions_recorded: number;
};

/** Platform actions read as codes in the log; people do not. */
const ACTION_LABELS: Record<string, string> = {
  "platform.company_onboarded": "Organisation onboarded",
  "platform.tenant_entered": "Entered an organisation",
  "platform.tenant_left": "Left an organisation",
  "platform.admin_invited": "Administrator invited",
  "platform.tenant_status_changed": "Status changed",
  "platform.tenant_purged": "Organisation purged",
  "platform.ownership_offered": "Ownership offered",
  "platform.ownership_accepted": "Ownership accepted",
  "platform.ownership_declined": "Ownership declined",
  "platform.ownership_cancelled": "Ownership offer withdrawn",
  "platform.ownership_claimed": "Ownership claimed",
  "platform.staff_added": "Staff added",
  "platform.staff_role_changed": "Staff role changed",
  "platform.staff_revoked": "Staff removed",
  "platform.release_recorded": "Release recorded",
  "platform.enquiry_erased": "Enquiry erased",
  "platform.restore_drill_recorded_by_hand": "Restore drill recorded",
};

export function actionLabel(code: string): string {
  const known = ACTION_LABELS[code];
  if (known) return known;
  const bare = code.replace(/^platform\./, "").replace(/_/g, " ");
  return bare.charAt(0).toUpperCase() + bare.slice(1);
}

function when(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * What was done inside a customer's organisation under a support access, in
 * the customer's own record.
 */
export function SupportActionLog() {
  const queryClient = useQueryClient();
  const [accessId, setAccessId] = useState("");
  const [what, setWhat] = useState("");
  const [why, setWhy] = useState("");
  const [isWrite, setIsWrite] = useState(false);
  const [done, setDone] = useState(false);

  const accesses = useQuery({
    queryKey: ["erp_platform_my_support_accesses"],
    queryFn: () => callErp<SupportAccess[]>("erp_platform_my_support_accesses"),
  });

  const live = useMemo(() => (accesses.data ?? []).filter((a) => a.is_live), [accesses.data]);
  const chosen = live.find((a) => a.id === accessId) ?? null;

  const record = useMutation({
    mutationFn: () =>
      callErp("erp_platform_record_support_action", {
        p_access_id: accessId,
        p_action: what,
        p_reason: why,
        p_object_type: null,
        p_object_id: null,
        p_is_write: isWrite,
      }),
    onSuccess: () => {
      setWhat("");
      setWhy("");
      setDone(true);
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_my_support_accesses"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_audit"] });
    },
  });

  return (
    <Card
      title="Your support access"
      icon={<KeyRound className="size-4 text-primary" />}
      description="Every action taken inside a customer's organisation is recorded against the access that allowed it, with the reason, so their continuity screen shows what was done and why."
    >
      {accesses.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : accesses.error ? (
        <Fail error={accesses.error} />
      ) : (accesses.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          You hold no support access. One is created when you enter an organisation from
          Organisations, with the reason you give at the time.
        </p>
      ) : (
        <div className="flex flex-col gap-4">
          <Table columns={["Organisation", "Granted", "Expires", "Access", "Recorded"]}>
            {(accesses.data ?? []).map((a) => (
              <tr key={a.id} className="border-b border-border/60 last:border-0">
                <td className="py-3 pr-4">
                  <div className="font-medium">{a.tenant_name ?? a.tenant_code ?? "—"}</div>
                  {a.reason ? (
                    <div className="text-xs text-muted-foreground">{a.reason}</div>
                  ) : null}
                </td>
                <td className="py-3 pr-4 text-xs text-muted-foreground">{when(a.granted_at)}</td>
                <td className="py-3 pr-4 text-xs">
                  <Pill tone={a.is_live ? "ok" : "muted"}>
                    {a.is_live ? when(a.expires_at) : "Ended"}
                  </Pill>
                </td>
                <td className="py-3 pr-4 text-xs">
                  <Pill tone={a.is_write_access ? "warn" : "muted"}>
                    {a.is_write_access ? "May change things" : "Read only"}
                  </Pill>
                </td>
                <td className="py-3 pr-0 text-xs text-muted-foreground">
                  {a.actions_recorded === 0 ? "Nothing yet" : `${a.actions_recorded} action(s)`}
                </td>
              </tr>
            ))}
          </Table>

          {live.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              None of your accesses is still open, so there is nothing to record against. Enter the
              organisation again to open a fresh one.
            </p>
          ) : (
            <form
              className="grid gap-3 border-t border-border pt-4 sm:grid-cols-2"
              onSubmit={(e) => {
                e.preventDefault();
                setDone(false);
                record.mutate();
              }}
            >
              <label className="block text-sm font-medium sm:col-span-2">
                Access
                <select
                  required
                  value={accessId}
                  onChange={(e) => setAccessId(e.target.value)}
                  className={INPUT}
                >
                  <option value="">Choose the access you are working under…</option>
                  {live.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.tenant_name ?? a.tenant_code} · until {when(a.expires_at)} ·{" "}
                      {a.is_write_access ? "may change things" : "read only"}
                    </option>
                  ))}
                </select>
              </label>
              <label className="block text-sm font-medium">
                What you did
                <input
                  required
                  value={what}
                  onChange={(e) => setWhat(e.target.value)}
                  placeholder="Viewed the failed invoice posting"
                  className={INPUT}
                />
              </label>
              <label className="block text-sm font-medium">
                Why
                <input
                  required
                  value={why}
                  onChange={(e) => setWhy(e.target.value)}
                  placeholder="Investigating ticket 4471"
                  className={INPUT}
                />
              </label>
              <label className="flex items-center gap-2 text-sm sm:col-span-2">
                <input
                  type="checkbox"
                  checked={isWrite}
                  disabled={chosen ? !chosen.is_write_access : false}
                  onChange={(e) => setIsWrite(e.target.checked)}
                  className="size-4"
                />
                It changed something
                {chosen && !chosen.is_write_access ? (
                  <span className="text-xs text-muted-foreground">
                    This access is read only, so a change cannot be recorded against it.
                  </span>
                ) : null}
              </label>
              {record.error ? (
                <div className="sm:col-span-2">
                  <Fail error={record.error} />
                </div>
              ) : null}
              {done && !record.error ? (
                <p className="text-sm text-emerald-700 sm:col-span-2 dark:text-emerald-400">
                  Recorded. It now shows on that organisation's continuity screen.
                </p>
              ) : null}
              <div className="sm:col-span-2">
                <button
                  type="submit"
                  disabled={record.isPending || !accessId}
                  className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
                >
                  {record.isPending ? "Recording…" : "Record this action"}
                </button>
              </div>
            </form>
          )}
        </div>
      )}
    </Card>
  );
}

export function Activity() {
  const [action, setAction] = useState("");
  const [q, setQ] = useState("");

  const rows = useQuery({
    queryKey: ["erp_platform_audit", action],
    queryFn: () =>
      callErp<PlatformAuditRow[]>("erp_platform_audit", {
        p_action: action || null,
        p_tenant_id: null,
        p_limit: 200,
      }),
  });

  // The filter list is built from what has actually happened, so it never
  // offers a filter that returns nothing and never omits a new action code.
  const [seen, setSeen] = useState<string[]>([]);
  const options = useMemo(() => {
    const codes = new Set<string>(seen);
    for (const r of rows.data ?? []) codes.add(r.action);
    return [...codes].sort((a, b) => actionLabel(a).localeCompare(actionLabel(b)));
  }, [rows.data, seen]);
  if (!action && rows.data && seen.length === 0 && rows.data.length > 0) {
    setSeen([...new Set(rows.data.map((r) => r.action))]);
  }

  const needle = q.trim().toLowerCase();
  const shown = (rows.data ?? []).filter((r) =>
    needle
      ? [r.actor_email, r.tenant_code, r.target, r.reason, actionLabel(r.action)]
          .filter(Boolean)
          .join(" ")
          .toLowerCase()
          .includes(needle)
      : true,
  );

  return (
    <div className="flex flex-col gap-5">
      <Card
        title="Platform activity"
        icon={<ClipboardList className="size-4 text-primary" />}
        description="Every platform action, including each entry into a customer company and the reason given. Newest first, last 200."
        action={
          <div className="flex flex-wrap gap-2">
            <input
              aria-label="Search activity"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="Search person, organisation or reason"
              className="w-56 rounded-md border border-input bg-background px-2 py-2 text-xs"
            />
            <select
              aria-label="Filter by action"
              value={action}
              onChange={(e) => setAction(e.target.value)}
              className="rounded-md border border-input bg-background px-2 py-2 text-xs"
            >
              <option value="">All actions</option>
              {options.map((c) => (
                <option key={c} value={c}>
                  {actionLabel(c)}
                </option>
              ))}
            </select>
          </div>
        }
      >
        {rows.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : rows.error ? (
          <Fail error={rows.error} />
        ) : shown.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {needle || action
              ? "Nothing matches that. Clear the filter to see everything."
              : "Nothing has been done on this deployment yet."}
          </p>
        ) : (
          <Table columns={["When", "Who", "Action", "Organisation", "Detail"]}>
            {shown.map((r) => (
              <tr key={r.id} className="border-b border-border/60 align-top last:border-0">
                <td className="py-3 pr-4 text-xs whitespace-nowrap text-muted-foreground">
                  {when(r.occurred_at)}
                </td>
                <td className="py-3 pr-4 text-xs">
                  <div className="font-medium">{r.actor_email}</div>
                  <div className="text-muted-foreground">{r.actor_role}</div>
                </td>
                <td className="py-3 pr-4 text-sm">{actionLabel(r.action)}</td>
                <td className="py-3 pr-4 font-mono text-xs">{r.tenant_code ?? "—"}</td>
                <td className="max-w-[22rem] py-3 pr-0 text-xs text-muted-foreground">
                  {[r.reason, r.target].filter(Boolean).join(" · ") || "—"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <SupportActionLog />
    </div>
  );
}
