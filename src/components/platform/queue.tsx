import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Timer } from "lucide-react";
import { useState } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";
import type { DrainResult, JobHandler } from "../../lib/platform";

/**
 * Jobs, across every organisation.
 *
 * The database can run any handler whose implementation is an erp function,
 * which is all three of the ones the worker implements. It cannot make an
 * outbound call, so a handler that needs one is reported by name rather than
 * skipped — a pass that quietly omitted work would be worse than a failure.
 */
export function Queue() {
  const queryClient = useQueryClient();
  const [last, setLast] = useState<DrainResult | null>(null);
  const [swept, setSwept] = useState<string | null>(null);

  const handlers = useQuery({
    queryKey: ["erp_job_handlers"],
    queryFn: () => callErp<JobHandler[]>("erp_job_handlers"),
  });

  const drain = useMutation({
    mutationFn: () => callErp<DrainResult>("erp_platform_run_due_jobs", { p_batch_size: 25 }),
    onSuccess: (r) => {
      setLast(r);
      void queryClient.invalidateQueries();
    },
  });

  const sweep = useMutation({
    mutationFn: () =>
      callErp<{ purged: number }[]>("erp_platform_purge_due_tenants", { p_grace_days: 7 }),
    onSuccess: (r) => {
      setSwept(`${Array.isArray(r) ? r.length : 0} organisation(s) purged`);
      void queryClient.invalidateQueries();
    },
  });

  return (
    <div className="flex flex-col gap-5">
      <Card
        title="Run the due work"
        icon={<Timer className="size-4 text-primary" />}
        description="Claims every job that is due across every organisation, runs the ones this database can, and reports the rest by name."
      >
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={() => drain.mutate()}
            disabled={drain.isPending}
            className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
          >
            {drain.isPending ? "Running…" : "Run due jobs"}
          </button>
          <button
            type="button"
            onClick={() => sweep.mutate()}
            disabled={sweep.isPending}
            className={`${TOUCH} rounded-md border border-input px-4 text-sm font-medium hover:bg-muted disabled:opacity-60`}
          >
            {sweep.isPending ? "Sweeping…" : "Purge organisations past their grace period"}
          </button>
        </div>

        {drain.error ? (
          <div className="mt-3">
            <Fail error={drain.error} />
          </div>
        ) : null}
        {sweep.error ? (
          <div className="mt-3">
            <Fail error={sweep.error} />
          </div>
        ) : null}
        {swept ? <p className="mt-3 text-sm text-muted-foreground">{swept}</p> : null}

        {last ? (
          <div className="mt-4">
            <div className="flex flex-wrap gap-2">
              <Pill tone="muted">{last.claimed} claimed</Pill>
              <Pill tone={last.succeeded > 0 ? "ok" : "muted"}>{last.succeeded} succeeded</Pill>
              <Pill tone={last.failed > 0 ? "bad" : "muted"}>{last.failed} failed</Pill>
              <Pill tone={last.needs_worker > 0 ? "warn" : "muted"}>
                {last.needs_worker} need the worker
              </Pill>
            </div>
            {last.claimed === 0 ? (
              <p className="mt-3 text-sm text-muted-foreground">
                Nothing was due. That is a real answer, not an empty one.
              </p>
            ) : (
              <ul className="mt-3 flex flex-col gap-1">
                {last.organisations.flatMap((o) =>
                  o.runs.map((r, i) => (
                    <li key={`${o.organisation}-${i}`} className="text-xs text-muted-foreground">
                      <span className="font-mono">{o.organisation}</span> · {r.job} ·{" "}
                      <span className={r.outcome === "failed" ? "text-destructive" : ""}>
                        {r.outcome}
                      </span>
                      {r.error ? ` — ${r.error}` : ""}
                    </li>
                  )),
                )}
              </ul>
            )}
          </div>
        ) : null}
      </Card>

      <Card
        title="Handlers"
        description="What a job can be pointed at. Until these were seeded, erp.job could not hold a row and no job could exist."
      >
        {handlers.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : handlers.error ? (
          <Fail error={handlers.error} />
        ) : (
          <Table columns={["Handler", "Runs where", "What it does"]}>
            {(handlers.data ?? []).map((h) => (
              <tr key={h.code} className="border-b border-border/60 align-top last:border-0">
                <td className="py-3 pr-4 font-mono text-xs">{h.code}</td>
                <td className="py-3 pr-4">
                  <Pill tone={h.runs_in_database ? "ok" : "warn"}>
                    {h.runs_in_database ? "This database" : "Worker only"}
                  </Pill>
                </td>
                <td className="py-3 pr-0 text-xs text-muted-foreground">{h.description}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}
