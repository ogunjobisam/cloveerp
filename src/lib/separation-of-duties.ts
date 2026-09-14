import { ErpError } from "./erp";

/**
 * Separation of duties, as the desk reads it.
 *
 * The rules are the organisation's own (`erp.sod_rule`, brought by the base
 * pack), and the database applies them whenever somebody is given a role:
 * once the organisation is live, a prohibited pairing is refused unless
 * somebody who may promote configuration records why it is accepted, and
 * anything else is allowed and recorded for review
 * (supabase/migrations/20260914065000_duties_stay_separated.sql). This file
 * holds the shapes `erp_sod_conflicts` and the grant doors return, and the two
 * decisions the screen makes about them. Pure: no React, no Supabase client.
 */

/** The shortest reason the database accepts for an exception. */
export const EXCEPTION_REASON_MIN = 20;

export type DutySeverity = "prohibited" | "material" | "advisory";

/** unrecorded: it stands, and no grant door has recorded it yet. */
export type DutyStatus = "unrecorded" | "open" | "accepted" | "mitigated";

/** One person meeting one rule, as `erp_sod_conflicts` lists it. */
export type DutyConflict = {
  app_user_id: string;
  person: string | null;
  email: string | null;
  rule_code: string;
  rule_name: string;
  severity: DutySeverity;
  description: string | null;
  mitigation: string | null;
  permissions_a: string[];
  permissions_b: string[];
  status: DutyStatus;
  recorded_at: string | null;
  exception_reason: string | null;
  exception_by: string | null;
  exception_at: string | null;
};

export type DutiesReport = {
  is_live: boolean;
  rules: number;
  conflicts: DutyConflict[];
  administrators: { app_user_id: string; person: string | null }[];
};

/** A person's conflicts as a grant door returns them after the change. */
export type SettledConflict = {
  rule_code: string;
  rule_name: string;
  severity: DutySeverity;
  permissions_a: string[];
  permissions_b: string[];
  status: "open" | "accepted" | "mitigated";
  exception_reason: string | null;
};

/** The refusal a grant meets when it would put a prohibited pairing in one person's hands. */
export function isProhibitedPairing(error: unknown): boolean {
  return error instanceof ErpError && error.erpCode === "CLOVEERP_SOD_PROHIBITED";
}

/** What is wrong with the reason for an exception, or null when it will do. */
export function exceptionReasonProblem(reason: string): "empty" | "short" | null {
  const trimmed = reason.trim();
  if (trimmed === "") return "empty";
  if (trimmed.length < EXCEPTION_REASON_MIN) return "short";
  return null;
}

/** Whether a conflict still waits on somebody's decision. */
export function awaitsDecision(conflict: Pick<DutyConflict, "status">): boolean {
  return conflict.status === "open" || conflict.status === "unrecorded";
}

/** The conflicts a grant door reports that somebody should look at. */
export function toReview(conflicts: unknown): SettledConflict[] {
  return Array.isArray(conflicts)
    ? (conflicts as SettledConflict[]).filter((c) => c?.status === "open")
    : [];
}

/**
 * `erp_sod_conflicts`' answer, read without trusting its shape: a screen drawn
 * against an organisation with nothing in it, or a stub that answers `[]`,
 * shows "no rules yet" rather than throwing on a missing list.
 */
export function readDutiesReport(raw: unknown): DutiesReport {
  const o =
    raw !== null && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {};
  const rules = o["rules"];
  const conflicts = o["conflicts"];
  const administrators = o["administrators"];
  return {
    is_live: o["is_live"] === true,
    rules: typeof rules === "number" ? rules : 0,
    conflicts: Array.isArray(conflicts) ? (conflicts as DutyConflict[]) : [],
    administrators: Array.isArray(administrators)
      ? (administrators as DutiesReport["administrators"])
      : [],
  };
}
