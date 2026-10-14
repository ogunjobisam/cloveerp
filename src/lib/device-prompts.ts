/**
 * What the scanner asks for at each step, in words. A task's steps are its
 * handler's payload keys (site_id, cost_minor), which are the database's
 * names for what it records, never the screen's: a step whose key had no
 * words here used to show the key itself ("site_id").
 *
 * Each prompt passes through ui() on the screen, so a tenant can rename it;
 * the English here seeds the dictionary row.
 */
export const KEY_WORDS: Record<string, string> = {
  item_id: "Scan the product",
  component_item_id: "Scan the component",
  location_id: "Scan the location",
  to_location_id: "Scan the destination location",
  from_location_id: "Scan the source location",
  site_id: "Scan the site",
  container_id: "Scan the handling unit",
  parent_container_id: "Scan the outer handling unit",
  batch_id: "Scan the batch",
  works_order_id: "Scan the works order",
  task_id: "Scan the task",
  allocation_id: "Scan the pick",
  receipt_id: "Scan the receipt",
  sscc: "Scan the carton",
  order_line_id: "Scan the order line",
  original_document_id: "Scan the original document",
  document_id: "Scan the document",
  party_id: "Scan the supplier",
  shipment_id: "Scan the shipment",
  inspection_id: "Scan the inspection",
  quantity: "How many?",
  completed: "How many completed?",
  scrapped: "How many scrapped?",
  minutes: "How many minutes?",
  reason: "Why?",
  note: "Note",
  status: "New status",
  code: "Code for the new handling unit",
  container_type: "Handling unit type",
  carrier_code: "Carrier",
  service_code: "Service",
  cost_minor: "Carriage cost, in pence or cents",
  reason_code: "Reason code",
  outcome: "Outcome",
  severity: "Severity",
  batch_number: "Batch number",
  characteristic: "Characteristic",
  instrument: "Instrument used",
  numeric_value: "Measured value",
  text_value: "Observed result",
  operation_seq: "Operation number",
  quantity_scrapped: "How many scrapped?",
  scrap_reason: "Why scrapped?",
  disposition: "Decision",
};

/** The words for a step: its own, or the key read as words. */
export function promptFor(key: string): string {
  return KEY_WORDS[key] ?? plainKey(key);
}

/**
 * A key nobody has worded yet still reads as words, never as a column name:
 * an id is something scanned ("pallet_label_id" → "Scan the pallet label"),
 * anything else is its name ("weight_kg" → "Weight kg").
 */
export function plainKey(key: string): string {
  const scanned = /_id$/.test(key);
  const words = key.replace(/_id$/, "").replace(/_+/g, " ").trim();
  if (scanned) return `Scan the ${words}`;
  return words.charAt(0).toUpperCase() + words.slice(1);
}
