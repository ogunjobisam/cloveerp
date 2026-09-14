/**
 * The deletion sweep's answer, as the platform console reads it.
 *
 * `erp_platform_purge_due_tenants` returns one object, not a list of rows:
 * `{ purged, organisations: [{ tenant_id, code, deleted_at }], grace_days }`
 * (supabase/migrations/20260831214239_…). The Jobs screen once counted it as an
 * array and so always said nothing was purged, whatever the sweep had removed.
 * Pure: no React, no Supabase client.
 */

export type PurgedOrganisation = {
  tenant_id: string;
  code: string;
  deleted_at: string | null;
};

export type PurgeSweep = {
  purged: number;
  organisations: PurgedOrganisation[];
  grace_days: number | null;
};

/**
 * What the sweep returned, or null when it cannot be read as the sweep's answer.
 *
 * Null rather than a zero: a count the screen invented is the defect this
 * replaces, and the sweep deletes organisations, so "0 purged" must only ever
 * be the database's own figure.
 */
export function readPurgeSweep(data: unknown): PurgeSweep | null {
  if (typeof data !== "object" || data === null || Array.isArray(data)) return null;
  const raw = data as Record<string, unknown>;

  const organisations = Array.isArray(raw["organisations"])
    ? (raw["organisations"] as unknown[]).flatMap((o) => {
        if (typeof o !== "object" || o === null) return [];
        const r = o as Record<string, unknown>;
        if (typeof r["code"] !== "string") return [];
        return [
          {
            tenant_id: typeof r["tenant_id"] === "string" ? r["tenant_id"] : "",
            code: r["code"],
            deleted_at: typeof r["deleted_at"] === "string" ? r["deleted_at"] : null,
          },
        ];
      })
    : null;

  const purged = raw["purged"];
  const count =
    typeof purged === "number" && Number.isInteger(purged) && purged >= 0
      ? purged
      : organisations?.length;
  if (count === undefined) return null;

  const grace = raw["grace_days"];
  return {
    purged: count,
    organisations: organisations ?? [],
    grace_days: typeof grace === "number" && Number.isFinite(grace) ? grace : null,
  };
}

/** One plain sentence: how many organisations the sweep purged, and which. */
export function purgeSweepSummary(sweep: PurgeSweep): string {
  const days = sweep.grace_days;

  if (sweep.purged === 0) {
    return days === null
      ? "No organisation was purged: none was past its grace period."
      : `No organisation was purged: none had asked to be deleted more than ${days} ${
          days === 1 ? "day" : "days"
        } ago.`;
  }

  const noun = sweep.purged === 1 ? "organisation" : "organisations";
  const codes = sweep.organisations.map((o) => o.code);
  return codes.length > 0
    ? `Purged ${sweep.purged} ${noun}: ${codes.join(", ")}.`
    : `Purged ${sweep.purged} ${noun}.`;
}
