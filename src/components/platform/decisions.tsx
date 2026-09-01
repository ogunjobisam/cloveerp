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

/** Decisions the code alone does not explain. */

type PolicyDecision = {
  code: string;
  title: string;
  spec_reference: string | null;
  decision: string;
  rationale: string;
  status: "accepted" | "open" | "superseded";
  evidence: string | null;
  decided_by: string | null;
  decided_at: string;
};

/**
 * Decisions the code alone does not explain.
 *
 * Read-only on purpose. A decision is taken in a migration, with the reasoning
 * beside it in the diff; a form would let one be typed in without either.
 */
export function Decisions() {
  const rows = useQuery({
    queryKey: ["erp_platform_policy_decisions"],
    queryFn: () => callErp<PolicyDecision[]>("erp_platform_policy_decisions"),
  });

  return (
    <Card
      title="Decisions"
      icon={<Gavel className="size-4 text-primary" />}
      description="Deliberate deviations from the specification, and questions deliberately left open. Open ones first."
    >
      {rows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : rows.error ? (
        <Fail error={rows.error} />
      ) : (rows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">Nothing recorded yet.</p>
      ) : (
        <ul className="flex flex-col gap-5">
          {(rows.data ?? []).map((d) => (
            <li key={d.code} className="border-b border-border/60 pb-5 last:border-0 last:pb-0">
              <div className="flex flex-wrap items-center gap-2">
                <Pill
                  tone={d.status === "open" ? "warn" : d.status === "accepted" ? "ok" : "muted"}
                >
                  {d.status}
                </Pill>
                <span className="text-sm font-semibold">{d.title}</span>
                {d.spec_reference ? (
                  <span className="text-xs text-muted-foreground">{d.spec_reference}</span>
                ) : null}
              </div>
              <p className="mt-2 text-sm">{d.decision}</p>
              <p className="mt-2 text-sm text-muted-foreground">{d.rationale}</p>
              {d.evidence ? (
                <p className="mt-2 text-xs text-muted-foreground">
                  <span className="font-medium">Visible in:</span> {d.evidence}
                </p>
              ) : null}
              <p className="mt-2 text-xs text-muted-foreground">
                {d.decided_by
                  ? `${d.decided_by} · ${new Date(d.decided_at).toLocaleDateString()}`
                  : "Not yet decided"}
              </p>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
