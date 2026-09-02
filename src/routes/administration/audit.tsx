import { friendlyError } from "@/lib/errors";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * The audit log, readable.
 *
 * `erp.audit_entry` has recorded every governed action since the first tenant
 * existed; what was missing was a way to look at it. This screen is a filter
 * bar over one RPC, `erp_audit_log`, which is itself gated on
 * `administration.audit_read` — the database decides who may read the trail,
 * and it records the fact that they did.
 */
export const Route = createFileRoute("/administration/audit")({
  head: () => ({
    meta: [
      { title: "Audit log — Clove ERP" },
      {
        name: "description",
        content:
          "Track master-data change submissions, approvals and applied changes by tenant and user.",
      },
      { property: "og:title", content: "Audit log — Clove ERP" },
      { property: "og:description", content: "Track master-data change submissions, approvals and applied changes by tenant and user." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <AuditLog />
    </Gate>
  ),
});

type Entry = {
  id: number;
  occurred_at: string;
  actor: string | null;
  actor_kind: string | null;
  action: string;
  object_type: string | null;
  object_key: string | null;
  changed_fields: string[] | null;
  reason: string | null;
  source: string | null;
};

/** The values of erp.audit_action, mirrored so the filter offers real choices. */
const ACTIONS = ["insert", "update", "delete", "read", "execute", "authenticate", "export"];

type Filters = {
  action: string;
  objectType: string;
  actor: string;
  from: string;
  to: string;
};

const EMPTY_FILTERS: Filters = { action: "", objectType: "", actor: "", from: "", to: "" };

function tone(action: string): "ok" | "warn" | "bad" | "muted" {
  if (action === "delete") return "bad";
  if (action === "update" || action === "export") return "warn";
  if (action === "insert" || action === "authenticate") return "ok";
  return "muted";
}

function AuditLog() {
  const { session } = useErpSession();
  const { t } = useT();
  const allowed = hasPermission(session, "administration.audit_read");

  // Drafts are what the inputs hold; applied is what the query asks for.
  // Splitting them keeps every keystroke from firing a filtered query.
  const [draft, setDraft] = useState<Filters>(EMPTY_FILTERS);
  const [applied, setApplied] = useState<Filters>(EMPTY_FILTERS);

  const args = {
    p_action: applied.action || null,
    p_object_type: applied.objectType || null,
    p_actor: applied.actor || null,
    p_from: applied.from || null,
    p_to: applied.to || null,
    p_limit: 200,
  };

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_audit_log", args],
    queryFn: () => callErp<Entry[]>("erp_audit_log", args),
    enabled: allowed,
  });

  if (!allowed) {
    return (
      <div className="flex min-w-0 flex-col gap-6">
        <PageHeader title={t("audit.title", "Audit log")}>
          {t(
            "audit.blurb",
            "Every recorded action in this tenant: who did what, to which object, and when.",
          )}
        </PageHeader>
        <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
          This account does not hold{" "}
          <code className="font-mono text-xs">administration.audit_read</code>, so the audit trail
          is not offered. Absence of a grant is a refusal, not a default.
        </p>
      </div>
    );
  }

  const field =
    "w-full rounded-md border border-input bg-background px-3 py-2 text-sm outline-none focus-visible:ring-2 focus-visible:ring-ring";

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("audit.title", "Audit log")}>
        {t(
          "audit.blurb",
          "Every recorded action in this tenant: who did what, to which object, and when.",
        )}
      </PageHeader>

      <form
        className="grid min-w-0 grid-cols-2 gap-3 rounded-xl border border-border bg-card p-4 sm:grid-cols-3 sm:p-5 lg:grid-cols-6"
        onSubmit={(e) => {
          e.preventDefault();
          setApplied(draft);
        }}
      >
        <label className="flex min-w-0 flex-col gap-1">
          <span className="text-xs font-medium text-muted-foreground">
            {t("audit.filter_action", "Action")}
          </span>
          <select
            className={field}
            value={draft.action}
            onChange={(e) => setDraft({ ...draft, action: e.target.value })}
          >
            <option value="">Any</option>
            {ACTIONS.map((a) => (
              <option key={a} value={a}>
                {a}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="text-xs font-medium text-muted-foreground">
            {t("audit.filter_object", "Object type")}
          </span>
          <input
            className={field}
            placeholder="party, item, document…"
            value={draft.objectType}
            onChange={(e) => setDraft({ ...draft, objectType: e.target.value })}
          />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="text-xs font-medium text-muted-foreground">
            {t("audit.filter_actor", "Actor")}
          </span>
          <input
            className={field}
            placeholder="Name contains…"
            value={draft.actor}
            onChange={(e) => setDraft({ ...draft, actor: e.target.value })}
          />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="text-xs font-medium text-muted-foreground">
            {t("audit.filter_from", "From")}
          </span>
          <input
            type="date"
            className={field}
            value={draft.from}
            onChange={(e) => setDraft({ ...draft, from: e.target.value })}
          />
        </label>
        <label className="flex min-w-0 flex-col gap-1">
          <span className="text-xs font-medium text-muted-foreground">
            {t("audit.filter_to", "To")}
          </span>
          <input
            type="date"
            className={field}
            value={draft.to}
            onChange={(e) => setDraft({ ...draft, to: e.target.value })}
          />
        </label>
        <div className="flex items-end">
          <button
            type="submit"
            className={`${TOUCH} w-full rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground`}
          >
            {t("audit.apply", "Apply filters")}
          </button>
        </div>
      </form>

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <div className="px-4 py-4 sm:px-5">
          {isPending ? (
            <p className="text-sm text-muted-foreground">Loading…</p>
          ) : error ? (
            <div role="alert">
              <p className="text-sm font-medium text-destructive">This did not load.</p>
              <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
            </div>
          ) : !data || data.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {t("audit.empty", "No audit entries match these filters.")}
            </p>
          ) : (
            <Table
              columns={[
                t("audit.col_when", "When"),
                t("audit.col_actor", "Actor"),
                t("audit.col_action", "Action"),
                t("audit.col_object", "Object"),
                t("audit.col_fields", "Changed fields"),
                t("audit.col_reason", "Reason"),
              ]}
            >
              {data.map((e) => (
                <tr key={e.id} className="border-b border-border last:border-0">
                  <td className="py-2 pr-4 whitespace-nowrap text-muted-foreground">
                    {new Date(e.occurred_at).toLocaleString(undefined, {
                      dateStyle: "medium",
                      timeStyle: "short",
                    })}
                  </td>
                  <td className="py-2 pr-4">
                    {e.actor ?? "—"}
                    {e.actor_kind ? (
                      <span className="ml-1 text-xs text-muted-foreground">({e.actor_kind})</span>
                    ) : null}
                  </td>
                  <td className="py-2 pr-4">
                    <Pill tone={tone(e.action)}>{e.action}</Pill>
                  </td>
                  <td className="py-2 pr-4">
                    {e.object_type ?? "—"}
                    {e.object_key ? (
                      <span className="ml-1 text-xs text-muted-foreground">{e.object_key}</span>
                    ) : null}
                  </td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">
                    {e.changed_fields?.join(", ") || "—"}
                  </td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{e.reason ?? "—"}</td>
                </tr>
              ))}
            </Table>
          )}
        </div>
      </section>
    </div>
  );
}
