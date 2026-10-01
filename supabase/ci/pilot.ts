// The Xero + Unleashed pilot's files, through the import profiles and the
// doors, as the pilot organisation's administrator.
//
// Usage: bun supabase/ci/pilot.ts <auth-user-id> <as-at YYYY-MM-DD>
// Reads PSQL from the environment like run_checks.sh. Run by
// supabase/ci/pilot_rehearsal.sh, which builds the organisation first and
// proves the result after. The orchestration is src/lib/import/pilot/run.ts,
// typechecked and unit-tested with the application.
import { readFileSync } from "node:fs";
import { psqlDoor } from "../../src/lib/import/pilot/psql";
import { PILOT_FILES, runPilot, type PilotFile } from "../../src/lib/import/pilot/run";

const [authUser, asAt] = process.argv.slice(2);
if (!authUser || !asAt) {
  console.error("usage: bun supabase/ci/pilot.ts <auth-user-id> <as-at>");
  process.exit(2);
}

const psql = (process.env["PSQL"] ?? "psql -v ON_ERROR_STOP=1 --quiet --no-psqlrc")
  .split(/\s+/)
  .filter((p) => p !== "");

const files = Object.fromEntries(
  PILOT_FILES.map((f) => [
    f,
    readFileSync(new URL(`../../src/lib/import/fixtures/pilot/${f}.csv`, import.meta.url), "utf8"),
  ]),
) as Record<PilotFile, string>;

try {
  const steps = await runPilot(psqlDoor(psql, authUser), files, asAt);
  for (const s of steps) {
    const money =
      s.controlMinor === null ? "" : `  control ${s.controlMinor}, staged ${s.stagedMinor}`;
    const live = s.activated === null ? "" : `  ${s.activated} activated`;
    console.log(
      `── ${s.file.padEnd(22)} ${String(s.rows).padStart(3)} row(s)  batch ${s.batchId}${money}${live}`,
    );
    for (const w of s.warnings) console.log(`     warning: ${w}`);
  }
} catch (e) {
  console.error(`pilot stopped: ${e instanceof Error ? e.message : String(e)}`);
  process.exit(1);
}
