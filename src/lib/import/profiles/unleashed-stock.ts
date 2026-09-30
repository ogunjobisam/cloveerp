import {
  addDecimals,
  decimalText,
  multiply,
  parseDecimal,
  parseMinor,
  parseUkDate,
  roundTo,
  type Decimal,
} from "../values";
import { cell, emptyResult, type Column, type Profile } from "../types";
import { gbp, isTotalLabel } from "./common";

/**
 * Unleashed: Stock on Hand enquiry, as at the cutover, exported as CSV.
 *
 * The stock door takes a whole-penny unit cost and values each row at
 * round(quantity × unit cost). Unleashed averages to fractions of a penny, so
 * where the rounded cost moves the value the line says by how much; the exact
 * value arrives with M5 (PR 5). Zero and negative lines are held back and
 * listed: a negative is a clean-up for the customer before cutover.
 * Serialised stock does not come through here at all; it is received.
 */

const COLUMNS: Column[] = [
  { key: "item", label: "Product Code", aliases: ["Product", "Code", "SKU"], required: true },
  {
    key: "site",
    label: "Warehouse",
    aliases: ["Warehouse Code", "Warehouse Name"],
    required: true,
  },
  { key: "bin", label: "Bin", aliases: ["Bin Location", "Location", "Bin Code"], required: false },
  {
    key: "quantity",
    label: "Qty On Hand",
    aliases: ["On Hand", "Quantity", "Quantity On Hand", "QtyOnHand"],
    required: true,
  },
  {
    key: "avg_cost",
    label: "Avg Cost",
    aliases: ["Average Cost", "Avg Land Cost", "Unit Cost"],
    required: true,
  },
  {
    key: "total_cost",
    label: "Total Cost",
    aliases: ["Total Value", "Value", "Stock Value"],
    required: false,
  },
  { key: "batch", label: "Batch", aliases: ["Batch Number", "Batch No", "Lot"], required: false },
  {
    key: "expires_on",
    label: "Expiry Date",
    aliases: ["Expiry", "Expires", "Best Before"],
    required: false,
  },
];

export const unleashedStock: Profile = {
  id: "unleashed-stock",
  source: "Unleashed",
  title: "Stock on hand",
  hint: "Inventory → Stock on Hand, as at the cutover date. Export as CSV.",
  target: { kind: "opening", domain: "stock" },
  columns: COLUMNS,
  findsHeaderRow: true,
  transform(records, ctx) {
    const out = emptyResult();
    const quantities: Decimal[] = [];
    let staged = 0n;

    for (const r of records) {
      const item = cell(r, "item");
      if (item === "" || isTotalLabel(item)) continue;

      const qty = parseDecimal(cell(r, "quantity"));
      const avg = parseDecimal(cell(r, "avg_cost"));
      if (!qty) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `quantity is not a number: ${cell(r, "quantity")}`,
        });
        continue;
      }
      if (!avg) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `Avg Cost is not an amount: ${cell(r, "avg_cost")}`,
        });
        continue;
      }

      // The value Unleashed states, where the file carries it; else quantity × average.
      const printedText = cell(r, "total_cost");
      const printed = printedText === "" ? null : parseMinor(printedText);
      const exact = roundTo(multiply(qty, avg), 2);
      const printedMinor = printed?.ok ? BigInt(printed.minor) : exact;

      if (qty.units <= 0n) {
        out.exclusions.push({
          line: r.line,
          label: `${item} at ${cell(r, "site")}`,
          reason:
            qty.units < 0n
              ? "negative quantity; clear it in Unleashed before cutover"
              : "nothing on hand",
          amountMinor: Number(printedMinor),
          quantity: decimalText(qty),
        });
        continue;
      }

      const site = cell(r, "site");
      if (site === "") {
        out.findings.push({ line: r.line, severity: "error", message: "no warehouse" });
        continue;
      }
      const location = cell(r, "bin") || ctx.defaultLocation.trim();
      if (location === "") {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: "no bin, and no default location given for lines without one",
        });
        continue;
      }

      const unitCost = roundTo(avg, 2);
      if (unitCost < 0n) {
        out.findings.push({ line: r.line, severity: "error", message: "negative average cost" });
        continue;
      }
      const loads = roundTo(multiply(qty, { units: unitCost, scale: 0 }), 0);
      if (loads !== printedMinor) {
        out.findings.push({
          line: r.line,
          severity: "warning",
          message: `loads at ${gbp(loads)} (${gbp(unitCost)} a unit); Unleashed says ${gbp(printedMinor)}. The exact value arrives with M5`,
        });
      }

      const row: Record<string, string | number> = {
        item,
        site,
        location,
        quantity: decimalText(qty),
        unit_cost_minor: Number(unitCost),
      };
      const batch = cell(r, "batch");
      if (batch !== "") row["batch"] = batch;
      const expiryText = cell(r, "expires_on");
      if (expiryText !== "") {
        const iso = parseUkDate(expiryText);
        if (!iso) {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: `expiry is not a date: ${expiryText}`,
          });
          continue;
        }
        row["expires_on"] = iso;
      }

      out.rows.push(row);
      out.lines.push(r.line);
      quantities.push(qty);
      staged += loads;
    }

    out.stagedTotalMinor = Number(staged);
    out.stagedQuantity = decimalText(addDecimals(quantities));
    return out;
  },
};
