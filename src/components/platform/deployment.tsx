import { useQuery } from "@tanstack/react-query";
import { HardDrive } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";
import type { DeploymentState } from "../../lib/platform";

/**
 * What is deployed, against what the repository holds.
 *
 * The repository half is resolved at build time: import.meta.glob is given
 * `{ eager: false }` so only the keys are collected — the filenames — and not
 * one line of SQL is bundled into the app.
 *
 * A database cannot see the repository it was built from, so it reports counts
 * and the migrations it has, and the comparison happens here.
 */
const REPO_MIGRATIONS: string[] = Object.keys(
  import.meta.glob("/supabase/migrations/*.sql", { eager: false }),
)
  .map((p) => p.split("/").pop() ?? p)
  .map((f) => f.replace(/\.sql$/, ""))
  .sort();

/** Supabase records a migration by its leading timestamp, not its whole name. */
const versionOf = (name: string) => name.match(/^(\d+)/)?.[1] ?? name;

export function Deployment() {
  const state = useQuery({
    queryKey: ["erp_platform_deployment_state"],
    queryFn: () => callErp<DeploymentState>("erp_platform_deployment_state"),
  });

  const d = state.data;
  const appliedVersions = new Set((d?.migrations ?? []).map((m) => m.version));
  const repoVersions = REPO_MIGRATIONS.map((n) => ({ name: n, version: versionOf(n) }));

  const notApplied = repoVersions.filter((r) => !appliedVersions.has(r.version));
  const notInRepo = (d?.migrations ?? []).filter(
    (m) => !repoVersions.some((r) => r.version === m.version),
  );

  return (
    <div className="flex flex-col gap-5">
      <Card
        title="Migrations"
        icon={<HardDrive className="size-4 text-primary" />}
        description={`This build carries ${REPO_MIGRATIONS.length} migration files. Compared against what the database says it has applied.`}
      >
        {state.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : state.error ? (
          <Fail error={state.error} />
        ) : !d?.migrations_known ? (
          <p className="text-sm text-muted-foreground">
            This database has no migration ledger — it was built by replaying the files directly, as
            CI does, rather than through the Supabase CLI. The counts below still apply; the list of
            applied versions does not exist to compare against.
          </p>
        ) : (
          <div className="flex flex-col gap-4">
            <div className="flex flex-wrap gap-2">
              <Pill tone="muted">{d.migrations.length} applied</Pill>
              <Pill tone={notApplied.length === 0 ? "ok" : "warn"}>
                {notApplied.length} in this build, not applied
              </Pill>
              <Pill tone={notInRepo.length === 0 ? "ok" : "bad"}>
                {notInRepo.length} applied, not in this build
              </Pill>
            </div>

            {notApplied.length === 0 && notInRepo.length === 0 ? (
              <p className="text-sm text-muted-foreground">The database and this build agree.</p>
            ) : (
              <Table columns={["Migration", "State"]}>
                {[
                  ...notApplied.map((r) => ({ name: r.name, state: "not applied" as const })),
                  ...notInRepo.map((m) => ({
                    name: `${m.version} ${m.name ?? ""}`.trim(),
                    state: "not in this build" as const,
                  })),
                ].map((row) => (
                  <tr key={row.name} className="border-b border-border/60 last:border-0">
                    <td className="py-2 pr-4 font-mono text-xs">{row.name}</td>
                    <td className="py-2 pr-0">
                      <Pill tone={row.state === "not applied" ? "warn" : "bad"}>{row.state}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </div>
        )}
      </Card>

      <Card title="What this database holds">
        {d ? (
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {Object.entries(d.counts).map(([k, v]) => (
              <div key={k} className="rounded-lg border border-border p-3">
                <div className="font-display text-xl font-semibold">{v}</div>
                <div className="text-xs text-muted-foreground">{k.replace(/_/g, " ")}</div>
              </div>
            ))}
          </div>
        ) : null}
      </Card>

      <Card
        title="Registers"
        description="Every deliberate deviation this product records. A register that has gone empty is a governance failure that looks like nothing at all."
      >
        {d ? (
          <Table columns={["Register", "Rows"]}>
            {Object.entries(d.registers).map(([k, v]) => (
              <tr key={k} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 text-sm">{k.replace(/_/g, " ")}</td>
                <td className="py-2 pr-0 text-sm tabular-nums">{v}</td>
              </tr>
            ))}
          </Table>
        ) : null}
      </Card>
    </div>
  );
}
