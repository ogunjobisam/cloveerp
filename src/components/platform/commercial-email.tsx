import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { TOUCH } from "../erp/page";
import { Pill } from "../erp/panel";
import { callErp } from "../../lib/erp";
import {
  describeSend,
  latestSends,
  recipientsSentence,
  type CommercialEmailState,
  type CommercialSend,
} from "../../lib/commercial-sends";
import { Card, Fail, INPUT } from "./kit";

/**
 * An issued order form or invoice on its way to the customer.
 *
 * Issuing sends it (20260914097200); these say who it went to and what became
 * of each send, and let an operator send it again. They read one door,
 * public.erp_platform_commercial_emails(), for a quote or for a contract, so
 * the quote builder and the contract page show the same sends. The words are
 * src/lib/commercial-sends.ts, where they are tested.
 */

const BUTTON = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium disabled:opacity-60`;

const KEY = "erp_platform_commercial_emails";

type Kind = "order_form" | "contract_invoice";

export function useCommercialEmails(target: { quoteDocumentId: string } | { contractId: string }) {
  const args = {
    p_quote_document_id: "quoteDocumentId" in target ? target.quoteDocumentId : null,
    p_contract_id: "contractId" in target ? target.contractId : null,
  };
  return useQuery({
    queryKey: [KEY, args],
    queryFn: () => callErp<CommercialEmailState>(KEY, args),
  });
}

function useSendAgain() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (args: { kind: Kind; documentId: string }) =>
      callErp<{ queued: number }>("erp_platform_send_commercial_email", {
        p_kind: args.kind,
        p_document_id: args.documentId,
      }),
    onSettled: () => void queryClient.invalidateQueries({ queryKey: [KEY] }),
  });
}

/** The latest send of one document, a line per recipient, and the sends before it. */
export function SendLines({ sends, documentId }: { sends: CommercialSend[]; documentId: string }) {
  const latest = latestSends(sends, documentId);
  if (latest.length === 0)
    return <span className="text-xs text-muted-foreground">Not emailed</span>;
  const earlier = sends.filter(
    (s) => s.document_id === documentId && s.send_number < (latest[0]?.send_number ?? 0),
  ).length;
  return (
    <ul className="flex flex-col gap-1">
      {latest.map((s) => {
        const d = describeSend(s);
        return (
          <li key={s.id} className="flex flex-wrap items-center gap-1.5 text-xs">
            <Pill tone={d.tone}>{s.status}</Pill>
            <span className={d.tone === "bad" ? "text-destructive" : "text-muted-foreground"}>
              {d.text}
            </span>
          </li>
        );
      })}
      {earlier > 0 ? (
        <li className="text-xs text-muted-foreground">
          {earlier} earlier {earlier === 1 ? "send" : "sends"}
        </li>
      ) : null}
    </ul>
  );
}

/** Send again, for one document. */
export function SendAgain({
  kind,
  documentId,
  disabled,
  sentBefore,
}: {
  kind: Kind;
  documentId: string;
  disabled?: boolean;
  sentBefore: boolean;
}) {
  const send = useSendAgain();
  return (
    <span className="inline-flex flex-col items-start gap-1">
      <button
        type="button"
        className={SECONDARY}
        disabled={disabled || send.isPending}
        onClick={() => send.mutate({ kind, documentId })}
      >
        {send.isPending ? "Sending…" : sentBefore ? "Send again" : "Send it"}
      </button>
      {send.error ? <Fail error={send.error} /> : null}
    </span>
  );
}

/**
 * The order form's email, in the quote builder: who it goes to, the customer
 * email to set when there is none, and each send once it is issued.
 */
export function QuoteEmail({
  documentId,
  issued,
  mayWrite,
}: {
  documentId: string;
  issued: boolean;
  mayWrite: boolean;
}) {
  const state = useCommercialEmails({ quoteDocumentId: documentId });
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const setContact = useMutation({
    mutationFn: () =>
      callErp("erp_set_quote_contact", {
        p_document_id: documentId,
        p_name: name.trim() || null,
        p_email: email.trim(),
      }),
    onSuccess: () => {
      setEditing(false);
      void queryClient.invalidateQueries({ queryKey: [KEY] });
    },
  });

  if (state.isPending) return <p className="text-xs text-muted-foreground">Loading…</p>;
  if (state.error) return <Fail error={state.error} />;
  const s = state.data;
  const nobody = s.recipients.length === 0;
  const sentBefore = s.sends.length > 0;

  return (
    <div className="flex flex-col gap-2">
      <p className={`text-sm ${nobody && !s.demonstration ? "font-medium text-destructive" : ""}`}>
        {recipientsSentence("order_form", s.recipients, s.demonstration)}
      </p>
      {!issued && !nobody && !s.demonstration ? (
        <p className="text-xs text-muted-foreground">
          The order form is emailed the moment the quote is issued.
        </p>
      ) : null}
      {issued ? <SendLines sends={s.sends} documentId={documentId} /> : null}
      {mayWrite && !s.demonstration ? (
        <div className="flex flex-wrap items-start gap-2">
          {issued && !nobody ? (
            <SendAgain kind="order_form" documentId={documentId} sentBefore={sentBefore} />
          ) : null}
          {!editing ? (
            <button
              type="button"
              className={nobody ? BUTTON : SECONDARY}
              onClick={() => setEditing(true)}
            >
              {nobody ? "Add the customer's email" : "Change the customer email"}
            </button>
          ) : null}
        </div>
      ) : null}
      {editing ? (
        <form
          className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
          onSubmit={(e) => {
            e.preventDefault();
            if (email.trim()) setContact.mutate();
          }}
        >
          <div className="grid gap-2 sm:grid-cols-2">
            <label className="block text-xs font-medium">
              Customer email
              <input
                className={INPUT}
                type="email"
                required
                value={email}
                placeholder="dana@okaforfoods.co.uk"
                onChange={(e) => setEmail(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              Name
              <input
                className={INPUT}
                value={name}
                placeholder="Dana Okafor"
                onChange={(e) => setName(e.target.value)}
              />
            </label>
          </div>
          {setContact.error ? <Fail error={setContact.error} /> : null}
          <div className="flex flex-wrap gap-2">
            <button type="submit" className={BUTTON} disabled={setContact.isPending}>
              {setContact.isPending ? "Saving…" : "Save the customer email"}
            </button>
            <button type="button" className={SECONDARY} onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
          {issued ? (
            <p className="text-xs text-muted-foreground">
              Saving does not send it. Send it once the address is right.
            </p>
          ) : null}
        </form>
      ) : null}
    </div>
  );
}

/**
 * Where a contract's invoices are emailed: its billing contact, or the
 * organisation's administrators. Everybody reads it; only an owner changes it.
 */
export function BillingContact({ contractId, isOwner }: { contractId: string; isOwner: boolean }) {
  const state = useCommercialEmails({ contractId });
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [email, setEmail] = useState("");
  const [name, setName] = useState("");
  const save = useMutation({
    mutationFn: (args: { email: string | null; name: string | null }) =>
      callErp("erp_platform_set_billing_contact", {
        p_contract_id: contractId,
        p_email: args.email,
        p_name: args.name,
      }),
    onSuccess: () => {
      setEditing(false);
      void queryClient.invalidateQueries({ queryKey: [KEY] });
    },
  });

  return (
    <Card
      title="Where invoices are emailed"
      description="Each invoice is emailed when it is issued: to the billing contact when there is one, otherwise to the customer organisation's administrators. Platform support and staff are never sent a customer's invoice."
    >
      {state.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : state.error ? (
        <Fail error={state.error} />
      ) : (
        <div className="flex flex-col gap-3">
          <p className="text-sm">
            {recipientsSentence(
              "contract_invoice",
              state.data.recipients,
              state.data.demonstration,
            )}
          </p>
          {isOwner && !editing ? (
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                className={SECONDARY}
                onClick={() => {
                  setEmail(state.data.billing_email ?? "");
                  setName(state.data.billing_name ?? "");
                  setEditing(true);
                }}
              >
                {state.data.billing_email ? "Change the billing contact" : "Set a billing contact"}
              </button>
              {state.data.billing_email ? (
                <button
                  type="button"
                  className={SECONDARY}
                  disabled={save.isPending}
                  onClick={() => save.mutate({ email: null, name: null })}
                >
                  Send to the administrators instead
                </button>
              ) : null}
            </div>
          ) : null}
          {editing ? (
            <form
              className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
              onSubmit={(e) => {
                e.preventDefault();
                if (email.trim()) save.mutate({ email: email.trim(), name: name.trim() || null });
              }}
            >
              <div className="grid gap-2 sm:grid-cols-2">
                <label className="block text-xs font-medium">
                  Billing email
                  <input
                    className={INPUT}
                    type="email"
                    required
                    value={email}
                    placeholder="accounts@okaforfoods.co.uk"
                    onChange={(e) => setEmail(e.target.value)}
                  />
                </label>
                <label className="block text-xs font-medium">
                  Name
                  <input
                    className={INPUT}
                    value={name}
                    placeholder="Accounts payable"
                    onChange={(e) => setName(e.target.value)}
                  />
                </label>
              </div>
              <div className="flex flex-wrap gap-2">
                <button type="submit" className={BUTTON} disabled={save.isPending}>
                  {save.isPending ? "Saving…" : "Save the billing contact"}
                </button>
                <button type="button" className={SECONDARY} onClick={() => setEditing(false)}>
                  Cancel
                </button>
              </div>
            </form>
          ) : null}
          {save.error ? <Fail error={save.error} /> : null}
        </div>
      )}
    </Card>
  );
}
