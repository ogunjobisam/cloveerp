import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";

import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { InvoiceIssue } from "../../components/erp/invoice-issue";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { decisionWords, type ApprovalDecision } from "../../lib/approval-decisions";
import { callErp } from "../../lib/erp";
import { prettifyField } from "../../lib/friendly";
import { useT } from "../../lib/i18n";
import {
  DELIVER_THIS_ORDER,
  DELIVERY_FROM_ORDER_FIELDS,
  deliveryFromOrderArgs,
  RECEIPT_FROM_ORDER_FIELDS,
  RECEIVE_THIS_ORDER,
  receiptFromOrderArgs,
} from "../../lib/modules";
import { formatMinor, minorUnitsOf, toMinor, type Currency } from "../../lib/money";
import { useCurrencies } from "../../components/erp/currencies";
import {
  useAvailableTransitions,
  type Transition,
} from "../../components/erp/available-transitions";
import { DocumentTransitions } from "../../components/erp/document-transitions";

/**
 * One document, whatever kind of document it is.
 *
 * There is no sales document screen and no procurement document screen,
 * because there is no sales document table and no procurement document table.
 * B7 put every type on one spine and configured thirteen of them onto it; a
 * screen per module would be the coded behaviour the product's thesis denies,
 * and would have to be written again for the fourteenth.
 *
 * Nothing here knows that a sales order goes draft → pending_approval →
 * confirmed. The transitions come from `erp_available_transitions`, which reads
 * the state machine the tenant promoted.
 */

export const Route = createFileRoute("/documents/$documentId")({
  head: () => ({
    meta: [
      { title: "Document — Clove ERP" },
      {
        name: "description",
        content:
          "A single Clove ERP document with its state machine, lines, postings and audit trail.",
      },
      { property: "og:title", content: "Document — Clove ERP" },
      {
        property: "og:description",
        content:
          "A single Clove ERP document with its state machine, lines, postings and audit trail.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Document />
    </Gate>
  ),
});

type Doc = {
  document_id: string;
  document_number: string;
  document_type: string;
  document_date: string;
  currency: string;
  party: string | null;
  their_reference: string | null;
  total_minor: number;
  state: string | null;
  state_name: string | null;
  is_committed: boolean;
};

type Line = {
  line_id: string;
  line_no: number;
  description: string | null;
  quantity: number;
  unit_price_minor: number;
  net_minor: number;
  item: string | null;
  /** What the supplier calls the product, stamped on the line when it was raised. */
  supplier_item_code: string | null;
};

type Lineage = {
  depth: number;
  direction: string;
  document_id: string;
  document_number: string;
  base_type: string;
  relation: string;
};

/** A contra journal raised against this document's posting. */
type Reversal = {
  journal_id: string;
  journal_number: string | null;
  posting_date: string;
  reason: string | null;
  reversed_at: string | null;
  reverses_journal_number: string | null;
};

type Payload = {
  document: Doc | null;
  lines: Line[];
  lineage: Lineage[];
  reversal: Reversal[];
  available_transitions: Transition[];
};

type DocType = { code: string; name: string; base_type_code: string };

/**
 * The organisation's own names for its document types, read as the New
 * document form reads them and under the same key. The page said
 * "purchase_order"; the organisation calls it a purchase order, or whatever it
 * renamed it to.
 */
function useDocumentTypeNames() {
  const { data } = useQuery({
    queryKey: ["erp_document_types", { p_base_type_code: "" }],
    queryFn: () => callErp<DocType[]>("erp_document_types", {}),
  });
  return {
    ofType: (code: string) => data?.find((t) => t.code === code)?.name ?? prettifyField(code),
    ofBase: (base: string) =>
      data?.find((t) => t.base_type_code === base)?.name ?? prettifyField(base),
  };
}

function Document() {
  const { documentId } = Route.useParams();

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_document", { p_document_id: documentId }],
    queryFn: () => callErp<Payload>("erp_document", { p_document_id: documentId }),
  });
  // The transitions are asked for on their own as well: the payload carries
  // them, but a guard can change under the reader's feet — a line added, an
  // approval decided — and this read is the one the buttons follow.
  const live = useAvailableTransitions(documentId);
  const typeNames = useDocumentTypeNames();

  const { currencies } = useCurrencies();

  if (isPending) return <p className="text-sm text-muted-foreground">Loading…</p>;
  if (error) {
    return (
      <div className="flex min-w-0 flex-col gap-6">
        <PageHeader title="Document" />
        <ErrorNote error={error} />
      </div>
    );
  }

  const doc = data?.document;
  if (!doc) {
    return (
      <div className="flex min-w-0 flex-col gap-6">
        <PageHeader title="Document">
          No document with that identifier is visible to this organisation.
        </PageHeader>
      </div>
    );
  }

  const minorUnits = minorUnitsOf(currencies, doc.currency);
  const money = (m: number) => formatMinor(m, doc.currency, minorUnits);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={doc.document_number}>
        {typeNames.ofType(doc.document_type)} · {doc.party ?? "no party"} · {doc.document_date}
      </PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <div className="flex flex-wrap items-center gap-3">
          <Pill tone={doc.is_committed ? "ok" : "muted"}>{doc.state_name ?? doc.state ?? "—"}</Pill>
          <span className="text-sm tabular-nums">{money(doc.total_minor)}</span>
          {doc.their_reference ? (
            <span className="text-xs text-muted-foreground">their ref {doc.their_reference}</span>
          ) : null}
        </div>

        <DocumentTransitions
          documentId={documentId}
          documentType={doc.document_type}
          transitions={live.data ?? data.available_transitions}
          committed={doc.is_committed}
        />

        {/* An order that can still be despatched is where its delivery comes
            from. Offered on the states erp.create_delivery_from_order accepts;
            the database refuses anything else by name. */}
        {doc.document_type === "sales_order" &&
        (doc.state === "confirmed" || doc.state === "picking") ? (
          <DeliverThisOrder
            documentId={documentId}
            context={`${doc.document_number} · ${doc.party ?? "no party"}`}
          />
        ) : null}

        {/* An order the supplier has been sent is where its goods receipt comes
            from. Offered on the states erp.create_receipt_from_order accepts;
            the database refuses anything else by name. */}
        {doc.document_type === "purchase_order" &&
        (doc.state === "sent" || doc.state === "partially_received") ? (
          <ReceiveThisOrder
            documentId={documentId}
            context={`${doc.document_number} · ${doc.party ?? "no party"}`}
          />
        ) : null}
      </section>

      {/* A sales invoice is issued here: its permanent number and the PDF the
          customer receives, through the numbered issue path. */}
      {doc.document_type === "sales_invoice" ? <InvoiceIssue documentId={documentId} /> : null}

      {/* What the supplier charged is a fact on their paperwork, not something
          to work out from our own rules, so it is typed in from their invoice.
          Offered on a purchase invoice before it is registered, which is when
          erp.state_supplier_tax accepts it. */}
      {doc.document_type === "purchase_invoice" && !doc.is_committed ? (
        <SupplierTax documentId={documentId} currency={doc.currency} minorUnits={minorUnits} />
      ) : null}

      {/* A credit note starts from the document that moved the goods, because
          that is the only place their cost is recorded. Offered once the
          despatch or the invoice has committed, which is when there is anything
          to reverse; erp.raise_customer_credit_note refuses anything else by
          name. */}
      {(doc.document_type === "delivery" || doc.document_type === "sales_invoice") &&
      doc.is_committed ? (
        <CreditCustomer
          documentId={documentId}
          context={`${doc.document_number} · ${doc.party ?? "no party"}`}
        />
      ) : null}

      {doc.document_type === "goods_receipt" && doc.is_committed ? (
        <CreditSupplier
          documentId={documentId}
          context={`${doc.document_number} · ${doc.party ?? "no party"}`}
        />
      ) : null}

      {/* A posted invoice cannot be edited and, where nothing is coming back,
          cannot be credited either: a credit note in this product is a goods
          return. Reversing the posting is what is left, and it is what an
          accounting system does — the opposite journal, on its own date, with
          both entries standing. Offered once the invoice has committed, which
          is when there is a posting to unmake; erp.reverse_document_posting
          refuses anything else by name. */}
      {(doc.document_type === "sales_invoice" || doc.document_type === "purchase_invoice") &&
      doc.is_committed ? (
        <ReversePosting
          documentId={documentId}
          context={`${doc.document_number} · ${doc.party ?? "no party"}`}
          reversal={data.reversal}
        />
      ) : null}

      <Lines
        documentId={documentId}
        lines={data.lines}
        committed={doc.is_committed}
        money={money}
        minorUnits={minorUnits}
        currency={doc.currency}
      />

      <ApprovalChain documentId={documentId} />

      <ApprovalDecisions documentId={documentId} />

      {data.lineage.length > 0 ? (
        <LineagePanel lineage={data.lineage} documentId={documentId} typeName={typeNames.ofBase} />
      ) : null}
    </div>
  );
}

/**
 * Create a delivery from the order on this page.
 *
 * The order is already chosen, so the form asks only for the lines, and it
 * arrives holding what is left to deliver on each. Created, the delivery opens
 * on its own page, where it is posted — or it is created and posted in one
 * press with Create and move on.
 */
function DeliverThisOrder({ documentId, context }: { documentId: string; context: string }) {
  const { ui } = useT();
  const navigate = useNavigate();

  return (
    <div className="mt-3 flex flex-wrap gap-2">
      <ActionDialog
        trigger={
          <ActionButton variant="secondary">{ui("Create a delivery from this order")}</ActionButton>
        }
        title="Create a delivery from this order"
        {...(DELIVER_THIS_ORDER.description ? { description: DELIVER_THIS_ORDER.description } : {})}
        permission="sales.despatch"
        fn="erp_create_delivery_from_order"
        fields={DELIVERY_FROM_ORDER_FIELDS}
        mapArgs={deliveryFromOrderArgs}
        prefill={{ p_order_id: documentId }}
        context={context}
        alsoSubmit={{ label: "Create and move on", args: { p_transition: "auto" } }}
        invalidates={[
          "erp_document",
          "erp_documents",
          "erp_deliverable_lines",
          "erp_available_transitions",
        ]}
        submitLabel="Create the delivery"
        onDone={(result) => {
          const made =
            typeof result === "object" && result !== null
              ? (result as Record<string, unknown>)["document_id"]
              : undefined;
          if (typeof made === "string")
            void navigate({ to: "/documents/$documentId", params: { documentId: made } });
        }}
      />
    </div>
  );
}

/**
 * Receive the goods against the order on this page.
 *
 * The order is already chosen, so the form asks only for the lines, and it
 * arrives holding what is left to receive on each, with a place and a batch
 * for each line. Created, the goods receipt opens on its own page, where it is
 * posted — or it is created and posted in one press with Create and move on,
 * which moves the order to partially received or received.
 */
function ReceiveThisOrder({ documentId, context }: { documentId: string; context: string }) {
  const { ui } = useT();
  const navigate = useNavigate();

  return (
    <div className="mt-3 flex flex-wrap gap-2">
      <ActionDialog
        trigger={<ActionButton variant="secondary">{ui("Receive this order")}</ActionButton>}
        title="Receive this order"
        {...(RECEIVE_THIS_ORDER.description ? { description: RECEIVE_THIS_ORDER.description } : {})}
        permission="procurement.receive"
        fn="erp_create_receipt_from_order"
        fields={RECEIPT_FROM_ORDER_FIELDS}
        mapArgs={receiptFromOrderArgs}
        prefill={{ p_order_id: documentId }}
        context={context}
        alsoSubmit={{ label: "Create and move on", args: { p_transition: "auto" } }}
        invalidates={[
          "erp_document",
          "erp_documents",
          "erp_receivable_lines",
          "erp_available_transitions",
          "erp_grni",
          "erp_goods_in",
        ]}
        submitLabel="Create the goods receipt"
        onDone={(result) => {
          const made =
            typeof result === "object" && result !== null
              ? (result as Record<string, unknown>)["document_id"]
              : undefined;
          if (typeof made === "string")
            void navigate({ to: "/documents/$documentId", params: { documentId: made } });
        }}
      />
    </div>
  );
}

type ChainStep = {
  seq: number;
  source: string;
  rule_id: string | null;
  rule_version: number | null;
  band_seq?: number | null;
  approver_user_id: string | null;
  approver_of_record_user_id: string | null;
  covered: boolean;
  cover_kind: string | null;
  cover_trail: { from_user_id: string; to_user_id: string; reason: string | null }[];
};

type Stamp = {
  stamp_id: number;
  resolved_at: string;
  value_minor: number | null;
  currency: string | null;
  resolved_chain: { steps?: ChainStep[]; department_id?: string | null };
};

/**
 * The approval chain as it was resolved on this document.
 *
 * The stamp is evidence, not a live calculation: it records which rule, at
 * which version, chose each approver, and where cover moved the decision to
 * somebody else while keeping the approver of record.
 */
function ApprovalChain({ documentId }: { documentId: string }) {
  const { data, error } = useQuery({
    queryKey: ["erp_document_approval_chain", { p_document_id: documentId }],
    queryFn: () => callErp<Stamp[]>("erp_document_approval_chain", { p_document_id: documentId }),
  });

  const stamp = useErpAction({
    fn: "erp_stamp_document_approval",
    invalidates: ["erp_document_approval_chain"],
  });

  const latest = data?.[0];
  const steps = latest?.resolved_chain?.steps ?? [];

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Approval routing</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {latest
              ? `Resolved ${latest.resolved_at.slice(0, 16).replace("T", " ")}, against the rules in force at that moment.`
              : "Nothing has been stamped on this document yet. Stamping records the chain, the rule version behind each step, and any cover in force."}
          </Prose>
        </div>
        <ActionButton
          busy={stamp.isPending}
          onClick={() => stamp.mutate({ p_document_id: documentId })}
        >
          Stamp the approval chain
        </ActionButton>
      </header>

      <div className="px-4 py-4 sm:px-5">
        <ErrorNote error={error ?? stamp.error} />
        {steps.length === 0 ? (
          <p className="text-xs text-muted-foreground">No steps resolved.</p>
        ) : (
          <Table columns={["Step", "Chosen by", "Rule version", "Approver", "Of record", "Cover"]}>
            {steps.map((s) => (
              <tr key={s.seq} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4 tabular-nums">{s.seq}</td>
                <td className="py-2 pr-4">
                  {s.source === "named_assignment"
                    ? "Named assignment"
                    : `Band ${s.band_seq ?? ""}`}
                </td>
                <td className="py-2 pr-4 tabular-nums">{s.rule_version ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">{s.approver_user_id ?? "—"}</td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {s.approver_of_record_user_id ?? "—"}
                </td>
                <td className="py-2 pr-4">
                  {s.covered ? (
                    <Pill tone="warn">{s.cover_kind ?? "cover"}</Pill>
                  ) : (
                    <span className="text-xs text-muted-foreground">none</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </div>
    </section>
  );
}

/**
 * Who decided this document's approval, task by task (20260914098000). An
 * administrator may approve for the people asked, or their own request, where
 * the organisation allows it, and each such decision says so.
 */
function ApprovalDecisions({ documentId }: { documentId: string }) {
  const { data, error } = useQuery({
    queryKey: ["erp_document_approval_decisions", { p_document_id: documentId }],
    queryFn: () =>
      callErp<ApprovalDecision[]>("erp_document_approval_decisions", {
        p_document_id: documentId,
      }),
  });

  const decisions = data ?? [];
  if (!error && decisions.length === 0) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Approval decisions</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Every task this document&apos;s approval asked for, who decided it and when.
        </Prose>
      </header>
      <div className="w-full max-w-full overflow-x-auto px-4 py-4 sm:px-5">
        <ErrorNote error={error} />
        {decisions.length > 0 ? (
          <Table columns={["Step", "Decision", "When", "Comment"]}>
            {decisions.map((d) => (
              <tr key={d.task_id} className="border-b border-border/60 last:border-0">
                <td className="py-2 pr-4">{d.step}</td>
                <td className="py-2 pr-4">
                  {decisionWords(d)}
                  {d.decided_via === "administrator" ? (
                    <>
                      {" "}
                      <Pill tone="warn">administrator</Pill>
                    </>
                  ) : null}
                </td>
                <td className="py-2 pr-4 whitespace-nowrap">
                  {d.decided_at ? d.decided_at.slice(0, 16).replace("T", " ") : "—"}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{d.comment ?? "—"}</td>
              </tr>
            ))}
          </Table>
        ) : null}
      </div>
    </section>
  );
}

function Lines({
  documentId,
  lines,
  committed,
  money,
  minorUnits,
  currency,
}: {
  documentId: string;
  lines: Line[];
  committed: boolean;
  money: (m: number) => string;
  minorUnits: number;
  currency: string;
}) {
  const price = useErpAction({
    fn: "erp_price_document_line",
    invalidates: ["erp_document"],
  });
  const amend = useErpAction({
    fn: "erp_amend_document_line",
    invalidates: ["erp_document", "erp_documents"],
  });

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Lines ({lines.length})</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {committed
              ? "This document is committed: the outside world has seen it, so lines are no longer editable. Amendment and reversal are what change it now."
              : "Prices are entered in major units and stored as an integer count of minor ones."}
          </Prose>
        </div>

        {/* erp.add_document_line refuses a committed document outright, so
            offering it would be a lie rather than a restriction. */}
        {!committed ? (
          <ActionDialog
            trigger={<ActionButton>Add line</ActionButton>}
            title="Add a line"
            description="The product list is this organisation's own; an empty one means no products have been created yet."
            fn="erp_add_document_line"
            fields={[
              {
                kind: "select",
                name: "p_item_id",
                label: "Product",
                required: true,
                options: {
                  fn: "erp_items",
                  value: "item_id",
                  label: ["code", "name"],
                },
              },
              { kind: "number", name: "p_quantity", label: "Quantity", required: true },
              {
                kind: "money",
                name: "p_unit_price_minor",
                label: "Unit price",
                currency,
              },
              {
                kind: "text",
                name: "p_description",
                label: "Description",
                placeholder: "As agreed on the phone",
                hint: "Optional. Overrides the product's own wording on this line.",
              },
            ]}
            mapArgs={(v) => ({
              p_document_id: documentId,
              p_item_id: v["p_item_id"],
              p_quantity: Number(v["p_quantity"] ?? 0),
              // toMinor, not a hand-rolled multiply. The two bugs it exists
              // for are both reachable from this form: Number("") is 0, so an
              // untouched price field would post a price of nothing rather
              // than leaving it unpriced; and 1.005 * 100 is 100.49999…, so
              // rounding the raw product gives 1.00 where the typist meant
              // 1.01. Null when it refuses — an absent price is a line the
              // pricing policies may still fill, and zero is a decision.
              p_unit_price_minor: toMinor((v["p_unit_price_minor"] ?? "") as string, minorUnits),
              p_description: v["p_description"] || null,
            })}
            invalidates={["erp_document", "erp_documents"]}
            submitLabel="Add line"
          />
        ) : null}
      </header>

      <div className="w-full max-w-full overflow-x-auto px-4 py-4 sm:px-5">
        {lines.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No lines yet. A document with no lines has no value to approve or post.
          </p>
        ) : (
          <Table columns={["#", "Product", "Their code", "Description", "Qty", "Unit", "Net", ""]}>
            {lines.map((l) => (
              <tr key={l.line_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 text-xs text-muted-foreground">{l.line_no}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.item ?? "—"}</td>
                {/* What the supplier calls it. Blank on anything they do not
                    supply, which is every sales line. */}
                <td className="py-2 pr-4 font-mono text-xs">{l.supplier_item_code ?? "—"}</td>
                <td className="py-2 pr-4">{l.description ?? "—"}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.quantity}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{money(l.unit_price_minor)}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{money(l.net_minor)}</td>
                <td className="py-2 pr-4">
                  {!committed ? (
                    <button
                      type="button"
                      onClick={() => price.mutate({ p_line_id: l.line_id })}
                      disabled={price.isPending}
                      className={`${TOUCH} inline-flex items-center text-xs font-medium text-muted-foreground underline underline-offset-2 disabled:opacity-50`}
                      title="Reprice this line through the tenant's promoted pricing policies."
                    >
                      Reprice
                    </button>
                  ) : (
                    /* A committed line changes only by amendment: a new
                       quantity, a reason, and the old figure kept beside it. */
                    <ActionDialog
                      trigger={
                        <button
                          type="button"
                          className={`${TOUCH} inline-flex items-center text-xs font-medium text-muted-foreground underline underline-offset-2`}
                        >
                          Amend
                        </button>
                      }
                      title="Amend a committed line"
                      description="The quantity changes; the old figure and the reason are kept with the line."
                      fn="erp_amend_document_line"
                      fields={[
                        {
                          kind: "number",
                          name: "p_quantity",
                          label: "New quantity",
                          required: true,
                        },
                        {
                          kind: "text",
                          name: "p_reason",
                          label: "Reason",
                          required: true,
                          placeholder: "Customer reduced the order",
                          hint: "Kept permanently against the amendment.",
                        },
                      ]}
                      mapArgs={(v) => ({
                        p_line_id: l.line_id,
                        p_quantity: Number(v["p_quantity"] ?? 0),
                        p_reason: v["p_reason"],
                      })}
                      invalidates={["erp_document", "erp_documents"]}
                      submitLabel="Amend"
                    />
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
        <ErrorNote error={price.error} />
        <ErrorNote error={amend.error} />
      </div>
    </section>
  );
}

/**
 * Where this document came from and what came of it.
 *
 * Already in the payload — `erp.document_lineage()` walks the relation graph
 * recursively — and rendered nowhere until now.
 */
function LineagePanel({
  lineage,
  documentId,
  typeName,
}: {
  lineage: Lineage[];
  documentId: string;
  typeName: (base: string) => string;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <h2 className="text-sm font-semibold">Related documents</h2>
        {/* A relation that was not raised by a conversion — a credit for an
            invoice raised elsewhere, a correction, a consolidation — is
            declared here, with its kind. */}
        <ActionDialog
          trigger={<ActionButton variant="secondary">Link a document</ActionButton>}
          title="Link this document to another"
          description="Records how the two relate. The relation is what lineage and matching read."
          fn="erp_link_documents"
          fields={[
            {
              kind: "select",
              name: "p_to_document_id",
              label: "Related document",
              required: true,
              // Any document but a cancelled one: what a relation points at —
              // the invoice a credit credits, the delivery an invoice invoices
              // — is usually posted or closed, so p_actionable would hide it.
              options: {
                fn: "erp_documents",
                args: { p_limit: 200, p_exclude_cancelled: true },
                value: "document_id",
                label: ["document_number", "document_type"],
              },
            },
            {
              kind: "choice",
              name: "p_kind",
              label: "Relation",
              required: true,
              choices: [
                { value: "fulfils", label: "Fulfils" },
                { value: "invoices", label: "Invoices" },
                { value: "credits", label: "Credits" },
                { value: "converts", label: "Converts" },
                { value: "returns", label: "Returns" },
                { value: "consumes", label: "Consumes" },
                { value: "corrects", label: "Corrects" },
                { value: "consolidates", label: "Consolidates" },
                { value: "mirrors", label: "Mirrors" },
              ],
            },
            {
              kind: "number",
              name: "p_quantity",
              label: "Quantity",
              hint: "Where the relation carries one.",
            },
          ]}
          mapArgs={(v) => ({
            p_from_document_id: documentId,
            p_to_document_id: v["p_to_document_id"],
            p_kind: v["p_kind"],
            p_quantity: v["p_quantity"] ? Number(v["p_quantity"]) : null,
          })}
          invalidates={["erp_document"]}
          submitLabel="Link"
        />
      </div>
      <ul className="mt-3 flex flex-col gap-1 text-sm">
        {lineage.map((r) => (
          <li key={`${r.direction}-${r.document_id}`} className="min-w-0">
            <span className="text-xs text-muted-foreground">
              {r.direction === "ancestor" ? "from" : "to"} · {r.relation} ·{" "}
            </span>
            <Link
              to="/documents/$documentId"
              params={{ documentId: r.document_id }}
              className="underline underline-offset-2"
            >
              {r.document_number}
            </Link>{" "}
            <span className="text-xs text-muted-foreground">{typeName(r.base_type)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/**
 * Crediting a customer, from the despatch or the invoice that billed it.
 *
 * The whole document is credited. Crediting part of one is a matter of
 * quantities per line, which this dialog has no shape for; the door takes them,
 * so the API can, and the screen will when there is a line editor to put them
 * in.
 */
function CreditCustomer({ documentId, context }: { documentId: string; context: string }) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Give this back</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A credit note reverses what was billed and puts the goods back on the shelf at what they
            cost rather than at what they sold for. It is left in draft; issuing it is what moves
            the money and the stock.
          </Prose>
        </div>

        <ActionDialog
          trigger={<ActionButton>Credit this</ActionButton>}
          title="Credit the customer and take the goods back"
          description="Reverses this despatch: the customer owes less, revenue goes back, and the goods return to the shelf at what they cost rather than at what they sold for. A part return is valued at the average of what the whole despatch cost."
          permission="sales.invoice"
          fn="erp_raise_customer_credit_note"
          context={context}
          fields={[
            {
              kind: "text",
              name: "p_reason_code",
              label: "Why it came back",
              placeholder: "damaged",
              hint: "A short code you can count later: damaged, wrong item, over-ordered.",
              required: true,
            },
            {
              kind: "text",
              name: "p_reason",
              label: "What the customer said",
              placeholder: "Two cases crushed in transit",
              hint: "Optional, and the only thing anybody will remember six months later.",
            },
          ]}
          mapArgs={(v) => ({
            p_document_id: documentId,
            p_reason_code: (v["p_reason_code"] as string) || "",
            p_reason: (v["p_reason"] as string) || null,
          })}
          invalidates={["erp_document", "erp_documents"]}
        />
      </header>
    </section>
  );
}

/** Sending goods back to the supplier who sent them, against the receipt. */
function CreditSupplier({ documentId, context }: { documentId: string; context: string }) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Send this back</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A supplier credit note takes the goods off the shelf at what they cost and reduces what
            we owe by what the supplier is crediting. It is left in draft; issuing it is what moves
            the stock and the money.
          </Prose>
        </div>

        <ActionDialog
          trigger={<ActionButton>Send back</ActionButton>}
          title="Credit the supplier and send the goods back"
          description="Reverses this receipt: the goods leave at what they cost, what we owe the supplier falls by what they are crediting, and the purchase order's history shows the return."
          permission="procurement.order"
          fn="erp_raise_supplier_credit_note"
          context={context}
          fields={[
            {
              kind: "text",
              name: "p_reason_code",
              label: "Why it is going back",
              placeholder: "wrong_item",
              hint: "A short code you can count later: damaged, wrong item, over-supplied.",
              required: true,
            },
            {
              kind: "text",
              name: "p_reason",
              label: "What we told the supplier",
              placeholder: "Wrong grade on ten of the hundred",
              hint: "Optional, and the only thing anybody will remember six months later.",
            },
          ]}
          mapArgs={(v) => ({
            p_document_id: documentId,
            p_reason_code: (v["p_reason_code"] as string) || "",
            p_reason: (v["p_reason"] as string) || null,
          })}
          invalidates={["erp_document", "erp_documents"]}
        />
      </header>
    </section>
  );
}

/**
 * Unmaking what a posted invoice did to the ledger.
 *
 * The date is the reversal's own and defaults to today, which is the point of
 * offering it: a bill posted last month and found wrong this month belongs in
 * this month. A closed month refuses it and says which, so the field is not a
 * way round the close.
 */
function ReversePosting({
  documentId,
  context,
  reversal,
}: {
  documentId: string;
  context: string;
  reversal: Reversal[];
}) {
  const done = reversal[0];

  // Already reversed: the database refuses a second one by name, so offering
  // the control again would be an invitation into a refusal. What it shows
  // instead is the answer to the question somebody actually has — when, and
  // why.
  if (done) {
    return (
      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">This posting has been reversed</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            The invoice is still here and so is what it posted. Journal {done.journal_number ?? "—"}{" "}
            reversed {done.reverses_journal_number ?? "it"} on {done.posting_date}
            {done.reason ? `: ${done.reason}` : "."} What it was worth is off the ageing. To charge
            it again, raise it again as a new document.
          </Prose>
        </header>
      </section>
    );
  }

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Reverse this posting</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A posted invoice is not edited. Reversing it raises the opposite journal on a date of
            its own, and both the invoice and the correction stay in the record.
          </Prose>
        </div>

        <ActionDialog
          trigger={<ActionButton>Reverse it</ActionButton>}
          title="Reverse what this invoice posted"
          description="The opposite journal is posted on the date you give, the invoice stays exactly as it is, and what it was worth comes off the ageing. Nothing already posted is rewritten."
          permission="finance.post"
          fn="erp_reverse_document_posting"
          context={context}
          fields={[
            {
              kind: "text",
              name: "p_reason",
              label: "Why it is being reversed",
              placeholder: "Keyed against the wrong supplier",
              hint: "Kept on the reversing journal beside who reversed it and when. A bill keyed against the wrong supplier, an invoice raised twice, a price entered wrong.",
              required: true,
            },
            {
              kind: "date",
              name: "p_posting_date",
              label: "The date it is reversed on",
              hint: "Today unless you say otherwise. A posting made last month and reversed this month belongs in this month; a month that is closed refuses it and says so.",
            },
          ]}
          mapArgs={(v) => ({
            p_document_id: documentId,
            p_reason: (v["p_reason"] as string) || "",
            p_posting_date: (v["p_posting_date"] as string) || null,
          })}
          invalidates={["erp_document", "erp_documents"]}
        />
      </header>
    </section>
  );
}

/** The tax a supplier's invoice states, typed in from the invoice itself. */
function SupplierTax({
  documentId,
  currency,
  minorUnits,
}: {
  documentId: string;
  currency: string;
  minorUnits: number;
}) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0">
          <h2 className="text-sm font-semibold">Tax the supplier charged</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            Taken from the supplier's invoice, not worked out here: what they charged is their
            decision under their own obligations. Spread across the lines by what each is worth, at
            the rate on their invoice.
          </Prose>
        </div>

        <ActionDialog
          trigger={<ActionButton>State their tax</ActionButton>}
          title="State the tax the supplier charged"
          description="The figure on their invoice. Leave it at nothing if they charged none."
          fn="erp_state_supplier_tax"
          fields={[
            { kind: "money", name: "p_tax_minor", label: "Tax charged", currency, required: true },
            {
              kind: "text",
              name: "p_tax_code",
              label: "Tax code",
              placeholder: "S",
              hint: "The code on their invoice. S is the standard rate.",
            },
            {
              kind: "text",
              name: "p_note",
              label: "Note",
              placeholder: "Their invoice number",
              hint: "Optional. Kept with the determination so the figure can be traced back.",
            },
          ]}
          mapArgs={(v) => ({
            p_document_id: documentId,
            // The document's own exponent, not GBP's: a zero-decimal currency
            // would otherwise store a hundred times what was typed.
            p_tax_minor: toMinor((v["p_tax_minor"] ?? "") as string, minorUnits),
            p_tax_code: (v["p_tax_code"] as string) || "S",
            p_note: (v["p_note"] as string) || null,
          })}
          invalidates={["erp_document", "erp_documents"]}
        />
      </header>
    </section>
  );
}
