/**
 * Collections on their way (20261004945000), as public.erp_inbound_shipments
 * answers them: an inbound shipment booked for an order we collect, from
 * whom, with which carrier, expected when, and whether it is late. It leaves
 * the list when the goods it carried are received.
 */

export type InboundShipment = {
  shipmentId: string;
  documentId: string | null;
  number: string;
  orderId: string | null;
  orderNumber: string;
  supplier: string;
  carrier: string;
  tracking: string | null;
  expected: string | null;
  late: boolean;
  /** Grams, as weighed or as its items weigh; null when nothing says. */
  weightG: number | null;
};

type Row = Record<string, unknown>;

const asRecord = (v: unknown): Row | null =>
  typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Row) : null;

const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** A weight in grams, from the number or numeric string the database answers. */
const grams = (v: unknown): number | null => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) && n > 0 ? n : null;
};

/** A weight as a person reads it: grams under a kilogram, else kilograms to a tenth. */
export function weightWords(grams: number): string {
  if (grams < 1000) return `${Math.round(grams)} g`;
  const kg = Math.round(grams / 100) / 10;
  return `${kg.toLocaleString("en-GB", { maximumFractionDigits: 1 })} kg`;
}

/** One row of erp_inbound_shipments, or null when it is not one. */
export function inboundShipment(row: unknown): InboundShipment | null {
  const r = asRecord(row);
  if (!r) return null;
  const shipmentId = text(r["shipment_id"]);
  if (shipmentId === null) return null;
  return {
    shipmentId,
    documentId: text(r["document_id"]),
    number: text(r["document_number"]) ?? "",
    orderId: text(r["order_id"]),
    orderNumber: text(r["order_number"]) ?? "",
    supplier: text(r["supplier"]) ?? "the supplier",
    carrier: text(r["carrier"]) ?? "",
    tracking: text(r["tracking_reference"]),
    expected: text(r["expected_arrival"]),
    late: r["late"] === true,
    weightG: grams(r["weight_g"]),
  };
}

/** Every row of the answer that is one, late first as the database ordered them. */
export function inboundShipments(result: unknown): InboundShipment[] {
  return (Array.isArray(result) ? result : [])
    .map(inboundShipment)
    .filter((s): s is InboundShipment => s !== null);
}
