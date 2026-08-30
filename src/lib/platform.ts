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
