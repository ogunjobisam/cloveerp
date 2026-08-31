import type { TenantBinding, WorkerConfig } from "./config.ts";
import { resolveCredential } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";
import { handlerFor, registeredCodes } from "./handlers.ts";

export type DrainReport = {
  jobsClaimed: number;
  jobsSucceeded: number;
  jobsFailed: number;
  messagesClaimed: number;
  messagesSent: number;
  messagesFailed: number;
  commandsClaimed: number;
  commandsSucceeded: number;
  commandsFailed: number;
  tenantsPurged: number;
};

const empty = (): DrainReport => ({
  jobsClaimed: 0, jobsSucceeded: 0, jobsFailed: 0,
  messagesClaimed: 0, messagesSent: 0, messagesFailed: 0,
  commandsClaimed: 0, commandsSucceeded: 0, commandsFailed: 0,
  tenantsPurged: 0,
});

/**
 * A handler that does not exist is a job that will never run.
 *
 * Checked once at startup rather than discovered at 3am by a job that has been
 * quietly failing to fire. B9 refuses a job naming an unknown handler_code, so
 * this is the other half of that promise: the database knows the handler is
 * declared, and only the worker knows whether anything implements it.
 */
export async function assertHandlersExist(sql: Sql): Promise<void> {
  const rows = await sql`
    select distinct j.handler_code
      from erp.job j
     where j.is_enabled and j.schedule_kind <> 'manual'`;

  const missing = rows
    .map((r) => String(r["handler_code"]))
    .filter((code) => !handlerFor(code));

  if (missing.length > 0) {
    throw new Error(
      `No implementation for scheduled handler(s): ${missing.join(", ")}. ` +
        `Registered here: ${registeredCodes().join(", ") || "(none)"}. ` +
        `Refusing to start: these jobs would look scheduled and never run.`,
    );
  }
}

// ---------------------------------------------------------------------------
// Scheduled jobs
// ---------------------------------------------------------------------------

async function drainJobs(sql: Sql, b: TenantBinding, cfg: WorkerConfig, out: DrainReport) {
  const claimed = await asPrincipal(sql, b, (tx) =>
    tx`select * from erp.claim_job_runs(${cfg.workerName}, 10)`);

  out.jobsClaimed += claimed.length;

  for (const run of claimed) {
    const runId = run["id"] as string;

    // Each run is its own transaction. One job failing must not roll back the
    // evidence of the ones that already finished.
    const job = await asPrincipal(sql, b, (tx) =>
      tx`select j.code, j.handler_code, j.parameters
           from erp.job j where j.id = ${run["job_id"] as string}::uuid`);

    const jobCode = String(job[0]?.["code"] ?? "unknown");
    const handlerCode = String(job[0]?.["handler_code"] ?? "");
    const handler = handlerFor(handlerCode);

    if (!handler) {
      await asPrincipal(sql, b, (tx) =>
        tx`select erp.fail_job_run(${runId}::bigint,
             ${`no handler registered for ${handlerCode}`}, '{}'::jsonb, false)`);
      out.jobsFailed += 1;
      continue;
    }

    try {
      const summary = await asPrincipal(sql, b, (tx) =>
        handler({
          tx,
          tenantId: b.tenantId,
          jobCode,
          parameters: (job[0]?.["parameters"] ?? {}) as Record<string, unknown>,
        }));

      await asPrincipal(sql, b, (tx) =>
        tx`select erp.complete_job_run(${runId}::bigint, ${JSON.stringify(summary)}::jsonb)`);
      out.jobsSucceeded += 1;
    } catch (err) {
      // The database decides what a failure costs — backoff, or the failing
      // flag once attempts are exhausted. The worker only reports.
      await asPrincipal(sql, b, (tx) =>
        tx`select erp.fail_job_run(${runId}::bigint, ${String((err as Error).message)})`);
      out.jobsFailed += 1;
    }
  }
}

// ---------------------------------------------------------------------------
// The outbox
// ---------------------------------------------------------------------------

/**
 * Delivering one message to one external system.
 *
 * Deliberately the only place a credential is touched. It is resolved from the
 * environment, used, and dropped — never written back, and never logged: the
 * error text goes into erp.integration_message.last_error, which is a table
 * somebody can read.
 */
async function deliver(
  systemCode: string,
  endpoint: string | null,
  credential: string | null,
  payload: unknown,
): Promise<void> {
  if (!endpoint) {
    throw new Error(`external system ${systemCode} has no endpoint configured`);
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(credential ? { authorization: `Bearer ${credential}` } : {}),
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    // Status and a bounded slice of the body. Never the request headers, which
    // is where the credential is.
    const body = (await response.text()).slice(0, 500);
    throw new Error(`${systemCode} responded ${response.status}: ${body}`);
  }
}

async function drainOutbox(sql: Sql, b: TenantBinding, cfg: WorkerConfig, out: DrainReport) {
  for (const systemCode of cfg.systems) {
    const claimed = await asPrincipal(sql, b, (tx) =>
      tx`select * from erp.claim_message_batch(${systemCode}, 50, ${cfg.workerName})`);

    if (claimed.length === 0) continue;
    out.messagesClaimed += claimed.length;

    const [system] = await asPrincipal(sql, b, (tx) =>
      tx`select connection, credential_ref from erp.external_system
          where tenant_id = ${b.tenantId}::uuid and code = ${systemCode}`);

    const endpoint = ((system?.["connection"] ?? {}) as Record<string, unknown>)["endpoint"] as
      | string
      | null;
    const credential = resolveCredential((system?.["credential_ref"] ?? null) as string | null);

    for (const message of claimed) {
      const id = message["id"] as string;
      try {
        await deliver(systemCode, endpoint ?? null, credential, message["payload"]);
        await asPrincipal(sql, b, (tx) => tx`select erp.complete_message(${id}::bigint)`);
        out.messagesSent += 1;
      } catch (err) {
        // 4xx is the receiver saying "never"; retrying is noise. Anything else
        // may be transient and keeps its attempts.
        const text = String((err as Error).message);
        const permanent = /responded 4\d\d/.test(text);
        await asPrincipal(sql, b, (tx) =>
          tx`select erp.fail_message(${id}::bigint, ${text}, ${!permanent})`);
        out.messagesFailed += 1;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outbound commands
// ---------------------------------------------------------------------------

async function drainCommands(sql: Sql, b: TenantBinding, cfg: WorkerConfig, out: DrainReport) {
  for (const systemCode of cfg.systems) {
    const claimed = await asPrincipal(sql, b, (tx) =>
      tx`select * from erp.claim_command_batch(${systemCode}, 20, ${cfg.workerName})`);

    if (claimed.length === 0) continue;
    out.commandsClaimed += claimed.length;

    const [system] = await asPrincipal(sql, b, (tx) =>
      tx`select connection, credential_ref from erp.external_system
          where tenant_id = ${b.tenantId}::uuid and code = ${systemCode}`);

    const endpoint = ((system?.["connection"] ?? {}) as Record<string, unknown>)["endpoint"] as
      | string
      | null;
    const credential = resolveCredential((system?.["credential_ref"] ?? null) as string | null);

    for (const command of claimed) {
      const id = command["id"] as string;

      // A dry run is a rehearsal. Sending it would make "simulated" a lie, and
      // the gateway has a constraint saying a dry run may never reach
      // 'succeeded'.
      if (command["dry_run"] === true) {
        await asPrincipal(sql, b, (tx) => tx`select erp.release_command(${id}::uuid)`);
        continue;
      }

      try {
        await deliver(systemCode, endpoint ?? null, credential, command["payload"]);
        await asPrincipal(sql, b, (tx) =>
          tx`select erp.complete_command(${id}::uuid, '{}'::jsonb)`);
        out.commandsSucceeded += 1;
      } catch (err) {
        const text = String((err as Error).message);
        const permanent = /responded 4\d\d/.test(text);
        await asPrincipal(sql, b, (tx) =>
          tx`select erp.fail_command(${id}::uuid, ${text}, ${!permanent})`);
        out.commandsFailed += 1;
      }
    }
  }
}

/** One pass over everything that is due, for every tenant this worker serves. */
/**
 * Companies whose deletion grace period has elapsed.
 *
 * Deliberately not an erp.job, and the reason is worth stating where somebody
 * would otherwise try to "fix" it: erp.job.tenant_id is NOT NULL and drainJobs
 * claims runs under a per-tenant binding, so a sweep scheduled that way would
 * belong to one arbitrary company and run under its context while deleting
 * others. Purging companies is platform work, so it runs once per pass on the
 * service connection rather than inside the binding loop.
 *
 * An administrator's deletion request is what sets deleted_at; a suspension
 * alone never does. So this only ever finishes something somebody asked for.
 */
async function sweepDeletedTenants(sql: Sql, out: DrainReport) {
  const purged = await sql`select code from erp.purge_due_tenants()`;
  out.tenantsPurged += purged.length;
  for (const row of purged) {
    console.log(`[erpware] purged company ${String(row["code"])}: grace period elapsed`);
  }
}

export async function drainOnce(sql: Sql, cfg: WorkerConfig): Promise<DrainReport> {
  const out = empty();
  await sweepDeletedTenants(sql, out);
  for (const binding of cfg.bindings) {
    await drainJobs(sql, binding, cfg, out);
    await drainOutbox(sql, binding, cfg, out);
    await drainCommands(sql, binding, cfg, out);
  }
  return out;
}
