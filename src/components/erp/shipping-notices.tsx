import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { fill } from "../../lib/interview";
import { inboundShipments } from "../../lib/inbound-shipments";
import { lineName } from "../../lib/line-name";
import {
  differenceWords,
  arrivedSeed,
  noticeCartonsTyped,
  noticeLineSummary,
  noticeLinesTyped,
  noticeOpen,
  noticeWords,
  orderLineWords,
  orderNotices,
  recordNoticeSeed,
  shippingNotices,
  type ShippingNotice,
} from "../../lib/shipping-notices";
import { awaitingOrders } from "../../lib/supplier-confirmation";
import { ActionButton, ActionDialog, ErrorNote, type Field } from "./action";
import { AwaitingConfirmations } from "./awaiting-confirmations";
import { InboundShipments } from "./inbound-shipments";
import { LineProduct } from "./line-product";
import { LoadingRows, Prose } from "./page";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Advance shipping notices (20261005000000): on a purchase order's page, what
 * the supplier said is on its way and how it arrived, with the buyer's moves —
 * record a notice the supplier gave by email or phone, cancel one that will
 * not come — and goods-in's — receive it as notified, or as it arrived. On the
 * Purchasing screen, everything on its way, late first, and a carton received
 * by the SSCC on its label. The database refuses regardless.
 */

const INVALIDATES = [
  "erp_order_shipping_notices",
  "erp_shipping_notices",
  "erp_document",
  "erp_documents",
  "erp_document_lines",
];

/**
 * What arrived, line by line, when it was not what the notice said.
 *
 * A notice still wholly on its way arrives holding its own lines at what it
 * said, ready to correct (J-59); untouched, they are received as notified,
 * which is what leaving them out meant. A part-received notice arrives empty:
 * what is left of each of its lines is not the quantity it said, and a line
 * left out is still taken as what is left of it.
 */
function arrivedFields(
  n: Pick<ShippingNotice, "orderId" | "status">,
  ui: (text: string) => string,
): Field[] {
  return [
    {
      kind: "rows",
      name: "lines",
      label: "What arrived",
      hint: "Lines left out are taken as notified. A line the notice did not hold can be added.",
      ...(n.status === "notified" ? { seed: arrivedSeed(n.orderId) } : {}),
      columns: [
        {
          name: "order_line_id",
          label: "Line",
          kind: "select",
          options: {
            fn: "erp_document_lines",
            args: { p_document_id: n.orderId, p_limit: 500 },
            value: "line_id",
            label: ["item", "quantity"],
            describe: (row) => fill(ui("{item}: {quantity} ordered"), orderLineWords(row).words),
          },
        },
        { name: "quantity", label: "Arrived", kind: "number", placeholder: "3" },
      ],
      addLabel: "Add a line",
    },
  ];
}

function arrivedArgs(
  noticeId: string,
  picked?: { rows: Record<string, Record<string, string>[]> },
): Record<string, unknown> {
  // mapArgs is handed what was typed: the quantities as text.
  const lines = (picked?.rows["lines"] ?? [])
    .filter((row) => (row["order_line_id"] ?? "") !== "" && (row["quantity"] ?? "") !== "")
    .map((row) => ({ order_line_id: row["order_line_id"], quantity: Number(row["quantity"]) }));
  return { p_notice: noticeId, p_lines: lines.length > 0 ? lines : null };
}

function ReceiveMoves({ n, context }: { n: ShippingNotice; context: string }) {
  const { ui } = useT();
  return (
    <>
      <ActionDialog
        trigger={<ActionButton>{ui("Receive as notified")}</ActionButton>}
        title="Receive as notified"
        description="Receives everything the notice says is coming, in one posted goods receipt."
        permission="procurement.receive"
        fn="erp_receive_as_notified"
        fields={[]}
        prefill={{ p_notice: n.noticeId }}
        context={context}
        invalidates={INVALIDATES}
        submitLabel="Receive"
      />
      <ActionDialog
        trigger={<ActionButton variant="secondary">{ui("Receive what arrived")}</ActionButton>}
        title="Receive what arrived"
        description="For a delivery that differs from its notice. The differences are kept on the notice and the buyer is told; the order stays open for anything short."
        permission="procurement.receive"
        fn="erp_receive_as_notified"
        fields={arrivedFields(n, ui)}
        // The notice the editor's rows are read from; sent as the door's own.
        prefill={{ p_notice: n.noticeId }}
        mapArgs={(_v, picked) => arrivedArgs(n.noticeId, picked)}
        context={context}
        invalidates={INVALIDATES}
        submitLabel="Receive"
      />
    </>
  );
}

function NoticeCard({ n, context }: { n: ShippingNotice; context: string }) {
  const { ui } = useT();
  const status = noticeWords(n.status);
  const cartonsIn = n.cartons.filter((c) => c.receivedAt !== null).length;
  return (
    <li className="min-w-0 py-3">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        <span className="font-medium">{n.notice}</span>
        <Pill tone={status.tone}>{ui(status.words)}</Pill>
        {n.late ? <Pill tone="bad">{ui("Late")}</Pill> : null}
        <span className="tabular-nums text-muted-foreground">
          {ui("Arrives")} {n.expectedArrival ?? "—"}
        </span>
        {n.carrier ? (
          <span className="text-muted-foreground">
            {n.carrier}
            {n.trackingReference ? ` · ${n.trackingReference}` : ""}
          </span>
        ) : null}
        {n.cartons.length > 0 ? (
          <span className="text-xs text-muted-foreground">
            {cartonsIn}/{n.cartons.length} {ui("cartons in")}
          </span>
        ) : null}
        {n.receiptId && n.receipt ? (
          <Link
            to="/documents/$documentId"
            params={{ documentId: n.receiptId }}
            className="underline underline-offset-2"
          >
            {n.receipt}
          </Link>
        ) : null}
      </div>
      <div className="mt-2">
        <Table columns={[ui("Line"), ui("Item"), ui("Notified"), ui("Received")]}>
          {n.lines.map((l) => (
            <tr key={l.orderLineId} className="border-b border-border/60 last:border-0">
              <td className="py-2 pr-4 tabular-nums">{l.lineNo}</td>
              <td className="py-2 pr-4">
                <LineProduct name={lineName(l.itemCode, l.itemName, l.description)} />
              </td>
              <td className="py-2 pr-4 tabular-nums">{l.quantity}</td>
              <td className="py-2 tabular-nums">{l.receivedQuantity ?? "—"}</td>
            </tr>
          ))}
        </Table>
      </div>
      {n.differences.length > 0 ? (
        <ul className="mt-2 flex flex-col gap-1 text-xs">
          {n.differences.map((d, i) => (
            <li key={`${d.orderLineId}-${i}`} className="flex flex-wrap gap-2">
              <Pill tone="warn">{ui(differenceWords(d.kind))}</Pill>
              <span className="tabular-nums">
                {ui("Line")} {d.lineNo ?? "—"}: {d.notified} {ui("notified")}, {d.received}{" "}
                {ui("received")}
              </span>
            </li>
          ))}
        </ul>
      ) : null}
      {n.status === "cancelled" && n.cancelledReason ? (
        <p className="mt-2 min-w-0 break-words text-xs text-muted-foreground">
          {ui("Why it is cancelled")}: {n.cancelledReason}
        </p>
      ) : null}
      {noticeOpen(n) ? (
        <div className="mt-3 flex flex-wrap gap-2">
          <ReceiveMoves n={n} context={context} />
          {n.status === "notified" ? (
            <ActionDialog
              trigger={<ActionButton variant="secondary">{ui("Cancel the notice")}</ActionButton>}
              title="Cancel the notice"
              description="The shipment will not come as notified. What it held is open for another notice."
              permission="procurement.order"
              fn="erp_cancel_shipping_notice"
              fields={[
                {
                  kind: "text",
                  name: "p_reason",
                  label: "Why it is cancelled",
                  required: true,
                  placeholder: "The supplier split the delivery",
                },
              ]}
              prefill={{ p_notice: n.noticeId }}
              context={context}
              invalidates={INVALIDATES}
              submitLabel="Cancel the notice"
            />
          ) : null}
        </div>
      ) : null}
    </li>
  );
}

/** A purchase order's notices, on its page. */
export function OrderShippingNotices({
  documentId,
  context,
}: {
  documentId: string;
  context: string;
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error, isPending } = useQuery({
    queryKey: ["erp_order_shipping_notices", { p_order: documentId }],
    queryFn: () => callErp<unknown>("erp_order_shipping_notices", { p_order: documentId }),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  // What was read is kept while a later read fails, with the failure beside
  // it, so a form open over the section is not taken away (J-34). Its place
  // is held while it is first read, so the sections below it do not move
  // under a pointer when it lands (J-128).
  if (error && data === undefined) return <ErrorNote error={error} />;
  if (isPending) return <LoadingRows rows={1} />;
  const { notices, open } = orderNotices(data);
  const anyOpen = open.some((o) => o.open > 0);
  if (notices.length === 0 && !anyOpen) return <ErrorNote error={error} />;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Shipping notices")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui(
          "What the supplier said is on its way, from the link in the order's email or recorded by you, and how it arrived.",
        )}
      </Prose>
      {notices.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">{ui("Nothing notified yet.")}</p>
      ) : (
        <ul className="mt-2 flex flex-col divide-y divide-border">
          {notices.map((n) => (
            <NoticeCard key={n.noticeId} n={n} context={context} />
          ))}
        </ul>
      )}
      {anyOpen ? (
        <div className="mt-3">
          <RecordNotice orderId={documentId} open={open} context={context} />
        </div>
      ) : null}
      {error ? (
        <div className="mt-3">
          <ErrorNote error={error} />
        </div>
      ) : null}
    </section>
  );
}

function RecordNotice({
  orderId,
  open,
  context,
}: {
  orderId: string;
  /** What of each line is still open for a notice, as the order's page read it. */
  open: readonly { orderLineId: string; open: number }[];
  context: string;
}) {
  const { ui } = useT();
  const openByLine = new Map(open.map((o) => [o.orderLineId, o.open]));
  const lineOptions = {
    fn: "erp_document_lines",
    args: { p_document_id: orderId, p_limit: 500 },
    value: "line_id",
    label: ["item", "quantity"],
    // "RM-300 — 6" said neither that 6 was ordered nor what was open (J-61).
    describe: (row: Record<string, unknown>) => {
      const { words, open: left } = orderLineWords(row, openByLine);
      return left === null
        ? fill(ui("{item}: {quantity} ordered"), words)
        : fill(ui("{item}: {open} of {quantity} still open"), { ...words, open: left });
    },
  };
  const fields: Field[] = [
    { kind: "date", name: "ship_date", label: "Sent on" },
    { kind: "date", name: "expected_arrival", label: "Arrives on", required: true },
    { kind: "text", name: "carrier", label: "Carrier", placeholder: "DHL" },
    {
      kind: "text",
      name: "tracking_reference",
      label: "Tracking number",
      hint: "Optional. The consignment or tracking number.",
    },
    {
      kind: "text",
      name: "supplier_reference",
      label: "Their delivery note number",
      placeholder: "DN-1234",
    },
    {
      kind: "rows",
      name: "lines",
      label: "What is on its way",
      // A notice holding nothing is refused by the door (J-60): the editor
      // arrives holding what is still open on each line, and is required.
      required: true,
      seed: recordNoticeSeed(orderId),
      columns: [
        { name: "order_line_id", label: "Line", kind: "select", options: lineOptions },
        { name: "quantity", label: "Quantity", kind: "number", placeholder: "6" },
      ],
      addLabel: "Add a line",
    },
    // A buyer can say which carton holds what, as the supplier's link can, so
    // goods-in can receive a carton by its label (J-70).
    {
      kind: "rows",
      name: "cartons",
      label: "Cartons",
      hint: "Optional. For cartons with an SSCC label: a row for each line a carton holds. Together the cartons must hold exactly what the lines above say.",
      columns: [
        { name: "sscc", label: "SSCC", kind: "text", placeholder: "(00)350123451234567894" },
        { name: "order_line_id", label: "Line", kind: "select", options: lineOptions },
        { name: "quantity", label: "Quantity", kind: "number", placeholder: "6" },
      ],
      addLabel: "Add a carton",
    },
  ];
  return (
    <ActionDialog
      trigger={<ActionButton variant="secondary">{ui("Record a shipping notice")}</ActionButton>}
      title="Record a shipping notice"
      description="For a delivery the supplier told you about by email or phone. No more than is still open on each line."
      permission="procurement.order"
      fn="erp_record_shipping_notice"
      fields={fields}
      mapArgs={(v, picked) => {
        // mapArgs is handed what was typed: the quantities as text. A line
        // the editor arrived holding at nought is already notified in full.
        const lines = noticeLinesTyped(picked?.rows["lines"] ?? []);
        const cartons = noticeCartonsTyped(picked?.rows["cartons"] ?? []);
        const opt = (k: string) => (v[k] ? { [k]: v[k] } : {});
        return {
          p_order: orderId,
          p_notice: {
            ...opt("ship_date"),
            expected_arrival: v["expected_arrival"] ?? "",
            ...opt("carrier"),
            ...opt("tracking_reference"),
            ...opt("supplier_reference"),
            lines,
            ...(cartons.length > 0 ? { cartons } : {}),
          },
        };
      }}
      context={context}
      invalidates={INVALIDATES}
      submitLabel="Record"
    />
  );
}

/**
 * Everything on its way to goods in, on the Purchasing screen: one card for
 * the supplier's side of an order after it is sent.
 *
 * It used to be three cards one after another — orders awaiting their
 * supplier's answer, deliveries notified, collections booked — two of them
 * headed "On its way", and each saying in its own sentence that it was empty.
 * They are three lists of one card now: a list with nothing in it is left
 * out, and the card says once when nothing is on its way at all.
 */
export function OnItsWay() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  // Three reads, each for whoever may read purchasing: the orders still
  // waiting on their supplier, the deliveries notified, the collections booked.
  const awaiting = useQuery({
    queryKey: ["erp_awaiting_confirmations"],
    queryFn: () => callErp<unknown>("erp_awaiting_confirmations", {}),
    enabled: mayRead,
  });
  const notified = useQuery({
    queryKey: ["erp_shipping_notices"],
    queryFn: () => callErp<unknown>("erp_shipping_notices", {}),
    enabled: mayRead,
  });
  const inbound = useQuery({
    queryKey: ["erp_inbound_shipments"],
    queryFn: () => callErp<unknown>("erp_inbound_shipments", {}),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const orders = awaitingOrders(awaiting.data);
  const notices = shippingNotices(notified.data);
  const shipments = inboundShipments(inbound.data);
  const nothing = orders.length === 0 && notices.length === 0 && shipments.length === 0;
  // Said only once every read has answered: a list still being read is not
  // an empty one, and neither is one that failed.
  const answered = [awaiting, notified, inbound].every((q) => !q.isPending && !q.error);
  // A list still being read holds its place, and what failed is said at the
  // foot of the card: nothing arrives above a button already drawn, which
  // moved "Receive what arrived" from under the pointer while a slow read
  // landed (J-128).
  const placeholder = <LoadingRows rows={1} className="py-4 first:pt-0 last:pb-0" />;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <h2 className="text-sm font-semibold">{ui("On its way")}</h2>
        <ActionDialog
          trigger={<ActionButton variant="secondary">{ui("Receive a carton")}</ActionButton>}
          title="Receive a carton"
          description="Scan or type the SSCC on the carton's label. What its notice says it holds is received in a posted goods receipt."
          permission="procurement.receive"
          fn="erp_receive_notified_carton"
          fields={[
            {
              kind: "text",
              name: "p_sscc",
              label: "SSCC",
              required: true,
              placeholder: "(00)350123451234567894",
              hint: "A scanner types the label straight in.",
            },
          ]}
          context="Goods in"
          invalidates={INVALIDATES}
          submitLabel="Receive"
        />
      </div>
      {nothing && answered ? (
        <p className="mt-3 text-sm text-muted-foreground">{ui("Nothing is on its way.")}</p>
      ) : (
        <div className="mt-3 flex flex-col divide-y divide-border empty:hidden">
          {awaiting.isPending ? (
            placeholder
          ) : orders.length > 0 ? (
            <AwaitingConfirmations orders={orders} />
          ) : null}
          {notified.isPending ? (
            placeholder
          ) : notices.length > 0 ? (
            <div className="min-w-0 py-4 first:pt-0 last:pb-0">
              <h3 className="text-sm font-medium">{ui("Shipping notices")}</h3>
              <Prose className="mt-0.5 text-xs text-muted-foreground">
                {ui(
                  "Deliveries suppliers have told you are coming, the late ones first. Receive one as notified, or a carton by scanning its label.",
                )}
              </Prose>
              <ul className="mt-2 flex flex-col divide-y divide-border text-sm">
                {notices.map((n) => (
                  <li
                    key={n.noticeId}
                    className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-2 py-2"
                  >
                    <Link
                      to="/documents/$documentId"
                      params={{ documentId: n.orderId }}
                      className="font-medium underline underline-offset-2"
                    >
                      {n.order}
                    </Link>
                    {/* Which notice, and what it holds: two notices against
                        one order read the same without them (J-57). */}
                    <span className="tabular-nums">{n.notice}</span>
                    <span className="text-muted-foreground">{n.supplier}</span>
                    {n.lines.length > 0 ? (
                      <span className="min-w-0 text-xs text-muted-foreground">
                        {noticeLineSummary(n.lines)}
                      </span>
                    ) : null}
                    <span className="tabular-nums">
                      {ui("Arrives")} {n.expectedArrival ?? "—"}
                    </span>
                    {n.late ? <Pill tone="bad">{ui("Late")}</Pill> : null}
                    {n.status === "part_received" ? (
                      <Pill tone="warn">{ui("Part received")}</Pill>
                    ) : null}
                    {n.carrier ? (
                      <span className="text-xs text-muted-foreground">
                        {n.carrier}
                        {n.trackingReference ? ` · ${n.trackingReference}` : ""}
                      </span>
                    ) : null}
                    <span className="ml-auto flex flex-wrap gap-2">
                      <ReceiveMoves n={n} context={`${n.notice} · ${n.order}`} />
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {inbound.isPending ? (
            placeholder
          ) : shipments.length > 0 ? (
            <InboundShipments shipments={shipments} />
          ) : null}
        </div>
      )}
      <div className="mt-3 flex flex-col gap-2 empty:hidden">
        <ErrorNote error={awaiting.error} />
        <ErrorNote error={notified.error} />
        <ErrorNote error={inbound.error} />
      </div>
    </section>
  );
}
