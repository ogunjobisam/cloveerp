import { useMutation, useQuery } from "@tanstack/react-query";
import { Stethoscope } from "lucide-react";
import { Fragment, useState } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";
import type { CheckResult, DiagnosticCheck } from "../../lib/platform";

/**
 * The checks, and what they found.
 *
 * The list is not in this file. It is erp_meta.diagnostic_check, which is also
 * what erp.platform_assurance() runs and what erp.assert_diagnostics_registered()
 * polices — so a check added to the product appears here without a deployment,
 * and one added without being registered fails the build.
 *
 * The findings are the point. Until this, the assurance screen could say
 * isolation had failed and could not say which table, because every detail
 * report behind these assertions was reachable only from a SQL client.
 */
export function Diagnostics() {
  const [results, setResults] = useState<Record<string, CheckResult>>({});
  const [open, setOpen] = useState<string | null>(null);

  const checks = useQuery({
    queryKey: ["erp_platform_diagnostics"],
    queryFn: () => callErp<DiagnosticCheck[]>("erp_platform_diagnostics"),
  });

  const run = useMutation({
    mutationFn: (code: string) => callErp<CheckResult>("erp_platform_run_check", { p_code: code }),
    onSuccess: (r) => setResults((prev) => ({ ...prev, [r.code]: r })),
  });

  const runAll = useMutation({
    mutationFn: async () => {
      const list = (checks.data ?? []).filter((c) => c.scope === "platform");
      const out: Record<string, CheckResult> = {};
      // Sequentially: these read the whole catalogue, and firing thirty at once
      // buys nothing but contention.
      for (const c of list) {
        out[c.code] = await callErp<CheckResult>("erp_platform_run_check", {
          p_code: c.code,
        });
      }
      return out;
    },
    onSuccess: (out) => setResults((prev) => ({ ...prev, ...out })),
  });

  const rows = checks.data ?? [];
  const done = Object.values(results);
  const failed = done.filter((r) => !r.ok).length;

  return (
    <Card
      title="Diagnostics"
      icon={<Stethoscope className="size-4 text-primary" />}
      description="Every check this product runs against itself, and the report behind each failure."
      action={
        <button
          type="button"
          onClick={() => runAll.mutate()}
          disabled={runAll.isPending || rows.length === 0}
          className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
        >
          {runAll.isPending ? "Running…" : "Run all"}
        </button>
      }
    >
      {done.length > 0 ? (
        <p className="mb-4 text-sm text-muted-foreground">
          {done.length} run,{" "}
          <span className={failed > 0 ? "font-semibold text-destructive" : ""}>
            {failed} failing
          </span>
          .
        </p>
      ) : null}

      {runAll.error ? <Fail error={runAll.error} /> : null}
      {run.error ? <Fail error={run.error} /> : null}

      {checks.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : checks.error ? (
        <Fail error={checks.error} />
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          The register is empty, which is itself unexpected.
        </p>
      ) : (
        <Table columns={["Check", "Result", "", ""]}>
          {rows.map((c) => {
            const r = results[c.code];
            return (
              <Fragment key={c.code}>
                <tr className="border-b border-border/60 align-top last:border-0">
                  <td className="py-3 pr-4">
                    <div className="text-sm font-medium">{c.title}</div>
                    <div className="mt-0.5 text-xs text-muted-foreground">{c.blurb}</div>
                    <div className="mt-1 flex flex-wrap gap-1.5">
                      {c.scope === "tenant" ? (
                        <Pill tone="muted">needs an organisation</Pill>
                      ) : null}
                      {!c.runs_in_ci ? <Pill tone="warn">not in CI</Pill> : null}
                    </div>
                  </td>
                  <td className="py-3 pr-4">
                    {r ? (
                      <Pill tone={r.ok ? "ok" : "bad"}>{r.ok ? "Holds" : "Violated"}</Pill>
                    ) : (
                      <span className="text-xs text-muted-foreground">—</span>
                    )}
                  </td>
                  <td className="py-3 pr-4 text-xs text-muted-foreground">
                    {r?.ok ? r.summary : r ? `${r.findings.length} finding(s)` : ""}
                  </td>
                  <td className="py-3 pr-0 text-right">
                    <button
                      type="button"
                      onClick={() => run.mutate(c.code)}
                      disabled={run.isPending}
                      className={`${TOUCH} rounded-md border border-input px-3 text-xs font-medium hover:bg-muted disabled:opacity-60`}
                    >
                      Run
                    </button>
                    {r && !r.ok && r.findings.length > 0 ? (
                      <button
                        type="button"
                        onClick={() => setOpen(open === c.code ? null : c.code)}
                        className={`${TOUCH} ml-2 rounded-md border border-input px-3 text-xs font-medium hover:bg-muted`}
                      >
                        {open === c.code ? "Hide" : "Findings"}
                      </button>
                    ) : null}
                  </td>
                </tr>
                {open === c.code && r ? (
                  <tr className="border-b border-border/60">
                    <td colSpan={4} className="py-3">
                      <p className="mb-2 text-xs text-muted-foreground">{r.detail}</p>
                      <ul className="flex flex-col gap-1">
                        {r.findings.map((f, i) => (
                          <li
                            key={`${c.code}-f-${i}`}
                            className="rounded bg-muted px-2 py-1 font-mono text-xs"
                          >
                            {Object.entries(f)
                              .filter(([, v]) => v !== null && v !== "")
                              .map(([k, v]) => `${k}=${String(v)}`)
                              .join("  ")}
                          </li>
                        ))}
                      </ul>
                    </td>
                  </tr>
                ) : null}
              </Fragment>
            );
          })}
        </Table>
      )}
    </Card>
  );
}
