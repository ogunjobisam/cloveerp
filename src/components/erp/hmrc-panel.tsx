import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";

import { callErp, callFunction, hasPermission } from "../../lib/erp";
import { clientFacts } from "../../lib/hmrc-device";
import { DECLARATION } from "../../lib/hmrc-mtd";
import { useT } from "../../lib/i18n";
import type { VatObligation } from "../../lib/vat-returns";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/** Shaped by public.erp_hmrc_status() (20261013070000). */
type HmrcCompany = {
  entity_id: string;
  company: string;
  vrn: string | null;
  connection: {
    environment: "sandbox" | "production";
    connected_at: string;
    connected_by: string | null;
  } | null;
  obligations: {
    period_key: string;
    starts_on: string;
    ends_on: string;
    due_on: string;
    status: "O" | "F";
    received_on: string | null;
  }[];
  submissions: {
    document_id: string;
    document_number: string | null;
    outcome: "accepted" | "already_held";
    processing_date: string | null;
    form_bundle_number: string | null;
    payment_indicator: string | null;
    environment: "sandbox" | "production";
    declared_at: string;
    declared_by: string | null;
  }[];
};

const READS = ["erp_hmrc_status", "erp_vat_obligations"];

/**
 * Making Tax Digital for VAT on the VAT returns screen (20261013070000): each
 * company connected to HMRC with its own HMRC account, the obligations HMRC
 * holds, and each finalised return submitted with HMRC's declaration agreed.
 * HMRC is called by the hmrc Edge Function; this page never holds a token.
 * Every press is the database's to refuse: connecting, reading and submitting
 * need finance.close_period, as finalising does.
 */
export function HmrcPanel({ finalised }: { finalised: VatObligation[] }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const may = hasPermission(session, "finance.close_period");
  const client = useQueryClient();
  const status = useQuery({
    queryKey: ["erp_hmrc_status"],
    queryFn: () => callErp<HmrcCompany[]>("erp_hmrc_status", {}),
  });
  const reread = () => Promise.all(READS.map((k) => client.invalidateQueries({ queryKey: [k] })));

  const connect = useMutation({
    mutationFn: (entityId: string) =>
      callFunction<{ url: string }>("hmrc", {
        action: "connect",
        entity_id: entityId,
        return_host: window.location.host,
        client: clientFacts(),
      }),
    onSuccess: (r) => {
      window.location.assign(r.url);
    },
  });
  const obligations = useMutation({
    mutationFn: (entityId: string) =>
      callFunction("hmrc", { action: "obligations", entity_id: entityId, client: clientFacts() }),
    onSuccess: reread,
  });

  // HMRC's answer, relayed back here by /hmrc/callback: traded for tokens
  // once, and the code taken out of the address so a reload does not replay it.
  const exchange = useMutation({
    mutationFn: (args: { code: string; state: string }) =>
      callFunction("hmrc", { action: "exchange", ...args, client: clientFacts() }),
    onSuccess: reread,
  });
  const [refused, setRefused] = useState<string | null>(null);
  const once = useRef(false);
  useEffect(() => {
    if (once.current) return;
    once.current = true;
    const q = new URLSearchParams(window.location.search);
    const code = q.get("hmrc_code");
    const state = q.get("hmrc_state");
    const error = q.get("hmrc_error");
    if (!state) return;
    window.history.replaceState(null, "", window.location.pathname);
    if (error) setRefused(error);
    else if (code) exchange.mutate({ code, state });
  }, [exchange]);

  const rows = status.data ?? [];
  if (status.isPending) return null;

  return (
    <section
      className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5"
      data-hmrc
    >
      <h2 className="text-sm font-semibold">{ui("Filed with HMRC")}</h2>
      <p className="mb-3 max-w-prose text-xs text-muted-foreground">
        {ui(
          "Connect each company to HMRC once, with the business's own HMRC sign-in. A finalised return is then submitted from here, against the period HMRC holds for the same dates, and HMRC's receipt is kept with it.",
        )}
      </p>
      <ErrorNote error={status.error} />
      <ErrorNote error={connect.error} />
      <ErrorNote error={obligations.error} />
      <ErrorNote error={exchange.error} />
      {refused ? (
        <p role="alert" className="mb-3 text-sm text-destructive">
          {ui("HMRC did not connect the company:")} {refused}
        </p>
      ) : null}
      {exchange.isPending ? (
        <p role="status" className="mb-3 text-sm text-muted-foreground">
          {ui("Finishing the connection to HMRC…")}
        </p>
      ) : null}

      <div className="flex flex-col gap-4">
        {rows.map((c) => (
          <div
            key={c.entity_id}
            className="flex min-w-0 flex-col gap-2 border-t border-border/60 pt-3 first:border-0 first:pt-0"
          >
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-sm font-medium">{c.company}</span>
              {c.vrn ? (
                <span className="text-xs text-muted-foreground tabular-nums">VRN {c.vrn}</span>
              ) : null}
              {c.connection ? (
                <Pill tone="ok">
                  {c.connection.environment === "production"
                    ? ui("Connected to HMRC")
                    : ui("Connected to HMRC's sandbox")}
                </Pill>
              ) : (
                <Pill tone="muted">{ui("Not connected")}</Pill>
              )}
            </div>
            {may ? (
              <div className="flex flex-wrap gap-2">
                {!c.connection ? (
                  <ActionButton
                    busy={connect.isPending && connect.variables === c.entity_id}
                    onClick={() => connect.mutate(c.entity_id)}
                  >
                    {ui("Connect to HMRC")}
                  </ActionButton>
                ) : (
                  <>
                    <ActionButton
                      variant="secondary"
                      busy={obligations.isPending && obligations.variables === c.entity_id}
                      onClick={() => obligations.mutate(c.entity_id)}
                    >
                      {ui("Read obligations from HMRC")}
                    </ActionButton>
                    <ActionDialog
                      trigger={<ActionButton variant="secondary">{ui("Disconnect")}</ActionButton>}
                      title="Disconnect from HMRC"
                      description="The company's HMRC tokens are forgotten and nothing more is read or filed for it until it is connected again."
                      permission="finance.close_period"
                      fn="erp_hmrc_disconnect"
                      fields={[
                        {
                          kind: "text",
                          name: "p_reason",
                          label: "Why it is disconnected",
                          required: true,
                          placeholder: "The business moved to an agent",
                          hint: "Kept with the change for the next person.",
                        },
                      ]}
                      prefill={{ p_entity_id: c.entity_id }}
                      context={c.company}
                      invalidates={READS}
                      submitLabel="Disconnect"
                    />
                  </>
                )}
              </div>
            ) : null}
            {c.obligations.length > 0 ? (
              <Table columns={[ui("HMRC period"), ui("Due"), ui("State"), ui("Received")]}>
                {c.obligations.map((o) => (
                  <tr key={o.period_key} className="border-b border-border/60 last:border-0">
                    <td className="whitespace-nowrap py-1.5 pr-4 text-sm tabular-nums">
                      {o.starts_on} – {o.ends_on}
                    </td>
                    <td className="whitespace-nowrap py-1.5 pr-4 text-sm tabular-nums">
                      {o.due_on}
                    </td>
                    <td className="py-1.5 pr-4">
                      <Pill tone={o.status === "F" ? "ok" : "warn"}>
                        {o.status === "F" ? ui("Fulfilled") : ui("Open")}
                      </Pill>
                    </td>
                    <td className="whitespace-nowrap py-1.5 pr-4 text-sm tabular-nums">
                      {o.received_on ?? "—"}
                    </td>
                  </tr>
                ))}
              </Table>
            ) : null}
            {finalised
              .filter((r) => r.entity_id === c.entity_id && r.return_document_id)
              .map((r) => (
                <SubmitRow
                  key={r.return_document_id}
                  row={r}
                  connected={c.connection !== null}
                  may={may}
                  submitted={
                    c.submissions.find((s) => s.document_id === r.return_document_id) ?? null
                  }
                  onDone={reread}
                />
              ))}
          </div>
        ))}
      </div>
    </section>
  );
}

function SubmitRow({
  row,
  connected,
  may,
  submitted,
  onDone,
}: {
  row: VatObligation;
  connected: boolean;
  may: boolean;
  submitted: HmrcCompany["submissions"][number] | null;
  onDone: () => Promise<unknown>;
}) {
  const { ui } = useT();
  const [open, setOpen] = useState(false);
  const [agreed, setAgreed] = useState(false);
  const submit = useMutation({
    mutationFn: () =>
      callFunction("hmrc", {
        action: "submit",
        document_id: row.return_document_id,
        declaration: agreed,
        client: clientFacts(),
      }),
    onSuccess: async () => {
      setOpen(false);
      await onDone();
    },
  });

  return (
    <div
      className="flex min-w-0 flex-col gap-2 rounded-lg border border-border px-3 py-2"
      data-hmrc-return={row.return_number ?? ""}
    >
      <p className="text-sm">
        <span className="font-medium">{row.return_number}</span>
        <span className="ml-2 text-muted-foreground tabular-nums">
          {row.period_start} – {row.period_end}
        </span>
      </p>
      {submitted ? (
        <p className="text-xs text-muted-foreground">
          {submitted.outcome === "accepted"
            ? `${ui("Submitted to HMRC")} ${submitted.processing_date ?? ""} · ${ui("Form bundle")} ${submitted.form_bundle_number ?? ""}${submitted.payment_indicator ? ` · ${submitted.payment_indicator}` : ""}`
            : ui("HMRC already held a return for this period.")}
          {submitted.declared_by ? ` · ${ui("Declared by")} ${submitted.declared_by}` : ""}
        </p>
      ) : !connected ? (
        <p className="text-xs text-muted-foreground">
          {ui("Connect the company to HMRC to submit this return.")}
        </p>
      ) : may && !open ? (
        <div>
          <ActionButton onClick={() => setOpen(true)}>{ui("Submit to HMRC")}</ActionButton>
        </div>
      ) : may ? (
        <div className="flex max-w-prose flex-col gap-2">
          <p className="text-sm">{ui(DECLARATION)}</p>
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.target.checked)} />
            <span>{ui("I agree, and this return is true and complete.")}</span>
          </label>
          <div className="flex flex-wrap gap-2">
            <ActionButton
              busy={submit.isPending}
              disabled={!agreed}
              onClick={() => submit.mutate()}
            >
              {ui("Submit to HMRC")}
            </ActionButton>
            <ActionButton variant="secondary" onClick={() => setOpen(false)}>
              {ui("Not now")}
            </ActionButton>
          </div>
          <ErrorNote error={submit.error} />
        </div>
      ) : null}
    </div>
  );
}
