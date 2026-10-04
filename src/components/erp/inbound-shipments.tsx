import { Link } from "@tanstack/react-router";

import { useT } from "../../lib/i18n";
import { weightWords, type InboundShipment } from "../../lib/inbound-shipments";
import { Prose } from "./page";
import { Pill } from "./panel";

/**
 * Collections on their way (20261004955000): the inbound shipments booked for
 * orders we collect, late first, each with its order, supplier, carrier, weight
 * and tracking reference. One leaves the list when the goods it carried are
 * received; receiving them delivers it.
 *
 * One list of the Purchasing screen's "On its way" card, which reads the
 * shipments and leaves the list out when there are none.
 */
export function InboundShipments({ shipments }: { shipments: InboundShipment[] }) {
  const { ui } = useT();

  return (
    <div className="min-w-0 py-4 first:pt-0 last:pb-0">
      <h3 className="text-sm font-medium">{ui("We collect")}</h3>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui("Collections we booked from suppliers, until their goods are received.")}
      </Prose>
      <ul className="mt-2 flex flex-col divide-y divide-border text-sm">
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
    </div>
  );
}
