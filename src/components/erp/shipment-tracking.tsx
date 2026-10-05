import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { shipmentTracking, trackingWords } from "../../lib/carriers/carrier-account";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { weightWords } from "../../lib/inbound-shipments";
import { formatMinor } from "../../lib/money";
import { whenText } from "../../lib/when";
import { ErrorNote } from "./action";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * A shipment's carriage, on its page (20261004965000): its weight, and as its
 * carrier's system knows it, the label the carrier issued, its tracking code
 * and the latest status the carrier reported. And as it was booked (J-66,
 * 20261007060000): the carrier, the service, the cost, when it is expected,
 * and what it carries, since a shipment has no lines of its own to say so.
 * Drawn for a shipment with a carrier booked, a weight, one booked through
 * the organisation's provider, or one with a tracking code.
 */
export function ShipmentTracking({ documentId }: { documentId: string }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "logistics.read");
  const { data, error } = useQuery({
    queryKey: ["erp_shipment_tracking", { p_shipment_document: documentId }],
    queryFn: () => callErp<unknown>("erp_shipment_tracking", { p_shipment_document: documentId }),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  // What was read is kept while a later read fails, with the failure beside
  // it (J-34).
  if (error && data === undefined) return <ErrorNote error={error} />;
  const t = shipmentTracking(data);
  if (!t) return <ErrorNote error={error} />;
  const tracked = t.provider !== null || t.trackingReference !== null;
  if (!tracked && t.weightG === null && t.carrier === null) return <ErrorNote error={error} />;
  const status = trackingWords(t.status);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Carriage")}</h2>
      {t.carrier !== null ? (
        <div className="mt-2 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <span className="text-xs text-muted-foreground">
            {ui("Carrier")} <span className="text-foreground">{t.carrier}</span>
          </span>
          {t.serviceCode ? (
            <span className="text-xs text-muted-foreground">
              {ui("Service")} <span className="font-mono text-foreground">{t.serviceCode}</span>
            </span>
          ) : null}
          {t.costMinor !== null && t.currency ? (
            <span className="text-xs text-muted-foreground">
              {ui("Cost")}{" "}
              <span className="tabular-nums text-foreground">
                {formatMinor(t.costMinor, t.currency)}
              </span>
            </span>
          ) : null}
          {t.expectedArrival ? (
            <span className="text-xs text-muted-foreground">
              {ui("Expected")}{" "}
              <span className="tabular-nums text-foreground">{t.expectedArrival}</span>
            </span>
          ) : null}
        </div>
      ) : null}
      {/* What it carries: a collection its order, an outbound shipment its
          deliveries. */}
      {t.carries.length > 0 ? (
        <div className="mt-2 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <span className="text-xs text-muted-foreground">
            {t.direction === "inbound" ? ui("Order") : ui("Deliveries")}
          </span>
          {t.carries.map((c) => (
            <Link
              key={c.documentId}
              to="/documents/$documentId"
              params={{ documentId: c.documentId }}
              className="text-xs underline underline-offset-2"
            >
              {c.documentNumber}
            </Link>
          ))}
        </div>
      ) : null}
      <div className="mt-2 flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1 text-sm">
        <span className="text-xs text-muted-foreground">
          {ui("Weight")}{" "}
          <span className="tabular-nums text-foreground">
            {t.weightG !== null ? weightWords(t.weightG) : ui("No weight")}
          </span>
        </span>
        {tracked ? <Pill tone={status.tone}>{ui(status.words)}</Pill> : null}
        {t.trackingReference ? (
          <span className="font-mono text-xs">{t.trackingReference}</span>
        ) : null}
        {t.statusAt ? (
          <span className="text-xs tabular-nums text-muted-foreground">{whenText(t.statusAt)}</span>
        ) : null}
        {t.labelRateMinor !== null && t.currency ? (
          <span className="text-xs tabular-nums text-muted-foreground">
            {ui("Label")} {formatMinor(t.labelRateMinor, t.currency)}
          </span>
        ) : null}
        {t.labelUrl ? (
          <a
            href={t.labelUrl}
            target="_blank"
            rel="noreferrer"
            className="text-xs font-medium underline underline-offset-2"
          >
            {ui("Open the label")}
          </a>
        ) : null}
      </div>
      {t.detail ? <p className="mt-1 text-xs text-muted-foreground">{t.detail}</p> : null}
      {error ? (
        <div className="mt-3">
          <ErrorNote error={error} />
        </div>
      ) : null}
    </section>
  );
}
