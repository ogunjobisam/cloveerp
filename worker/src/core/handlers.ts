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

/**
 * Reads each provider's status feed and records what it says.
 *
 * Specification v1.6 §16.5: an outage below the platform is the platform's
 * incident to communicate. erp.record_dependency_status() declares a
 * severity-3 incident with the origin stated when a feed reports major or
 * critical impact, and resolves it on recovery; this handler only carries the
 * feed's word to it. A feed that cannot be read is recorded as `unknown`, not
 * as an outage — silence from a status page is not evidence of one.
 *
 * `feed_base_url` in the job's parameters replaces every feed with
 * `<base>/<code>/status.json`, which is how the build rehearses this against
 * the stub without reaching the internet.
 */
register("platform.poll_dependency_status", async ({ tx, parameters }) => {
  const base = typeof parameters["feed_base_url"] === "string" ? parameters["feed_base_url"] : null;
  const deps = await tx`
    select code, feed_url from erp_ref.platform_dependency
     where feed_kind = 'statuspage_v2' order by seq`;
  const results: Record<string, unknown>[] = [];
  let declared = 0;
  let resolved = 0;
  for (const d of deps) {
    const code = String(d["code"]);
    const url = base ? `${base.replace(/\/$/, "")}/${code}/status.json` : String(d["feed_url"]);
    let indicator = "unknown";
    let description: string | null = null;
    let raw: unknown = {};
    try {
      const res = await fetch(url, {
        headers: { accept: "application/json" },
        signal: AbortSignal.timeout(10_000),
      });
      if (res.ok) {
        raw = await res.json();
        const status = (raw as { status?: { indicator?: unknown; description?: unknown } }).status;
        const ind = typeof status?.indicator === "string" ? status.indicator : "unknown";
        indicator = ["none", "minor", "major", "critical"].includes(ind) ? ind : "unknown";
        description = typeof status?.description === "string" ? status.description : null;
      } else {
        description = `feed answered ${res.status}`;
      }
    } catch (e) {
      description = `feed unreachable: ${e instanceof Error ? e.message : String(e)}`;
    }
    const [row] = await tx`
      select erp.record_dependency_status(${code}, ${indicator}, ${description},
                                          ${tx.json(JSON.parse(JSON.stringify(raw ?? {})))}, 'worker') as outcome`;
    const outcome = (row?.["outcome"] ?? {}) as {
      declared?: string | null;
      resolved?: string | null;
    };
    if (outcome.declared) declared += 1;
    if (outcome.resolved) resolved += 1;
    results.push({
      dependency: code,
      indicator,
      description,
      declared: outcome.declared ?? null,
      resolved: outcome.resolved ?? null,
    });
  }
  return { polled: results.length, declared, resolved, feeds: results };
});
