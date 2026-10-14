import { describe, expect, test } from "bun:test";
import { KEY_WORDS, plainKey, promptFor } from "./device-prompts";

// Every key a device task asks for on the day this was written
// (erp_ref.device_task_handler.arguments). A new task's key that is not here
// still reads as words through plainKey(); add its own words when it lands.
const TASK_KEYS = [
  "allocation_id",
  "batch_id",
  "batch_number",
  "carrier_code",
  "characteristic",
  "code",
  "completed",
  "component_item_id",
  "container_id",
  "container_type",
  "cost_minor",
  "disposition",
  "document_id",
  "inspection_id",
  "instrument",
  "item_id",
  "location_id",
  "minutes",
  "note",
  "numeric_value",
  "operation_seq",
  "order_line_id",
  "original_document_id",
  "outcome",
  "parent_container_id",
  "party_id",
  "quantity",
  "reason",
  "reason_code",
  "receipt_id",
  "scrapped",
  "service_code",
  "severity",
  "shipment_id",
  "site_id",
  "sscc",
  "status",
  "task_id",
  "text_value",
  "to_location_id",
  "works_order_id",
];

describe("the scanner's prompts", () => {
  test("every key a task asks for has words of its own", () => {
    expect(TASK_KEYS.filter((k) => !(k in KEY_WORDS))).toEqual([]);
  });

  test("no prompt reads as a column name", () => {
    for (const k of [...TASK_KEYS, ...Object.keys(KEY_WORDS)]) {
      expect(promptFor(k)).not.toMatch(/_/);
    }
  });

  test("the site is asked for in words, not as site_id", () => {
    expect(promptFor("site_id")).toBe("Scan the site");
  });

  test("a key with no words yet still reads as words", () => {
    expect(plainKey("pallet_label_id")).toBe("Scan the pallet label");
    expect(plainKey("weight_kg")).toBe("Weight kg");
    expect(promptFor("tare__weight")).toBe("Tare weight");
  });
});
