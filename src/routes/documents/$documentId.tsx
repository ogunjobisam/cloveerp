import { useQuery } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";

import { ActionButton, ActionDialog, ErrorNote, useErpAction } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";
import { formatMinor, minorUnitsOf, type Currency } from "../../lib/money";

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
  head: () => ({ meta: [{ title: "Document — ERPWare" }] }),
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
};

type Lineage = {
  depth: number;
  direction: string;
  document_id: string;
  document_number: string;
  base_type: string;
  relation: string;
};

type Transition = {
  code: string;
  name: string;
  to_state: string;
  /** The caller holds the transition's `required_permission`. */
  permitted: boolean;
  /** The transition's guard evaluates true against this document's numbers. */
  guard_passes: boolean;
  is_automatic: boolean;
};

type Payload = {
  document: Doc | null;
  lines: Line[];
  lineage: Lineage[];
  available_transitions: Transition[];
};

function Document() {
  const { documentId } = Route.useParams();

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_document", { p_document_id: documentId }],
    queryFn: () => callErp<Payload>("erp_document", { p_document_id: documentId }),
  });

  const { data: currencies } = useQuery({
    queryKey: ["erp_currencies", {}],
    queryFn: () => callErp<Currency[]>("erp_currencies"),
    staleTime: Infinity,
  });

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
          No document with that identifier is visible to this tenant.
        </PageHeader>
      </div>
    );
  }

  const minorUnits = minorUnitsOf(currencies, doc.currency);
  const money = (m: number) => formatMinor(m, doc.currency, minorUnits);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={doc.document_number}>
        {doc.document_type} · {doc.party ?? "no party"} · {doc.document_date}
      </PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <div className="flex flex-wrap items-center gap-3">
          <Pill tone={doc.is_committed ? "ok" : "muted"}>{doc.state_name ?? doc.state ?? "—"}</Pill>
          <span className="text-sm tabular-nums">{money(doc.total_minor)}</span>
          {doc.their_reference ? (
            <span className="text-xs text-muted-foreground">their ref {doc.their_reference}</span>
          ) : null}
        </div>

        <Transitions
          documentId={documentId}
          transitions={data.available_transitions}
          committed={doc.is_committed}
        />
      </section>

      <Lines
        documentId={documentId}
        lines={data.lines}
        committed={doc.is_committed}
        money={money}
        minorUnits={minorUnits}
        currency={doc.currency}
      />

      <ApprovalChain documentId={documentId} />

      {data.lineage.length > 0 ? <LineagePanel lineage={data.lineage} /> : null}
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
    queryFn: () =>
      callErp<Stamp[]>("erp_document_approval_chain", { p_document_id: documentId }),
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
        <ActionButton busy={stamp.isPending} onClick={() => stamp.mutate({ p_document_id: documentId })}>
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
                  {s.source === "named_assignment" ? "Named assignment" : `Band ${s.band_seq ?? ""}`}
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
 * What may happen to this document next.
 *
 * Three states, and the difference between the last two is the reason
 * `erp_available_transitions` exists:
 *
 *   permitted, guard passes  — offered
 *   not permitted            — not offered at all, because the caller may not
 *   guard does not pass      — offered, disabled, and named
 *
 * "You may not do this" and "you may do this but not yet" are different facts,
 * and collapsing them into a greyed button tells the reader neither.
 */
function Transitions({
  documentId,
  transitions,
  committed,
}: {
  documentId: string;
  transitions: Transition[];
  committed: boolean;
}) {
  const act = useErpAction({
    fn: "erp_transition_document",
    invalidates: ["erp_document", "erp_documents"],
  });

  const offered = transitions.filter((t) => t.permitted && !t.is_automatic);

  if (offered.length === 0) {
    return (
      <p className="mt-4 text-xs text-muted-foreground">
        {transitions.length === 0
          ? committed
            ? "This document has reached a state its lifecycle does not continue from."
            : "This document's type has no lifecycle configured, so there is nothing to move it through."
          : "Nothing here is offered to this account. The transitions this document has all require a permission it does not hold."}
      </p>
    );
  }

  return (
    <div className="mt-4 flex flex-col gap-2">
      <div className="flex flex-wrap gap-2">
        {offered.map((t) => (
          <ActionButton
            key={t.code}
            variant={t.guard_passes ? "primary" : "secondary"}
            disabled={!t.guard_passes}
            busy={act.isPending}
            title={
              t.guard_passes
                ? `Moves this document to ${t.to_state}.`
                : "This document does not yet satisfy the condition on this transition."
            }
            onClick={() => act.mutate({ p_document_id: documentId, p_transition_code: t.code })}
          >
            {t.name}
          </ActionButton>
        ))}
      </div>
      <ErrorNote error={act.error} />
    </div>
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
            description="The item list is this tenant's own; an empty one means no items have been created yet."
            fn="erp_add_document_line"
            fields={[
              {
                kind: "select",
                name: "p_item_id",
                label: "Item",
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
              { kind: "text", name: "p_description", label: "Description" },
            ]}
            mapArgs={(v) => ({
              p_document_id: documentId,
              p_item_id: v["p_item_id"],
              p_quantity: Number(v["p_quantity"] ?? 0),
              p_unit_price_minor: Math.round(
                Number(v["p_unit_price_minor"] ?? 0) * 10 ** minorUnits,
              ),
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
          <Table columns={["#", "Item", "Description", "Qty", "Unit", "Net", ""]}>
            {lines.map((l) => (
              <tr key={l.line_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 text-xs text-muted-foreground">{l.line_no}</td>
                <td className="py-2 pr-4 font-mono text-xs">{l.item ?? "—"}</td>
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
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
        <ErrorNote error={price.error} />
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
function LineagePanel({ lineage }: { lineage: Lineage[] }) {
  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">Related documents</h2>
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
            <span className="text-xs text-muted-foreground">{r.base_type}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
