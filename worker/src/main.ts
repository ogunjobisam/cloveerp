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
  const sql = connect(cfg.databaseUrl);

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

  console.log(
    `[clove-erp] ${cfg.workerName} serving ${cfg.bindings.length} tenant(s), ` +
      `systems: ${cfg.systems.join(", ") || "(none)"}`,
  );

  while (!stopping) {
    try {
      const report = await drainOnce(sql, cfg);
      const did =
        report.jobsClaimed + report.messagesClaimed + report.commandsClaimed +
          report.tenantsPurged >
        0;
      if (did) console.log(`[clove-erp] ${JSON.stringify(report)}`);
    } catch (err) {
      // A pass that throws is this process failing, not the work failing —
      // anything claimed keeps its lease and is reclaimed by the database.
      console.error(`[clove-erp] pass failed: ${(err as Error).message}`);
    }
    await new Promise((r) => setTimeout(r, cfg.pollMs));
  }

  await sql.end({ timeout: 10 });
  console.log("[clove-erp] stopped cleanly");
}

main().catch((err) => {
  console.error(`[clove-erp] refusing to start: ${(err as Error).message}`);
  process.exit(1);
});
