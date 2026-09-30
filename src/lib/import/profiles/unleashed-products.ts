import { cell, emptyResult, type Column, type Profile } from "../types";
import { deferredColumns, isTruthy } from "./common";

/**
 * Unleashed: Inventory → Products → Export.
 *
 * Today's item door takes the code, name, description, group and lifecycle.
 * Units, tracking flags, barcode, weight, prices, the default supplier and the
 * reorder policy are read and reported here, and arrive with the item extras
 * (PR 4). Unleashed carries no VAT class, so every product takes the
 * organisation's default and the list is there for the accountant to confirm
 * the zero-rated lines.
 */

const col = (key: string, label: string, aliases: string[], required = false): Column => ({
  key,
  label,
  aliases,
  required,
});

const DEFERRED: Column[] = [
  col("uom", "Unit Of Measure", ["UOM", "Unit"]),
  col("purchase_uom", "Default Purchases Unit Of Measure", ["Purchase Unit Of Measure"]),
  col("batch", "Is Batch Tracked", ["Batch Tracked"]),
  col("serial", "Is Serialized", ["Serialized", "Is Serialised"]),
  col("barcode", "Barcode", ["EAN", "GTIN"]),
  col("weight", "Weight", []),
  col("purchase_price", "Default Purchase Price", ["Purchase Price"]),
  col("sell_price", "Default Sell Price", ["Sell Price"]),
  col("supplier", "Supplier", ["Supplier Code", "Default Supplier"]),
  col("min_stock", "Min Stock Alert Level", ["Min Stock"]),
  col("max_stock", "Max Stock Alert Level", ["Max Stock"]),
  col("min_order", "Minimum Order Quantity", ["Min Order Qty"]),
  col("sub_group", "Product Sub Group", ["Sub Group"]),
];

const COLUMNS: Column[] = [
  col("code", "Product Code", ["Code", "SKU"], true),
  col("description", "Product Description", ["Description", "Name"], true),
  col("group", "Product Group", ["Group"]),
  col("obsolete", "Obsolete", ["Is Obsolete"]),
  ...DEFERRED,
];

export const unleashedProducts: Profile = {
  id: "unleashed-products",
  source: "Unleashed",
  title: "Products",
  hint: "Inventory → Products → Export, as CSV.",
  target: { kind: "master", objectType: "item" },
  columns: COLUMNS,
  findsHeaderRow: false,
  transform(records) {
    const out = emptyResult();
    const seen = new Map<string, number>();

    for (const r of records) {
      const code = cell(r, "code");
      const description = cell(r, "description");
      if (code === "") {
        out.findings.push({ line: r.line, severity: "error", message: "no Product Code" });
        continue;
      }
      const earlier = seen.get(code.toUpperCase());
      if (earlier !== undefined) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${code} is also on line ${earlier}`,
        });
        continue;
      }
      seen.set(code.toUpperCase(), r.line);
      if (description === "") {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${code} has no description`,
        });
        continue;
      }

      const row: Record<string, string> = { code, name: description, description };
      const group = cell(r, "group");
      if (group !== "") row["item_group"] = group;
      if (isTruthy(cell(r, "obsolete"))) row["lifecycle"] = "discontinued";

      out.rows.push(row);
      out.lines.push(r.line);
    }

    if (out.rows.length > 0) {
      out.findings.push({
        line: null,
        severity: "warning",
        message: `Unleashed carries no VAT class: all ${out.rows.length} products take the default. Have the accountant confirm any zero-rated lines.`,
      });
    }
    out.deferred = deferredColumns(records, DEFERRED, "arrives with the item extras import");
    return out;
  },
};
