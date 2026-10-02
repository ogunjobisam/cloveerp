import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { inboundShipments, weightWords } from "../../lib/inbound-shipments";
import { ErrorNote } from "./action";
import { Prose } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Collections on their way, on the Purchasing screen (20261004955000): the
 * inbound shipments booked for orders we collect, late first, each with its
 * order, supplier, carrier, weight and tracking reference. One leaves the list when
 * the goods it carried are received; receiving them delivers it.
 */
export function InboundShipments() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "procurement.read");
  const { data, error } = useQuery({
    queryKey: ["erp_inbound_shipments"],
    queryFn: () => callErp<unknown>("erp_inbound_shipments", {}),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const shipments = inboundShipments(data);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("On its way")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Collections we booked from suppliers, until their goods are received.")}
      </Prose>
      <ErrorNote error={error} />
      {shipments.length === 0 ? (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui(
            "Nothing is on its way. A collection booked for an order we collect lands here until its goods arrive.",
          )}
        </p>
      ) : (
        <ul className="mt-3 flex flex-col divide-y divide-border text-sm">
          {shipments.map((s) => (
            <li
              key={s.shipmentId}
              className="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 py-2"
            >
              {s.documentId ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: s.documentId }}
                  className="font-medium underline underline-offset-2"
                >
                  {s.number}
                </Link>
              ) : (
                <span className="font-medium">{s.number}</span>
              )}
              {s.orderId ? (
                <Link
                  to="/documents/$documentId"
                  params={{ documentId: s.orderId }}
                  className="text-xs underline underline-offset-2"
                >
                  {s.orderNumber}
                </Link>
              ) : null}
              <span className="text-muted-foreground">{s.supplier}</span>
              <span>{s.carrier}</span>
              {s.weightG !== null ? (
                <span className="text-xs tabular-nums text-muted-foreground">
                  {weightWords(s.weightG)}
                </span>
              ) : (
                <span className="text-xs text-muted-foreground">{ui("No weight")}</span>
              )}
              {s.tracking ? (
                <span className="text-xs text-muted-foreground">
                  {ui("Tracking")} {s.tracking}
                </span>
              ) : null}
              {s.expected ? (
                <span className="tabular-nums text-muted-foreground">
                  {ui("Expected")} {s.expected}
                </span>
              ) : null}
              {s.late ? <Pill tone="bad">{ui("Late")}</Pill> : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
