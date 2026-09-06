import { useQuery } from "@tanstack/react-query";

import { callErp, supabase } from "./erp";

/**
 * The platform layer: the product's own staff, above every tenant.
 *
 * A tenant administrator is the most powerful person inside one company. This
 * is the other axis — the people who run the product itself, who create those
 * companies and can be let into them to help. It is deliberately a separate
 * list with its own three roles rather than a permission inside a tenant,
 * because "can administer Acme" and "can create companies" are not the same
 * claim and should never be reachable from one another.
 */

export type PlatformRole = "owner" | "operator" | "support";

export type PlatformMe = {
  is_staff: boolean;
  role: PlatformRole | null;
  email?: string | null;
  display_name?: string | null;
  /** True only when the staff list is empty: the platform has no owner yet. */
  claimable: boolean;
};

export type PlatformTenant = {
  id: string;
  code: string;
  name: string;
  status: string;
  created_at: string;
  provisioned_at: string | null;
  suspended_at: string | null;
  principals: number;
  entities: number;
  sites: number;
  open_invitations: number;
  /** Which platform owner is accountable for this company, if any yet. */
  owner_staff_id: string | null;
  owner_email: string | null;
  owner_name: string | null;
  owned_by_me: boolean | null;
  owner_since: string | null;
  /** Set while an offer is open, so the row can say so rather than offer again. */
  pending_transfer_to: string | null;
};

/**
 * An offer to hand a company to another owner.
 *
 * The row outlives the decision: declined and withdrawn offers stay exactly
 * where they are, because who was asked and refused is part of the record.
 */
export type OwnershipTransfer = {
  id: string;
  tenant_id: string;
  tenant_code: string | null;
  tenant_name: string | null;
  from_staff_id: string;
  from_email: string;
  from_name: string;
  to_staff_id: string;
  to_email: string;
  to_name: string;
  status: "pending" | "accepted" | "declined" | "cancelled" | "expired";
  reason: string | null;
  response_note: string | null;
  expires_at: string;
  created_at: string;
  settled_at: string | null;
  is_mine_to_answer: boolean;
  is_mine_to_withdraw: boolean;
};

export type PlatformStaff = {
  id: string;
  email: string;
  display_name: string;
  role: PlatformRole;
  bound: boolean;
  created_at: string;
  revoked_at: string | null;
};

export type PlatformAuditRow = {
  id: number;
  occurred_at: string;
  actor_email: string | null;
  actor_role: string | null;
  action: string;
  tenant_code: string | null;
  target: string | null;
  reason: string | null;
  detail: Record<string, unknown>;
};

const RANK: Record<PlatformRole, number> = { owner: 3, operator: 2, support: 1 };

export function atLeast(role: PlatformRole | null | undefined, min: PlatformRole): boolean {
  return role ? RANK[role] >= RANK[min] : false;
}

export const ROLE_BLURB: Record<PlatformRole, string> = {
  owner: "Full control, including who else works on the platform.",
  operator: "Onboards and manages companies, and invites their administrators.",
  support: "Reads the company list and the activity log, and may be let in to help.",
};

/**
 * Asked once wherever the console might be offered. It answers on every
 * signed-in account, staff or not, so the absence of a menu entry is a fact
 * rather than a guess.
 */
export function usePlatformMe(enabled = true) {
  return useQuery({
    queryKey: ["erp_platform_me"],
    queryFn: () => callErp<PlatformMe>("erp_platform_me"),
    enabled: Boolean(supabase) && enabled,
    staleTime: 60_000,
  });
}

/* -------------------------------------------------------------------------- */
/* The superadmin console's reads.                                            */
/* -------------------------------------------------------------------------- */

export type DiagnosticCheck = {
  code: string;
  title: string;
  kind: "assertion" | "report";
  scope: "platform" | "tenant";
  blurb: string;
  runs_in_ci: boolean;
  has_detail: boolean;
  function: string;
};

/**
 * `ok` is deliberately nullable: a tenant-scoped check run outside an
 * organisation is neither passing nor failing, and reporting it as failed would
 * be a claim about the organisation rather than about the check.
 */
export type CheckResult = {
  code: string;
  title?: string;
  check: string;
  scope: "platform" | "tenant";
  blurb?: string;
  ok: boolean | null;
  summary: string | null;
  detail: string | null;
  findings: Record<string, unknown>[];
};

export type JobHandler = {
  code: string;
  description: string;
  runs_in_database: boolean;
  default_timeout_seconds: number;
};

export type DrainResult = {
  claimed: number;
  succeeded: number;
  failed: number;
  needs_worker: number;
  organisations: {
    organisation: string;
    runs: { job: string; outcome: string; error?: string }[];
  }[];
};

export type MyTenancy = {
  tenant_id: string;
  code: string;
  name: string;
  status: string;
  principal_status: string;
  is_active: boolean;
  holds_administrator: boolean;
  is_current: boolean;
};

export type TenantConfiguration = {
  tenant_id: string;
  code: string;
  name: string;
  status: string;
  is_live: boolean;
  has_self_environment: boolean;
  entities: number;
  sites: number;
  principals: number;
  ledgers: number;
  accounts: number;
  document_types: number;
  posting_rules: number;
  jobs: number;
  modules_installed: string[];
  change_sets_awaiting: number;
  determination_findings: number;
};

/** One deploy of main to live, as erp_meta.release records it. */
export type Release = {
  id: string;
  recorded_at: string;
  deployed_at_start: string;
  git_sha: string;
  app_build: string | null;
  migrations_recorded: number;
  migrations_high: string | null;
  proved: boolean;
  recorded_by: string;
  ledger_now: string | null;
  moved_since: boolean;
  note: string | null;
};

export type DeploymentState = {
  migrations_known: boolean;
  migrations: { version: string; name: string | null }[];
  counts: Record<string, number>;
  registers: Record<string, number>;
  /** The last five releases; empty on a database nothing has deployed to. */
  releases?: Release[];
  generated_at: string;
};
