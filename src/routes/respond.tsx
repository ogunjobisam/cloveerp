import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { Centred } from "../components/erp/gate";
import { formatMinor, isoMinorUnits } from "../lib/money";
import {
  supplierAnswer,
  tokenFromFragment,
  type LineEdit,
  type SupplierOrder,
} from "../lib/supplier-confirmation";
import { respondToOrder, supplierOrderByLink } from "../lib/supplier-response.functions";

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
    </main>
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
