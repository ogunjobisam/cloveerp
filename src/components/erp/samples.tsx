import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { formatMinor } from "../../lib/money";
import {
  canSettle,
  quantityWords,
  sample,
  type Sample,
  type SamplePurpose,
} from "../../lib/samples";
import { ActionButton, ActionDialog, ErrorNote, type Field } from "./action";
import { pickParty, pickSite } from "./actions-bar";
import { Prose, TOUCH } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Suppliers' samples on the Purchasing screen (20261004930000): what each
 * supplier lent, what is still here, what for, and when it is due back, the
 * overdue first.
 *
 * Settle is drawn on a line only where public.erp_samples says the reader may
 * decide what becomes of it. It returns the sample to the supplier, keeps it
 * free of charge (ours at no cost), or buys it at the agreed price. The door
 * refuses regardless, and refuses buying at nothing.
 */

// Buying a sample prices its receipt's line, which the receipt's page reads.
const INVALIDATES = [
  "erp_samples",
  "erp_stock_health",
  "erp_stock_valuation",
  "erp_documents",
  "erp_document",
];

const TRIGGER = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium`;

function SettleSample({ s }: { s: Sample }) {
  const { ui } = useT();
  const fields: Field[] = [
    {
      kind: "choice",
      name: "p_outcome",
      label: "Settle",
      required: true,
      choices: [
        { value: "return", label: "Return to the supplier" },
        { value: "keep", label: "Keep free of charge" },
        { value: "buy", label: "Buy" },
      ],
    },
    {
      kind: "number",
      name: "p_quantity",
      label: "Quantity",
      hint: "Leave empty to settle everything still held.",
    },
    {
      kind: "money",
      name: "p_price_minor",
      label: "Price each",
      currency: s.currency,
      hint: "Required to buy. The price agreed with the supplier.",
    },
    {
      kind: "text",
      name: "p_reason",
      label: "Reason",
      placeholder: "Shot and done",
    },
  ];
  const context = fill(ui("{quantity} of {item} from {supplier}"), {
    quantity: quantityWords(s.held),
    item: s.description,
    supplier: s.supplier,
  });
  return (
    <ActionDialog
      trigger={
        <button type="button" className={TRIGGER} aria-label={`${ui("Settle")} ${context}`}>
          {ui("Settle")}
        </button>
      }
      title="Settle a sample"
      description="Return it to the supplier, keep it free, or buy it at the agreed price."
      permission="procurement.order"
      fn="erp_settle_samples"
      fields={fields}
      prefill={{ p_line: s.lineId }}
      preselect={{ p_outcome: "return" }}
      context={`${s.receiptNumber} · ${context}`}
      invalidates={INVALIDATES}
      submitLabel="Settle"
    />
  );
}

/**
 * A supplier's samples, arrived (20261004930000): held here as theirs, valued
 * by nobody, until they go back, are kept or are bought. On the card that
 * lists them, where a person looks for it; it was in the header's sheet of
 * everything else, away from the samples it adds to (J-68).
 */
const RECEIVE_SAMPLES_FIELDS: Field[] = [
  pickParty("supplier", "p_supplier", "Supplier"),
  pickSite("p_site"),
  {
    kind: "rows",
    name: "p_lines",
    label: "Products",
    addLabel: "Add a product",
    columns: [
      {
        name: "item_id",
        label: "Product",
        kind: "select",
        options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
      },
      { name: "quantity", label: "Quantity", kind: "number", placeholder: "1" },
    ],
  },
  {
    kind: "choice",
    name: "p_purpose",
    label: "Purpose",
    required: true,
    choices: [
      { value: "shoot", label: "Photo shoot" },
      { value: "buying", label: "Buying appointment" },
      { value: "press", label: "Press loan" },
      { value: "fit", label: "Fit or quality check" },
    ],
  },
  { kind: "date", name: "p_due_back", label: "Due back" },
  {
    kind: "text",
    name: "p_their_reference",
    label: "Their reference",
    placeholder: "Their delivery note or sample request",
  },
];

function ReceiveSamples() {
  const { ui } = useT();
  return (
    <ActionDialog
      trigger={<ActionButton variant="secondary">{ui("Receive samples")}</ActionButton>}
      title="Receive samples"
      description="The samples stay the supplier's: held and counted here, valued by nobody, until they go back, are kept or are bought."
      permission="procurement.receive"
      fn="erp_receive_samples"
      fields={RECEIVE_SAMPLES_FIELDS}
      invalidates={["erp_samples", "erp_documents", "erp_stock_health"]}
      submitLabel="Receive samples"
    />
  );
}

export function Samples() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_samples", { p_include_settled: false }],
    queryFn: () => callErp<unknown>("erp_samples", { p_include_settled: false }),
    enabled: mayRead,
  });
  // Receiving them was offered to whoever may receive, from the header, before
  // it moved here; it still is, with the list drawn only for whoever may read.
  const mayReceive = hasPermission(session, "procurement.receive");
  if (!mayRead && !mayReceive) return null;

  const purposeWord: Record<SamplePurpose, string> = {
    shoot: ui("Photo shoot"),
    buying: ui("Buying appointment"),
    press: ui("Press loan"),
    fit: ui("Fit or quality check"),
  };
  const samples = (Array.isArray(data) ? data : [])
    .map(sample)
    .filter((s): s is Sample => s !== null);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <h2 className="text-sm font-semibold">{ui("Samples")}</h2>
        <ReceiveSamples />
      </div>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Samples suppliers lent: theirs until they go back, are kept or are bought.")}
      </Prose>
      <ErrorNote error={error} />
      {!mayRead ? null : samples.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui(
            "No samples are held. Samples a supplier lends land here until they go back, are kept or are bought.",
          )}
        </p>
      ) : (
        <ul className="mt-3 flex flex-col divide-y divide-border text-sm">
          {samples.map((s) => (
            <li key={s.lineId} className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 py-2">
              <span className="min-w-0 font-medium">{s.description}</span>
              <span className="text-muted-foreground">{s.supplier}</span>
              <span className="tabular-nums">
                {ui("Held")} {quantityWords(s.held)}
              </span>
              {s.purpose ? (
                <span className="text-muted-foreground">{purposeWord[s.purpose]}</span>
              ) : null}
              {s.dueBack ? (
                <span className="tabular-nums text-muted-foreground">
                  {ui("Due back")} {s.dueBack}
                </span>
              ) : null}
              {s.overdue ? <Pill tone="bad">{ui("Overdue")}</Pill> : null}
              {s.receiptId ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: s.receiptId }}
                  className="text-xs underline underline-offset-2"
                >
                  {s.receiptNumber}
                </Link>
              ) : null}
              <span className="ml-auto">{canSettle(s) ? <SettleSample s={s} /> : null}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

/**
 * What became of a supplier's samples, on their receipt's own page (J-15,
 * 20261007061000): what for, when they are due back, and for each line what
 * was received, returned, kept free, bought and at what price each, and what
 * is still held. The receipt's lines alone said none of it: a bought sample's
 * line carries the price it was bought at and a net of nothing.
 *
 * Read from erp_samples with the settled lines included, which is where
 * Samples on the Purchasing page reads them; Settle is drawn on a line where
 * the database says the reader may.
 */
export function SampleReceipt({ receiptId }: { receiptId: string }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_samples", { p_include_settled: true }],
    queryFn: () => callErp<unknown>("erp_samples", { p_include_settled: true }),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const lines = (Array.isArray(data) ? data : [])
    .map(sample)
    .filter((s): s is Sample => s !== null && s.receiptId === receiptId);
  if (lines.length === 0) return <ErrorNote error={error} />;

  const purposeWord: Record<SamplePurpose, string> = {
    shoot: ui("Photo shoot"),
    buying: ui("Buying appointment"),
    press: ui("Press loan"),
    fit: ui("Fit or quality check"),
  };
  // The purpose and the date due back are the receipt's, the same on every line.
  const first = lines[0];
  const overdue = lines.some((s) => s.overdue);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Samples")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Samples suppliers lent: theirs until they go back, are kept or are bought.")}
      </Prose>
      <div className="mt-2 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        {first?.purpose ? (
          <span className="text-xs text-muted-foreground">
            {ui("Purpose")} <span className="text-foreground">{purposeWord[first.purpose]}</span>
          </span>
        ) : null}
        {first?.dueBack ? (
          <span className="text-xs text-muted-foreground">
            {ui("Due back")} <span className="tabular-nums text-foreground">{first.dueBack}</span>
          </span>
        ) : null}
        {overdue ? <Pill tone="bad">{ui("Overdue")}</Pill> : null}
      </div>
      <ul className="mt-3 flex flex-col divide-y divide-border text-sm">
        {lines.map((s) => (
          <li key={s.lineId} className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 py-2">
            <span className="min-w-0 font-medium">{s.description}</span>
            <span className="tabular-nums">
              {ui("Received")} {quantityWords(s.received)}
            </span>
            {s.returned > 0 ? (
              <span className="tabular-nums">
                {ui("Returned")} {quantityWords(s.returned)}
              </span>
            ) : null}
            {s.kept > 0 ? (
              <span className="tabular-nums">
                {ui("Kept")} {quantityWords(s.kept)}
              </span>
            ) : null}
            {s.bought > 0 ? (
              <span className="tabular-nums">
                {ui("Bought")} {quantityWords(s.bought)}
              </span>
            ) : null}
            {s.bought > 0 && s.boughtPriceMinor !== null ? (
              <span className="tabular-nums text-muted-foreground">
                {ui("Price each")} {formatMinor(s.boughtPriceMinor, s.currency)}
              </span>
            ) : null}
            <span className="tabular-nums">
              {ui("Held")} {quantityWords(s.held)}
            </span>
            <span className="ml-auto">{canSettle(s) ? <SettleSample s={s} /> : null}</span>
          </li>
        ))}
      </ul>
      <ErrorNote error={error} />
    </section>
  );
}
