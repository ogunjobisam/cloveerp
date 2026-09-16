import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Timer } from "lucide-react";
import { useState } from "react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { Card, Fail } from "./kit";
import type { DrainResult, JobHandler, PlatformRole } from "../../lib/platform";
import type { EmailDeliveryRead } from "../../lib/platform-today";
import { whenText } from "../../lib/commercial-sends";
import { purgeSweepSummary, readPurgeSweep } from "../../lib/purge-sweep";

/**
 * Jobs, across every organisation.
 *
 * The database can run any handler whose implementation is an erp function,
 * which is all three of the ones the worker implements. It cannot make an
 * outbound call, so a handler that needs one is reported by name rather than
 * skipped — a pass that quietly omitted work would be worse than a failure.
 */
export function Queue({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const mayWrite = role === "owner" || role === "operator";
  const [last, setLast] = useState<DrainResult | null>(null);

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

  /** The door answers with one object — a count and the organisations — never a list. */
  const sweep = useMutation({
    mutationFn: async () =>
      readPurgeSweep(await callErp<unknown>("erp_platform_purge_due_tenants", { p_grace_days: 7 })),
    onSuccess: () => {
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
        {sweep.isSuccess ? (
          <p role="status" className="mt-3 text-sm text-muted-foreground">
            {sweep.data
              ? purgeSweepSummary(sweep.data)
              : "The sweep ran, but its answer could not be read. Check the organisations list to see what was purged."}
          </p>
        ) : null}

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

      <EmailDelivery mayWrite={mayWrite} />

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

/**
 * What the provider said became of the email this deployment sent.
 *
 * Every message is recorded as sent when the provider takes it; this is the
 * answer that comes afterwards. A bounce is a fact — nothing is retried for it
 * — and a complaint stops the address being written to at all, which is the
 * one thing here a person has to be able to undo.
 */
function EmailDelivery({ mayWrite }: { mayWrite: boolean }) {
  const queryClient = useQueryClient();
  const delivery = useQuery({
    queryKey: ["erp_platform_email_delivery"],
    queryFn: () => callErp<EmailDeliveryRead>("erp_platform_email_delivery", { p_limit: 50 }),
  });
  const clear = useMutation({
    mutationFn: (address: string) =>
      callErp("erp_platform_clear_email_suppression", { p_address: address, p_note: null }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_email_delivery"] });
    },
  });

  const counts = Object.entries(delivery.data?.recent ?? {});
  return (
    <Card
      title="Email delivery"
      description="What the provider said about the messages this deployment sent, in the last thirty days. A bounce is never retried; a complaint stops the address until somebody here clears it."
    >
      {delivery.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : delivery.error ? (
        <Fail error={delivery.error} />
      ) : (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap gap-2">
            {counts.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                The provider has said nothing yet. Until the webhook is configured in Resend, every
                message stays at “sent”.
              </p>
            ) : (
              counts.map(([state, n]) => (
                <Pill
                  key={state}
                  tone={
                    state === "bounced" || state === "complained"
                      ? "bad"
                      : state === "delayed"
                        ? "warn"
                        : "ok"
                  }
                >
                  {n} {state}
                </Pill>
              ))
            )}
          </div>

          {(delivery.data?.trouble ?? []).length > 0 ? (
            <Table columns={["What happened", "Address", "When", "Organisation", "Why"]}>
              {(delivery.data?.trouble ?? []).map((t) => (
                <tr key={t.event_id} className="border-b border-border/60 align-top last:border-0">
                  <td className="py-2 pr-4">
                    <Pill tone="bad">{t.state}</Pill>
                  </td>
                  <td className="py-2 pr-4 text-xs">{t.to_address ?? "—"}</td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">
                    {whenText(t.occurred_at)}
                  </td>
                  <td className="py-2 pr-4 font-mono text-xs">{t.tenant_code ?? "—"}</td>
                  <td className="py-2 pr-0 text-xs text-muted-foreground">
                    {t.detail ?? (t.matched === "nothing" ? "about a message we did not send" : "")}
                  </td>
                </tr>
              ))}
            </Table>
          ) : null}

          <div>
            <h3 className="text-sm font-semibold">Addresses nothing is sent to</h3>
            {(delivery.data?.suppressed ?? []).length === 0 ? (
              <p className="mt-1 text-sm text-muted-foreground">
                None. Every address this deployment writes to is still being written to.
              </p>
            ) : (
              <ul className="mt-2 flex flex-col gap-2">
                {(delivery.data?.suppressed ?? []).map((s) => (
                  <li key={s.address} className="flex flex-wrap items-center gap-2 text-xs">
                    <span className="font-medium">{s.address}</span>
                    <Pill tone="bad">{s.reason.replace(/_/g, " ")}</Pill>
                    <span className="text-muted-foreground">
                      since {whenText(s.suppressed_at)}
                      {s.note ? ` · ${s.note}` : ""}
                    </span>
                    {mayWrite ? (
                      <button
                        type="button"
                        className={`${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium disabled:opacity-60`}
                        disabled={clear.isPending}
                        onClick={() => clear.mutate(s.address)}
                      >
                        Write to it again
                      </button>
                    ) : null}
                  </li>
                ))}
              </ul>
            )}
            {clear.error ? (
              <div className="mt-2">
                <Fail error={clear.error} />
              </div>
            ) : null}
          </div>
        </div>
      )}
    </Card>
  );
}
