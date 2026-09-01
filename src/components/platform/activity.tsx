import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import {
  Archive,
  Building2,
  ClipboardList,
  Copy,
  Gavel,
  LogIn,
  Pause,
  Play,
  Plus,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
} from "lucide-react";

import { OfferOwnership } from "../erp/ownership";
import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  ROLE_BLURB,
  type PlatformAuditRow,
  type PlatformRole,
  type PlatformStaff,
  type PlatformTenant,
} from "../../lib/platform";
import { Card, Fail, TokenNotice, statusTone, INPUT } from "./kit";

/** Every platform action, including each entry into a customer company. */

export function Activity() {
  const [action, setAction] = useState("");
  const rows = useQuery({
    queryKey: ["erp_platform_audit", action],
    queryFn: () =>
      callErp<PlatformAuditRow[]>("erp_platform_audit", {
        p_action: action || null,
        p_tenant_id: null,
        p_limit: 200,
      }),
  });

  return (
    <Card
      title="Platform activity"
      icon={<ClipboardList className="size-4 text-primary" />}
      description="Every platform action, including each entry into a customer company and the reason given."
      action={
        <select
          value={action}
          onChange={(e) => setAction(e.target.value)}
          className="rounded-md border border-input bg-background px-2 py-2 text-xs"
        >
          <option value="">All actions</option>
          <option value="platform.company_onboarded">Organisation onboarded</option>
          <option value="platform.tenant_entered">Organisation entered</option>
          <option value="platform.tenant_left">Organisation left</option>
          <option value="platform.admin_invited">Administrator invited</option>
          <option value="platform.tenant_status_changed">Status changed</option>
          <option value="platform.ownership_offered">Ownership offered</option>
          <option value="platform.ownership_accepted">Ownership accepted</option>
          <option value="platform.ownership_declined">Ownership declined</option>
          <option value="platform.ownership_cancelled">Ownership offer withdrawn</option>
          <option value="platform.staff_added">Staff added</option>
          <option value="platform.staff_role_changed">Staff role changed</option>
          <option value="platform.staff_revoked">Staff removed</option>
        </select>
      }
    >
      {rows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : rows.error ? (
        <Fail error={rows.error} />
      ) : (rows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nothing recorded under this filter.</p>
      ) : (
        <Table columns={["When", "Who", "Action", "Organisation", "Detail"]}>
          {(rows.data ?? []).map((r) => (
            <tr key={r.id} className="border-b border-border/60 last:border-0 align-top">
              <td className="py-3 pr-4 text-xs text-muted-foreground">
                {new Date(r.occurred_at).toLocaleString()}
              </td>
              <td className="py-3 pr-4 text-xs">
                <div>{r.actor_email}</div>
                <div className="text-muted-foreground">{r.actor_role}</div>
              </td>
              <td className="py-3 pr-4 text-sm">{r.action.replace("platform.", "")}</td>
              <td className="py-3 pr-4 font-mono text-xs">{r.tenant_code ?? "—"}</td>
              <td className="py-3 pr-0 text-xs text-muted-foreground">
                {[r.target, r.reason].filter(Boolean).join(" · ") || "—"}
              </td>
            </tr>
          ))}
        </Table>
      )}
    </Card>
  );
}
