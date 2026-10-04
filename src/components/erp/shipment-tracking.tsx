import { useQuery } from "@tanstack/react-query";

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
 * and the latest status the carrier reported. Drawn for a shipment with a
 * weight, one booked through the organisation's provider, or one with a
 * tracking code.
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
  if (!tracked && t.weightG === null) return <ErrorNote error={error} />;
  const status = trackingWords(t.status);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Carriage")}</h2>
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
