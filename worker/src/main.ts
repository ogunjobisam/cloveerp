/**
 * The long-lived entrypoint.
 *
 * Deploy anywhere that will keep a process alive. The Edge Function entrypoint
 * in supabase/functions/dispatch drives exactly the same core on a cron; the
 * only difference is who decides when a pass happens.
 */
import { loadConfig } from "./core/config.ts";
import { connect } from "./core/db.ts";
import { assertHandlersExist, drainOnce } from "./core/drain.ts";

async function main() {
  const cfg = loadConfig();
  // A long-lived process draining queues: the audit trail says so on every
  // change it makes.
  const sql = connect(cfg.databaseUrl, "dispatch_worker");

  // Before serving anything: refuse to start if a scheduled job names a
  // handler nothing here implements. Starting anyway would present a
  // permanently silent job as a healthy worker.
  await assertHandlersExist(sql);

  let stopping = false;
  const stop = () => {
    // Finish the pass in flight rather than abandoning claimed work; its lease
    // would expire and the run would be reclaimed as timed_out, which is a
    // failure that did not happen.
    stopping = true;
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  // The organisations are not all known here: every pass asks
  // erp.dispatch_bindings() for the active ones nobody named.
  console.log(
    `[clove-erp] ${cfg.workerName} serving every active organisation ` +
      `(erp.dispatch_bindings(), read each pass; ${cfg.bindings.length} named in ` +
      `CLOVEERP_TENANTS with their own principal), ` +
      `systems: ${cfg.systems.join(", ") || "(none)"}, ` +
      `lease ${cfg.leaseSeconds}s, request timeout ${cfg.httpTimeoutMs}ms`,
  );

  // CLOVEERP_ONCE=1: one pass, then exit. What the build runs to prove a queue
  // drains in anger, and what an operator runs by hand to see one pass happen.
  const once = process.env["CLOVEERP_ONCE"] === "1";

  while (!stopping) {
    try {
      const report = await drainOnce(sql, cfg);
      const did =
        report.jobsClaimed +
          report.messagesClaimed +
          report.commandsClaimed +
          report.emailClaimed +
          report.webhooksClaimed +
          report.tenantsPurged +
          report.previewsPurged +
          report.reclaimed.commands +
          report.reclaimed.runs +
          report.reclaimed.messages +
          report.reclaimed.email +
          report.reclaimed.webhook +
          report.failures >
        0;
      if (did || once) console.log(`[clove-erp] ${JSON.stringify(report)}`);
      // A stage that failed was caught so the other organisations could carry on,
      // not so the pass could pass: a one-shot run still fails, as a throw does.
      // Which stage, and for which organisation, is already in the log above.
      if (once && report.failures > 0) {
        console.error(`[clove-erp] pass finished with ${report.failures} failed stage(s)`);
        await sql.end({ timeout: 10 });
        process.exit(1);
      }
    } catch (err) {
      // A pass that throws is this process failing, not the work failing —
      // anything claimed keeps its lease and is reclaimed by the database.
      console.error(`[clove-erp] pass failed: ${(err as Error).message}`);
      if (once) {
        await sql.end({ timeout: 10 });
        process.exit(1);
      }
    }
    if (once) break;
    await new Promise((r) => setTimeout(r, cfg.pollMs));
  }

  await sql.end({ timeout: 10 });
  console.log("[clove-erp] stopped cleanly");
}

main().catch((err) => {
  console.error(`[clove-erp] refusing to start: ${(err as Error).message}`);
  process.exit(1);
});
