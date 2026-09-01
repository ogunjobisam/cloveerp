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

/** Shaped by erp_platform_product_decisions(): §23's eighteen, in order. */
type ProductDecision = {
  code: string;
  seq: number;
  title: string;
  decision: string;
  rationale: string;
  cost: string | null;
  supersedes: string | null;
  spec_reference: string | null;
  registered_at: string;
  checks: { schema_name: string; routine_name: string; note: string | null }[];
  findings: { finding: string; detail: string }[];
};

/**
 * The decisions the product is built on, each with the routines that enforce
 * it and whatever the enforcement report says today.
 *
 * Read-only for the same reason the policy decisions are: a product decision
 * is taken in a migration with its checks beside it, and
 * erp.assert_product_decisions_enforced() fails the build when a check names
 * a routine that is gone. A decision with a finding here is one the build
 * would refuse — the same report, read live.
 */
export function ProductDecisions() {
  const rows = useQuery({
    queryKey: ["erp_platform_product_decisions"],
    queryFn: () => callErp<ProductDecision[]>("erp_platform_product_decisions"),
  });

  return (
    <Card
      title="Product decisions"
      icon={<ClipboardList className="size-4 text-primary" />}
      description="What the product is, decided once and enforced by name. Each decision lists the routines that hold it, and any of them that is missing."
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
                <span className="font-mono text-xs text-muted-foreground">{d.seq}</span>
                <span className="text-sm font-semibold">{d.title}</span>
                {d.spec_reference ? (
                  <span className="text-xs text-muted-foreground">{d.spec_reference}</span>
                ) : null}
                {d.findings.length > 0 ? (
                  <Pill tone="bad">
                    {d.findings.length === 1 ? "1 finding" : `${d.findings.length} findings`}
                  </Pill>
                ) : d.checks.length > 0 ? (
                  <Pill tone="ok">Enforced</Pill>
                ) : (
                  <Pill tone="muted">Not checked</Pill>
                )}
              </div>
              <p className="mt-2 text-sm">{d.decision}</p>
              <p className="mt-2 text-sm text-muted-foreground">{d.rationale}</p>
              {d.cost ? (
                <p className="mt-2 text-xs text-muted-foreground">
                  <span className="font-medium">Cost:</span> {d.cost}
                </p>
              ) : null}
              {d.supersedes ? (
                <p className="mt-2 text-xs text-muted-foreground">
                  <span className="font-medium">Supersedes:</span>{" "}
                  <span className="font-mono">{d.supersedes}</span>
                </p>
              ) : null}
              {d.checks.length > 0 ? (
                <ul className="mt-2 flex flex-wrap gap-1.5">
                  {d.checks.map((c) => (
                    <li
                      key={`${c.schema_name}.${c.routine_name}`}
                      className="rounded-md bg-muted px-1.5 py-0.5 font-mono text-xs"
                      title={c.note ?? undefined}
                    >
                      {c.schema_name}.{c.routine_name}
                    </li>
                  ))}
                </ul>
              ) : null}
              {d.findings.length > 0 ? (
                <ul className="mt-2 flex flex-col gap-1">
                  {d.findings.map((f, i) => (
                    <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                      <span className="font-medium">{f.finding}:</span> {f.detail}
                    </li>
                  ))}
                </ul>
              ) : null}
              <p className="mt-2 text-xs text-muted-foreground">
                <span className="font-mono">{d.code}</span> ·{" "}
                {new Date(d.registered_at).toLocaleDateString()}
              </p>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
