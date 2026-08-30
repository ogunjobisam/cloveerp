import type { Sql } from "./db.ts";

/**
 * What a scheduled job actually does.
 *
 * Keyed by erp_ref.job_handler.code. The registry is checked against the
 * database at startup: a job whose handler nothing implements would look
 * perfectly scheduled and never run, and B9 exists to make that state
 * impossible to reach quietly.
 */
export type JobContext = {
  tx: Sql;
  tenantId: string;
  jobCode: string;
  parameters: Record<string, unknown>;
};

/** Returned counts land in erp.job_run.summary, which is what makes a run reviewable. */
export type JobResult = Record<string, unknown>;

export type JobHandler = (ctx: JobContext) => Promise<JobResult>;

const registry = new Map<string, JobHandler>();

export function register(code: string, handler: JobHandler): void {
  registry.set(code, handler);
}

export function handlerFor(code: string): JobHandler | undefined {
  return registry.get(code);
}

export function registeredCodes(): string[] {
  return [...registry.keys()].sort();
}

// ---------------------------------------------------------------------------
// The handlers this worker implements
// ---------------------------------------------------------------------------

/**
 * Reclaims runs whose lease expired because a worker died holding them.
 *
 * Without this a job stays permanently "running", and under a skip or queue
 * overlap policy that silently stops it ever running again — the exact failure
 * B9 was written to prevent, arriving through the worker rather than the
 * schedule.
 */
register("platform.reclaim_timed_out_runs", async ({ tx }) => {
  const [row] = await tx`select erp.reclaim_timed_out_runs() as reclaimed`;
  return { reclaimed: Number(row?.["reclaimed"] ?? 0) };
});

/**
 * Reports jobs that have stopped running.
 *
 * Spec 3.8's dead-man's switch. Running it AS a job is deliberate: if the
 * scheduler stops entirely then this stops too, and its own silence is then
 * reported by whatever watches erp.silent_jobs() from outside.
 */
register("platform.report_silent_jobs", async ({ tx }) => {
  const rows = await tx`select job_code, silent_for::text, finding from erp.silent_jobs()`;
  return {
    silent: rows.length,
    jobs: rows.map((r) => ({
      job: r["job_code"],
      silent_for: r["silent_for"],
      finding: r["finding"],
    })),
  };
});

/** Releases outbound commands whose lease expired. */
register("platform.reclaim_expired_commands", async ({ tx }) => {
  const [row] = await tx`select erp.reclaim_expired_commands() as reclaimed`;
  return { reclaimed: Number(row?.["reclaimed"] ?? 0) };
});
