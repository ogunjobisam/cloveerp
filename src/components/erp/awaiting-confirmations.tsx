import { Link } from "@tanstack/react-router";

import { useT } from "../../lib/i18n";
import { confirmationWords, type AwaitingOrder } from "../../lib/supplier-confirmation";
import { Prose } from "./page";
import { Pill } from "./panel";

/**
 * Orders waiting on their supplier (20261004990000): those whose supplier
 * proposed changes or declined, which ask something of the buyer, then those
 * still unanswered, longest first, with the ones past the procurement policy's
 * days marked late.
 *
 * One list of the Purchasing screen's "On its way" card, which reads the
 * orders and leaves the list out when there are none.
 */
export function AwaitingConfirmations({ orders }: { orders: AwaitingOrder[] }) {
  const { ui } = useT();

  return (
    <div className="min-w-0 py-4 first:pt-0 last:pb-0">
      <h3 className="text-sm font-medium">{ui("Awaiting confirmation")}</h3>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Sent orders their supplier has not confirmed, or answered with changes or a refusal.")}
      </Prose>
      <ul className="mt-2 flex flex-col divide-y divide-border text-sm">
        {orders.map((o) => {
          const status = confirmationWords(o.status);
          return (
            <li
              key={o.orderId}
              className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 py-2"
            >
              <Link
                to="/documents/$documentId"
                params={{ documentId: o.orderId }}
                className="font-medium underline underline-offset-2"
              >
                {o.order}
              </Link>
              <span className="text-muted-foreground">{o.supplier}</span>
              <Pill tone={status.tone}>{ui(status.words)}</Pill>
              {o.status === "awaiting" ? (
                <span className="text-xs tabular-nums text-muted-foreground">
                  {o.daysWaiting} {ui("days")}
                </span>
              ) : null}
              {o.overdue ? <Pill tone="bad">{ui("Late")}</Pill> : null}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
