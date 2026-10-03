import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { Centred } from "../components/erp/gate";
import { formatMinor, isoMinorUnits } from "../lib/money";
import { noticePayload, ssccIsValid, ssccOf, type NoticeForm } from "../lib/shipping-notices";
import {
  supplierAnswer,
  tokenFromFragment,
  type LineEdit,
  type SupplierOrder,
} from "../lib/supplier-confirmation";
import {
  notifyShipment,
  respondToOrder,
  supplierOrderByLink,
} from "../lib/supplier-response.functions";

/**
 * Where a purchase order email's "Confirm this order" button lands
 * (20261004990000).
 *
 * The link is /respond#t=<token>. The supplier has no account, so the token is
 * their authority for one order and nothing else. Everything after the # stays
 * in the browser until this page sends it to the server in a request body, so
 * no server log or link scanner keeps it; the page takes it out of the address
 * bar on arrival. The server functions ask the database on the service role,
 * because a signed-out visitor may call no door themselves.
 *
 * The supplier confirms the order as it stands, changes the quantity or date
 * of any line, or declines it with a reason. A change waits for the buyer.
 * Once the order is confirmed, the same page takes what is on its way: when it
 * leaves and arrives, with whom, how much of each line, and the cartons by
 * the SSCC on their labels (20261005000000).
 */

export const Route = createFileRoute("/respond")({
  head: () => ({
    meta: [
      { title: "Confirm a purchase order — Clove ERP" },
      { name: "robots", content: "noindex, nofollow" },
    ],
  }),
  component: RespondPage,
});

const TOKEN_KEY = "clove.respond.token";

function RespondPage() {
  // The token, read from the fragment once the page is in the browser, kept
  // for this tab so a reload still answers, and taken out of the address bar.
  const [token, setToken] = useState<string | null>(null);
  const [read, setRead] = useState(false);
  useEffect(() => {
    let found = tokenFromFragment(window.location.hash);
    try {
      if (found) window.sessionStorage.setItem(TOKEN_KEY, found);
      else found = tokenFromFragment(`#t=${window.sessionStorage.getItem(TOKEN_KEY) ?? ""}`);
    } catch {
      // Storage refused: the fragment is all there is.
    }
    if (window.location.hash) {
      window.history.replaceState(null, "", window.location.pathname);
    }
    setToken(found);
    setRead(true);
  }, []);

  const order = useQuery({
    queryKey: ["supplier_order_by_link", token],
    queryFn: () => supplierOrderByLink({ data: { token: token ?? "" } }),
    enabled: token !== null,
    retry: false,
  });

  if (!read || (token !== null && order.isPending)) {
    return (
      <Centred>
        <p role="status" className="text-sm text-muted-foreground">
          Finding your order…
        </p>
      </Centred>
    );
  }
  if (token === null || !order.data) {
    return (
      <Centred>
        <div className="max-w-md text-center">
          <h1 className="text-lg font-semibold">This link answers no order</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            It may have expired, or the order was sent to you again with a new link. Use the button
            in the most recent email of the order, or reply to the buyer.
          </p>
        </div>
      </Centred>
    );
  }
  return <Answer token={token} order={order.data} />;
}

function Answer({ token, order }: { token: string; order: SupplierOrder }) {
  const queryClient = useQueryClient();
  const [edits, setEdits] = useState<Record<string, LineEdit>>({});
  const [reference, setReference] = useState(order.supplierReference ?? "");
  const [note, setNote] = useState("");
  const [declining, setDeclining] = useState(false);
  const places = isoMinorUnits(order.currency);

  const send = useMutation({
    mutationFn: (decision: "confirm" | "decline") =>
      respondToOrder({
        data: { token, answer: supplierAnswer(order, decision, edits, reference, note) },
      }),
    onSuccess: (result) => {
      if (result.ok) {
        void queryClient.invalidateQueries({ queryKey: ["supplier_order_by_link", token] });
      }
    },
  });

  const edit = (lineId: string, field: keyof LineEdit, value: string) =>
    setEdits((prev) => ({
      ...prev,
      [lineId]: { quantity: "", date: "", ...prev[lineId], [field]: value },
    }));

  const refused = send.data && !send.data.ok ? send.data.message : null;

  return (
    <main className="mx-auto w-full max-w-3xl px-4 py-8 sm:py-12">
      <p className="text-xs uppercase tracking-wide text-muted-foreground">{order.organisation}</p>
      <h1 className="mt-1 text-xl font-semibold">Purchase order {order.order}</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        For {order.supplier || "you"}
        {order.orderDate ? `, placed ${order.orderDate}` : ""}.
      </p>

      <StatusLine order={order} />

      <div className="mt-6 w-full overflow-x-auto rounded-xl border border-border">
        <table className="w-full min-w-[36rem] text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted-foreground">
              <th scope="col" className="px-3 py-2 font-medium">
                Line
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Item
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Ordered
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Price
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Wanted by
              </th>
              {order.canRespond ? (
                <>
                  <th scope="col" className="px-3 py-2 font-medium">
                    You can send
                  </th>
                  <th scope="col" className="px-3 py-2 font-medium">
                    By
                  </th>
                </>
              ) : (
                <th scope="col" className="px-3 py-2 font-medium">
                  Confirmed
                </th>
              )}
            </tr>
          </thead>
          <tbody>
            {order.lines.map((l) => (
              <tr key={l.lineId} className="border-b border-border/60 last:border-0">
                <td className="px-3 py-2 tabular-nums">{l.lineNo}</td>
                <td className="px-3 py-2">
                  {l.description}
                  {l.supplierItemCode ? (
                    <span className="block text-xs text-muted-foreground">
                      {l.supplierItemCode}
                    </span>
                  ) : null}
                </td>
                <td className="px-3 py-2 tabular-nums">
                  {l.quantity} {l.uom}
                </td>
                <td className="px-3 py-2 tabular-nums">
                  {l.unitPriceMinor === null
                    ? "—"
                    : formatMinor(l.unitPriceMinor, order.currency, places)}
                </td>
                <td className="px-3 py-2 tabular-nums">{l.requiredDate ?? "—"}</td>
                {order.canRespond ? (
                  <>
                    <td className="px-3 py-2">
                      <input
                        type="number"
                        inputMode="decimal"
                        min={0}
                        max={l.quantity}
                        step="any"
                        aria-label={`Quantity you can send for line ${l.lineNo}`}
                        placeholder={String(l.quantity)}
                        value={edits[l.lineId]?.quantity ?? ""}
                        onChange={(e) => edit(l.lineId, "quantity", e.target.value)}
                        className="h-11 w-24 rounded-md border border-input bg-background px-2"
                      />
                    </td>
                    <td className="px-3 py-2">
                      <input
                        type="date"
                        aria-label={`Date you can send line ${l.lineNo}`}
                        value={edits[l.lineId]?.date ?? ""}
                        onChange={(e) => edit(l.lineId, "date", e.target.value)}
                        className="h-11 rounded-md border border-input bg-background px-2"
                      />
                    </td>
                  </>
                ) : (
                  <td className="px-3 py-2 tabular-nums">
                    {l.confirmedQuantity === null
                      ? "—"
                      : `${l.confirmedQuantity}${l.confirmedDate ? ` by ${l.confirmedDate}` : ""}`}
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {order.canRespond ? (
        <form
          className="mt-6 flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            send.mutate(declining ? "decline" : "confirm");
          }}
        >
          <p className="text-sm text-muted-foreground">
            Leave a line empty to send it as ordered, on the date wanted. Any change waits for the
            buyer to accept it.
          </p>
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium">Your order reference</span>
            <input
              type="text"
              placeholder="SO-1234"
              maxLength={80}
              value={reference}
              onChange={(e) => setReference(e.target.value)}
              className="h-11 rounded-md border border-input bg-background px-2"
            />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            <span className="font-medium">
              {declining ? "Why you cannot take this order" : "A note for the buyer"}
            </span>
            <textarea
              rows={3}
              maxLength={1000}
              required={declining}
              placeholder={declining ? "Discontinued, out of stock until March…" : "Optional"}
              value={note}
              onChange={(e) => setNote(e.target.value)}
              className="rounded-md border border-input bg-background px-2 py-2"
            />
          </label>
          {refused ? (
            <p role="alert" className="text-sm text-destructive">
              {refused}
            </p>
          ) : null}
          <div className="flex flex-wrap gap-3">
            {declining ? (
              <>
                <button
                  type="submit"
                  disabled={send.isPending}
                  className="h-11 rounded-md bg-destructive px-5 text-sm font-medium text-destructive-foreground"
                >
                  Decline the order
                </button>
                <button
                  type="button"
                  onClick={() => setDeclining(false)}
                  className="h-11 rounded-md border border-input px-5 text-sm font-medium"
                >
                  Back
                </button>
              </>
            ) : (
              <>
                <button
                  type="submit"
                  disabled={send.isPending}
                  className="h-11 rounded-md bg-primary px-5 text-sm font-medium text-primary-foreground"
                >
                  Confirm the order
                </button>
                <button
                  type="button"
                  onClick={() => setDeclining(true)}
                  className="h-11 rounded-md border border-input px-5 text-sm font-medium"
                >
                  I cannot take this order
                </button>
              </>
            )}
          </div>
        </form>
      ) : null}

      {order.notices.length > 0 ? <Notices order={order} /> : null}

      {order.canNotify ? <OnItsWay token={token} order={order} /> : null}
    </main>
  );
}

function Notices({ order }: { order: SupplierOrder }) {
  const words: Record<string, string> = {
    notified: "On its way",
    part_received: "Part received",
    received: "Received",
  };
  return (
    <section className="mt-8">
      <h2 className="text-base font-semibold">What you told us is on its way</h2>
      <ul className="mt-2 flex flex-col divide-y divide-border rounded-xl border border-border text-sm">
        {order.notices.map((n) => (
          <li key={n.notice} className="flex flex-wrap gap-x-4 gap-y-1 px-3 py-2">
            <span className="font-medium">{n.notice}</span>
            <span>{words[n.status] ?? n.status}</span>
            {n.expectedArrival ? <span>Arriving {n.expectedArrival}</span> : null}
            {n.carrier ? (
              <span className="text-muted-foreground">
                {n.carrier}
                {n.trackingReference ? ` ${n.trackingReference}` : ""}
              </span>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  );
}

const EMPTY_NOTICE: NoticeForm = {
  shipDate: "",
  expectedArrival: "",
  carrier: "",
  trackingReference: "",
  supplierReference: "",
  note: "",
  quantities: {},
  cartons: [],
};

function OnItsWay({ token, order }: { token: string; order: SupplierOrder }) {
  const queryClient = useQueryClient();
  const [form, setForm] = useState<NoticeForm>(EMPTY_NOTICE);
  const lines = order.lines.filter((l) => l.openToNotify > 0);

  const send = useMutation({
    mutationFn: () => notifyShipment({ data: { token, notice: noticePayload(form) } }),
    onSuccess: (result) => {
      if (result.ok) {
        setForm(EMPTY_NOTICE);
        void queryClient.invalidateQueries({ queryKey: ["supplier_order_by_link", token] });
      }
    },
  });
  const refused = send.data && !send.data.ok ? send.data.message : null;
  const set = (field: Exclude<keyof NoticeForm, "quantities" | "cartons">, value: string) =>
    setForm((f) => ({ ...f, [field]: value }));
  const setCarton = (i: number, change: Partial<NoticeForm["cartons"][number]>) =>
    setForm((f) => ({
      ...f,
      cartons: f.cartons.map((c, j) => (j === i ? { ...c, ...change } : c)),
    }));
  const badLabel = form.cartons.some((c) => {
    const sscc = ssccOf(c.sscc);
    return c.sscc.trim() !== "" && (sscc === null || !ssccIsValid(sscc));
  });

  if (lines.length === 0) {
    return (
      <p className="mt-8 text-sm text-muted-foreground">
        Everything on this order is received or on its way.
      </p>
    );
  }

  return (
    <form
      className="mt-8 flex flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault();
        send.mutate();
      }}
    >
      <div>
        <h2 className="text-base font-semibold">Tell us it&apos;s on its way</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          One notice for each delivery. Give what is in it; leave a line empty if it is not.
        </p>
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Sent on</span>
          <input
            type="date"
            value={form.shipDate}
            onChange={(e) => set("shipDate", e.target.value)}
            className="h-11 rounded-md border border-input bg-background px-2"
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Arrives on</span>
          <input
            type="date"
            required
            value={form.expectedArrival}
            onChange={(e) => set("expectedArrival", e.target.value)}
            className="h-11 rounded-md border border-input bg-background px-2"
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Carrier</span>
          <input
            type="text"
            maxLength={80}
            placeholder="DHL"
            value={form.carrier}
            onChange={(e) => set("carrier", e.target.value)}
            className="h-11 rounded-md border border-input bg-background px-2"
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Tracking number</span>
          <input
            type="text"
            maxLength={120}
            value={form.trackingReference}
            onChange={(e) => set("trackingReference", e.target.value)}
            className="h-11 rounded-md border border-input bg-background px-2"
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="font-medium">Your delivery note number</span>
          <input
            type="text"
            maxLength={80}
            placeholder="DN-1234"
            value={form.supplierReference}
            onChange={(e) => set("supplierReference", e.target.value)}
            className="h-11 rounded-md border border-input bg-background px-2"
          />
        </label>
      </div>

      <div className="w-full overflow-x-auto rounded-xl border border-border">
        <table className="w-full min-w-[28rem] text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted-foreground">
              <th scope="col" className="px-3 py-2 font-medium">
                Line
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Item
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                Still to send
              </th>
              <th scope="col" className="px-3 py-2 font-medium">
                In this delivery
              </th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.lineId} className="border-b border-border/60 last:border-0">
                <td className="px-3 py-2 tabular-nums">{l.lineNo}</td>
                <td className="px-3 py-2">{l.description}</td>
                <td className="px-3 py-2 tabular-nums">
                  {l.openToNotify} {l.uom}
                </td>
                <td className="px-3 py-2">
                  <input
                    type="number"
                    inputMode="decimal"
                    min={0}
                    max={l.openToNotify}
                    step="any"
                    aria-label={`Quantity in this delivery for line ${l.lineNo}`}
                    value={form.quantities[l.lineId] ?? ""}
                    onChange={(e) =>
                      setForm((f) => ({
                        ...f,
                        quantities: { ...f.quantities, [l.lineId]: e.target.value },
                      }))
                    }
                    className="h-11 w-24 rounded-md border border-input bg-background px-2"
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-col gap-3">
        <p className="text-sm text-muted-foreground">
          Optional: if your cartons carry an SSCC label, list each one and what is in it. We receive
          a carton by scanning its label. Together they must hold what the lines say.
        </p>
        {form.cartons.map((c, i) => (
          <fieldset key={i} className="rounded-lg border border-border p-3">
            <legend className="px-1 text-sm font-medium">Carton {i + 1}</legend>
            <label className="flex flex-col gap-1 text-sm">
              <span>SSCC</span>
              <input
                type="text"
                inputMode="numeric"
                maxLength={40}
                placeholder="(00)350123451234567894"
                value={c.sscc}
                onChange={(e) => setCarton(i, { sscc: e.target.value })}
                className="h-11 rounded-md border border-input bg-background px-2"
              />
            </label>
            <div className="mt-2 flex flex-wrap gap-3">
              {lines.map((l) => (
                <label key={l.lineId} className="flex flex-col gap-1 text-sm">
                  <span>Line {l.lineNo}</span>
                  <input
                    type="number"
                    inputMode="decimal"
                    min={0}
                    step="any"
                    value={c.quantities[l.lineId] ?? ""}
                    onChange={(e) =>
                      setCarton(i, { quantities: { ...c.quantities, [l.lineId]: e.target.value } })
                    }
                    className="h-11 w-24 rounded-md border border-input bg-background px-2"
                  />
                </label>
              ))}
            </div>
            <button
              type="button"
              onClick={() =>
                setForm((f) => ({ ...f, cartons: f.cartons.filter((_, j) => j !== i) }))
              }
              className="mt-2 h-11 rounded-md border border-input px-4 text-sm"
            >
              Remove this carton
            </button>
          </fieldset>
        ))}
        <button
          type="button"
          onClick={() =>
            setForm((f) => ({ ...f, cartons: [...f.cartons, { sscc: "", quantities: {} }] }))
          }
          className="h-11 self-start rounded-md border border-input px-4 text-sm font-medium"
        >
          Add a carton
        </button>
        {badLabel ? (
          <p role="alert" className="text-sm text-destructive">
            A carton&apos;s SSCC is eighteen digits ending in its check digit. Check the label.
          </p>
        ) : null}
      </div>

      <label className="flex flex-col gap-1 text-sm">
        <span className="font-medium">A note for goods-in</span>
        <textarea
          rows={2}
          maxLength={1000}
          placeholder="Optional"
          value={form.note}
          onChange={(e) => set("note", e.target.value)}
          className="rounded-md border border-input bg-background px-2 py-2"
        />
      </label>
      {refused ? (
        <p role="alert" className="text-sm text-destructive">
          {refused}
        </p>
      ) : null}
      {send.data?.ok ? (
        <p role="status" className="text-sm">
          Thank you. The buyer has been told it is on its way.
        </p>
      ) : null}
      <button
        type="submit"
        disabled={send.isPending || badLabel}
        className="h-11 self-start rounded-md bg-primary px-5 text-sm font-medium text-primary-foreground"
      >
        Send the notice
      </button>
    </form>
  );
}

function StatusLine({ order }: { order: SupplierOrder }) {
  const words: Record<SupplierOrder["status"], string> = {
    awaiting: order.decisionNote
      ? `The buyer asked you to answer again: ${order.decisionNote}`
      : "Please confirm the order, or tell the buyer what you can send and when.",
    changes_proposed:
      "Thank you. Your changes are with the buyer, who will accept them or ask again. You can still revise them below.",
    confirmed: "This order is confirmed. Reply to the buyer if anything changes.",
    declined: "You declined this order. Reply to the buyer if that changes.",
    withdrawn: "The buyer has cancelled this order.",
  };
  return (
    <p className="mt-4 rounded-lg border border-border bg-card p-3 text-sm" role="status">
      {words[order.status]}
    </p>
  );
}
