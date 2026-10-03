import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { awaitingOrders, confirmationWords } from "../../lib/supplier-confirmation";
import { ErrorNote } from "./action";
import { Prose } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Orders waiting on their supplier, on the Purchasing screen (20261004990000):
 * those whose supplier proposed changes or declined, which ask something of
 * the buyer, then those still unanswered, longest first, with the ones past
 * the procurement policy's days marked late.
 */
export function AwaitingConfirmations() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_awaiting_confirmations"],
    queryFn: () => callErp<unknown>("erp_awaiting_confirmations", {}),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const orders = awaitingOrders(data);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Awaiting confirmation")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Sent orders their supplier has not confirmed, or answered with changes or a refusal.")}
      </Prose>
      <ErrorNote error={error} />
      {orders.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui("Every sent order has its supplier's answer.")}
        </p>
      ) : (
        <ul className="mt-3 flex flex-col divide-y divide-border text-sm">
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
      )}
    </section>
  );
}
