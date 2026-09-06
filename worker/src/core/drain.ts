import type { TenantBinding, WorkerConfig } from "./config.ts";
import { resolveCredential } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";
import { drainEmail } from "./email.ts";
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
  /** Dry runs settled as simulated without a request. */
  commandsSimulated: number;
  /** Requests sent that got no answer; left for a person, never resent blindly. */
  commandsAmbiguous: number;
  emailClaimed: number;
  emailSent: number;
  emailFailed: number;
  tenantsPurged: number;
  /** What erp.reclaim_stranded_work() returned to the queues before this pass claimed anything. */
  reclaimed: { commands: number; runs: number; messages: number; email: number };
};

const empty = (): DrainReport => ({
  jobsClaimed: 0,
  jobsSucceeded: 0,
  jobsFailed: 0,
  messagesClaimed: 0,
  messagesSent: 0,
  messagesFailed: 0,
  commandsClaimed: 0,
  commandsSucceeded: 0,
  commandsFailed: 0,
  commandsSimulated: 0,
  commandsAmbiguous: 0,
  emailClaimed: 0,
  emailSent: 0,
  emailFailed: 0,
  tenantsPurged: 0,
  reclaimed: { commands: 0, runs: 0, messages: 0, email: 0 },
});

/** The counterpart answered, and said no. */
export class Refused extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
  }
}

/**
 * The counterpart did not answer at all — a timeout, a reset, a connection
 * that never opened. After the request has left, this is the one outcome
 * that must not be retried blindly: the counterpart may have it.
 */
export class NoResponse extends Error {}

/**
 * A handler that does not exist is a job that will never run.
 *
 * Checked once at startup rather than discovered at 3am by a job that has been
 * quietly failing to fire. B9 refuses a job naming an unknown handler_code, so
 * this is the other half of that promise: the database knows the handler is
 * declared, and only the worker knows whether anything implements it.
 *
 * A handler with a SQL body is implemented — by the database, through
 * erp.run_claimed_job(). Only a handler that has no SQL body and nothing
 * registered here is a job that will never run. Until this distinction the
 * check demanded a TypeScript implementation for every enabled job, and since
 * every handler now has a SQL body, a worker pointed at a real organisation
 * refused to start.
 */
export async function assertHandlersExist(sql: Sql): Promise<void> {
  const rows = await sql`
    select distinct j.handler_code
      from erp.job j
      join erp_ref.job_handler h on h.code = j.handler_code
     where j.is_enabled and j.schedule_kind <> 'manual'
       and h.sql_function is null`;

  const missing = rows.map((r) => String(r["handler_code"])).filter((code) => !handlerFor(code));

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
  const claimed = await asPrincipal(
    sql,
    b,
    (tx) => tx`select * from erp.claim_job_runs(${cfg.workerName}, 10)`,
  );

  out.jobsClaimed += claimed.length;

  for (const run of claimed) {
    const runId = run["id"] as string;

    // Each run is its own transaction. One job failing must not roll back the
    // evidence of the ones that already finished.
    const job = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select j.code, j.handler_code, j.parameters
           from erp.job j where j.id = ${run["job_id"] as string}::uuid`,
    );

    const jobCode = String(job[0]?.["code"] ?? "unknown");
    const handlerCode = String(job[0]?.["handler_code"] ?? "");
    const handler = handlerFor(handlerCode);

    if (!handler) {
      // Not this process's to run — but the database may have a body for it.
      // erp.run_claimed_job() executes a SQL handler for a claimed run and
      // settles the run itself; a handler with neither a SQL body nor a
      // registration here is the only thing that fails. Until this branch the
      // worker failed every SQL-handled job it happened to claim first.
      const [settled] = await asPrincipal(
        sql,
        b,
        (tx) => tx`select erp.run_claimed_job(${runId}::bigint) as outcome`,
      );
      const outcome = (settled?.["outcome"] ?? {}) as { outcome?: string };
      if (outcome.outcome === "ok") out.jobsSucceeded += 1;
      else out.jobsFailed += 1;
      continue;
    }

    try {
      const summary = await asPrincipal(sql, b, (tx) =>
        handler({
          tx,
          tenantId: b.tenantId,
          jobCode,
          parameters: (job[0]?.["parameters"] ?? {}) as Record<string, unknown>,
        }),
      );

      await asPrincipal(
        sql,
        b,
        (tx) =>
          tx`select erp.complete_job_run(${runId}::bigint, ${JSON.stringify(summary)}::jsonb)`,
      );
      out.jobsSucceeded += 1;
    } catch (err) {
      // The database decides what a failure costs — backoff, or the failing
      // flag once attempts are exhausted. The worker only reports.
      await asPrincipal(
        sql,
        b,
        (tx) => tx`select erp.fail_job_run(${runId}::bigint, ${String((err as Error).message)})`,
      );
      out.jobsFailed += 1;
    }
  }
}

// ---------------------------------------------------------------------------
// The outbox
// ---------------------------------------------------------------------------

/**
 * Where a system's requests go.
 *
 * The adapter schema for example_http names the address `base_url` and forbids
 * any other key, and this file read `endpoint` — a key no valid connection
 * could carry. Every delivery therefore failed with "has no endpoint
 * configured" against a system whose connection was exactly as the schema
 * required. `endpoint` is still honoured for an adapter that declares it;
 * `base_url` is what the shipped adapter says.
 */
function endpointOf(connection: unknown): string | null {
  const c = (connection ?? {}) as Record<string, unknown>;
  const value = c["endpoint"] ?? c["base_url"];
  return typeof value === "string" && value.length > 0 ? value : null;
}

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
  idempotencyKey: string | null,
  timeoutMs: number,
): Promise<void> {
  if (!endpoint) {
    throw new Error(`external system ${systemCode} has no endpoint configured`);
  }

  // The command's own key travels with it, so a receiver can tell a retry of
  // the same command from a second command that happens to look alike. D19:
  // an outbound write carries its idempotency key all the way out.
  //
  // Bounded. A request with no timeout could outlive its lease, and a hung
  // socket would stall every organisation behind this one in the pass.
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(credential ? { authorization: `Bearer ${credential}` } : {}),
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (err) {
    // No answer of any kind: the counterpart may or may not have the request.
    throw new NoResponse(
      `${systemCode} gave no answer within ${timeoutMs} ms: ${(err as Error).name}`,
    );
  }

  if (!response.ok) {
    // Status and a bounded slice of the body. Never the request headers, which
    // is where the credential is.
    const body = (await response.text()).slice(0, 500);
    throw new Refused(`${systemCode} responded ${response.status}: ${body}`, response.status);
  }
}

/** The timeout for one system: its connection's own, or the worker's default. */
function timeoutFor(connection: unknown, cfg: WorkerConfig): number {
  const c = (connection ?? {}) as Record<string, unknown>;
  const own = Number(c["timeout_ms"]);
  return Number.isFinite(own) && own > 0 ? Math.min(own, cfg.httpTimeoutMs) : cfg.httpTimeoutMs;
}

async function drainOutbox(sql: Sql, b: TenantBinding, cfg: WorkerConfig, out: DrainReport) {
  for (const systemCode of cfg.systems) {
    const claimed = await asPrincipal(
      sql,
      b,
      (tx) => tx`select * from erp.claim_message_batch(${systemCode}, 50, ${cfg.workerName})`,
    );

    if (claimed.length === 0) continue;
    out.messagesClaimed += claimed.length;

    const [system] = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select connection, credential_ref from erp.external_system
          where tenant_id = ${b.tenantId}::uuid and code = ${systemCode}`,
    );

    const endpoint = endpointOf(system?.["connection"]);
    const credential = resolveCredential((system?.["credential_ref"] ?? null) as string | null);

    for (const message of claimed) {
      const id = message["id"] as string;
      try {
        // The message's own external id is its key on the wire; a message
        // without one is keyed by its row, which is stable across retries.
        await deliver(
          systemCode,
          endpoint ?? null,
          credential,
          message["payload"],
          (message["external_message_id"] as string | null) ?? `clove-message-${id}`,
          timeoutFor(system?.["connection"], cfg),
        );
        await asPrincipal(sql, b, (tx) => tx`select erp.complete_message(${id}::bigint)`);
        out.messagesSent += 1;
      } catch (err) {
        // 4xx is the receiver saying "never"; retrying is noise. Anything else
        // may be transient and keeps its attempts.
        const text = String((err as Error).message);
        const permanent =
          err instanceof Refused && err.status >= 400 && err.status < 500 && err.status !== 429;
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.fail_message(${id}::bigint, ${text}, ${!permanent})`,
        );
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
    const claimed = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select * from erp.claim_command_batch(${systemCode}, 20, ${cfg.workerName},
                                               make_interval(secs => ${cfg.leaseSeconds}))`,
    );

    if (claimed.length === 0) continue;
    out.commandsClaimed += claimed.length;

    const [system] = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select connection, credential_ref from erp.external_system
          where tenant_id = ${b.tenantId}::uuid and code = ${systemCode}`,
    );

    const endpoint = endpointOf(system?.["connection"]);
    const credential = resolveCredential((system?.["credential_ref"] ?? null) as string | null);
    const timeoutMs = timeoutFor(system?.["connection"], cfg);

    for (const command of claimed) {
      const id = command["id"] as string;

      // A dry run is a rehearsal. Sending it would make "simulated" a lie, and
      // the gateway has a constraint saying a dry run may never reach
      // 'succeeded'; complete_command settles a dry run as 'simulated'. (It
      // used to be released back to the queue, which only 'approved' commands
      // can be — so it raised, failed the pass, and was claimed again every
      // pass for ever.)
      if (command["dry_run"] === true) {
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.complete_command(${id}::uuid, '{"simulated": true}'::jsonb)`,
        );
        out.commandsSimulated += 1;
        continue;
      }

      // The mark goes to the database before the request goes to the wire.
      // If this process dies between the two, the reclaimer reads the mark and
      // knows the request may have left; without it, it would resend.
      let sent = false;
      try {
        await asPrincipal(sql, b, (tx) => tx`select erp.mark_command_sent(${id}::uuid)`);
        sent = true;
        await deliver(
          systemCode,
          endpoint ?? null,
          credential,
          command["payload"],
          (command["idempotency_key"] as string | null) ?? null,
          timeoutMs,
        );
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.complete_command(${id}::uuid, '{}'::jsonb)`,
        );
        out.commandsSucceeded += 1;
      } catch (err) {
        const text = String((err as Error).message);
        if (sent && err instanceof NoResponse) {
          // D19: an outcome that is unknown is said to be unknown. A person
          // with access to the counterpart settles it; nothing resends it.
          await asPrincipal(
            sql,
            b,
            (tx) => tx`select erp.mark_command_ambiguous(${id}::uuid, ${text})`,
          );
          out.commandsAmbiguous += 1;
          continue;
        }
        // 4xx other than 429 is the counterpart saying "never". Everything
        // else — 5xx, 429, or this process failing before the send — keeps
        // its attempts.
        const permanent =
          err instanceof Refused && err.status >= 400 && err.status < 500 && err.status !== 429;
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.fail_command(${id}::uuid, ${text}, ${!permanent})`,
        );
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
    console.log(`[clove-erp] purged company ${String(row["code"])}: grace period elapsed`);
  }
}

/**
 * What a dead worker left behind, returned to the queues before this pass
 * claims anything: commands past their lease (back to the queue, or ambiguous
 * if the request had left), runs that timed out, messages and email a worker
 * abandoned. Runs here as well as in the minute pass, so stranded work is
 * reclaimed wherever anything drains at all.
 */
async function reclaimStranded(sql: Sql, b: TenantBinding, out: DrainReport) {
  const [row] = await asPrincipal(sql, b, (tx) => tx`select erp.reclaim_stranded_work() as r`);
  const r = (row?.["r"] ?? {}) as Record<string, number>;
  out.reclaimed.commands += Number(r["commands"] ?? 0);
  out.reclaimed.runs += Number(r["runs"] ?? 0);
  out.reclaimed.messages += Number(r["messages"] ?? 0);
  out.reclaimed.email += Number(r["email"] ?? 0);
}

export async function drainOnce(sql: Sql, cfg: WorkerConfig): Promise<DrainReport> {
  const out = empty();
  const startedAt = new Date();
  await sweepDeletedTenants(sql, out);
  for (const binding of cfg.bindings) {
    await reclaimStranded(sql, binding, out);
    await drainJobs(sql, binding, cfg, out);
    await drainOutbox(sql, binding, cfg, out);
    await drainCommands(sql, binding, cfg, out);
    await drainEmail(sql, binding, cfg, out);
  }
  // The evidence. A pass that drained nothing is still a pass, and the console
  // reads the last one to say whether anybody is draining at all; a worker that
  // cannot record its pass is reported by the exception, not hidden by it.
  // sql.json, not a stringified cast: the driver would send the string as a
  // JSON string and the register would hold "{...}" in quotes, unreadable to
  // anything that wants a count out of it.
  await sql`select erp.record_drain_pass(${cfg.workerName}, ${startedAt}, ${sql.json(JSON.parse(JSON.stringify(out)))})`;
  return out;
}
