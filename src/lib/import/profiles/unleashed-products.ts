import { decimalText, multiply, parseDecimal, roundTo, type Decimal } from "../values";
import { cell, emptyResult, type Column, type Json, type Profile } from "../types";
import { gbp, isTruthy } from "./common";

/**
 * Unleashed: Inventory → Products → Export.
 *
 * Each product is one item_profile row: the item in its stock unit, its
 * purchase unit, batch, serial and expiry tracking, a primary barcode, its
 * weight in grams, a purchase price and its default sell price, its default
 * supplier, and its stock alert levels at the warehouse chosen for them.
 *
 * What is read and not loaded, and why:
 *   - Sell Price Tier 1–10. Pricing does not choose between price lists yet,
 *     so a second sales price would make a line's price arbitrary.
 *   - Fractions of a penny. Pricing does not read a price per N units, so a
 *     price is loaded per unit in whole pence and the line says what it was.
 *   - VAT class. Unleashed carries none; every product takes the default and
 *     the accountant confirms the zero-rated lines.
 */

const col = (key: string, label: string, aliases: string[], required = false): Column => ({
  key,
  label,
  aliases,
  required,
});

const TIERS: Column[] = Array.from({ length: 10 }, (_, i) =>
  col(`tier_${i + 1}`, `Sell Price Tier ${i + 1}`, [`SellPriceTier${i + 1}`, `Tier ${i + 1}`]),
);

const COLUMNS: Column[] = [
  col("code", "Product Code", ["Code", "SKU"], true),
  col("description", "Product Description", ["Description", "Name"], true),
  col("group", "Product Group", ["Group"]),
  col("sub_group", "Product Sub Group", ["Sub Group"]),
  col("uom", "Unit Of Measure", ["UOM", "Unit"]),
  col("purchase_uom", "Default Purchases Unit Of Measure", ["Purchase Unit Of Measure"]),
  col("batch", "Is Batch Tracked", ["Batch Tracked"]),
  col("serial", "Is Serialized", ["Serialized", "Is Serialised"]),
  col("barcode", "Barcode", ["EAN", "GTIN"]),
  col("weight", "Weight", []),
  col("purchase_price", "Default Purchase Price", ["Purchase Price"]),
  col("sell_price", "Default Sell Price", ["Sell Price"]),
  col("supplier", "Supplier", ["Supplier Code", "Default Supplier"]),
  col("supplier_item_code", "Supplier Product Code", ["Supplier Code For Product"]),
  col("min_stock", "Min Stock Alert Level", ["Min Stock"]),
  col("max_stock", "Max Stock Alert Level", ["Max Stock"]),
  col("min_order", "Minimum Order Quantity", ["Min Order Qty"]),
  col("obsolete", "Obsolete", ["Is Obsolete"]),
  ...TIERS,
];

const QUANTITY = /^\d+(\.\d+)?$/;

/** A price in whole pence, and what it was where that is not the same. */
function penny(text: string): { minor: number; was: Decimal } | null {
  const d = parseDecimal(text);
  if (!d || d.units < 0n) return null;
  return { minor: Number(roundTo(d, 2)), was: d };
}

export const unleashedProducts: Profile = {
  id: "unleashed-products",
  source: "Unleashed",
  title: "Products",
  hint: "Inventory → Products → Export, as CSV.",
  target: { kind: "master", objectType: "item_profile" },
  columns: COLUMNS,
  findsHeaderRow: false,
  transform(records, ctx) {
    const out = emptyResult();
    const seen = new Map<string, number>();
    let tiers = 0;
    let noSite = 0;

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
      const uom = cell(r, "uom").toUpperCase();
      if (uom === "") {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${code} has no Unit Of Measure`,
        });
        continue;
      }

      const row: { [key: string]: Json } = {
        source: "unleashed",
        code,
        name: description,
        description,
        stock_uom: uom,
      };
      const group = cell(r, "group");
      if (group !== "") row["item_group"] = group;
      if (isTruthy(cell(r, "obsolete"))) row["lifecycle"] = "discontinued";
      const buy = cell(r, "purchase_uom").toUpperCase();
      if (buy !== "" && buy !== uom) row["purchase_uom"] = buy;
      if (isTruthy(cell(r, "batch"))) row["is_batch_controlled"] = true;
      if (isTruthy(cell(r, "serial"))) row["is_serial_controlled"] = true;
      const barcode = cell(r, "barcode");
      if (barcode !== "") row["barcode"] = barcode;

      const weightText = cell(r, "weight");
      if (weightText !== "") {
        const w = parseDecimal(weightText);
        if (w && w.units >= 0n) {
          const grams = ctx.weightUnit === "kg" ? multiply(w, { units: 1000n, scale: 0 }) : w;
          if (grams.units > 0n) row["gross_weight_g"] = decimalText(grams);
        } else {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `weight "${weightText}" is not a number, so it is left out`,
          });
        }
      }

      for (const [key, field, label] of [
        ["purchase_price", "purchase_price", "purchase price"],
        ["sell_price", "sales_price", "sell price"],
      ] as const) {
        const text = cell(r, key);
        if (text === "") continue;
        const p = penny(text);
        if (!p) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `${label} "${text}" is not an amount, so it is left out`,
          });
          continue;
        }
        row[field] = { amount_minor: p.minor };
        if (p.was.scale > 2 && BigInt(p.minor) * 10n ** BigInt(p.was.scale - 2) !== p.was.units) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `${label} ${text} loads as ${gbp(p.minor)} a unit: prices are per unit in whole pence`,
          });
        }
      }

      const supplierText = cell(r, "supplier");
      if (supplierText !== "") {
        const party = ctx.partyCode(supplierText);
        if (!party.known) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `supplier ${supplierText} is not in a loaded supplier or contacts file, so the supplier is left off`,
          });
        } else {
          const supplier: { [key: string]: Json } = { party: party.code };
          const sic = cell(r, "supplier_item_code");
          if (sic !== "") supplier["supplier_item_code"] = sic;
          const moq = cell(r, "min_order");
          if (QUANTITY.test(moq) && Number(moq) > 0) supplier["min_order_quantity"] = moq;
          row["supplier"] = supplier;
        }
      }

      const levels: { [key: string]: Json } = {};
      for (const [key, field] of [
        ["min_stock", "reorder_point"],
        ["max_stock", "order_up_to"],
        ["min_order", "min_order_quantity"],
      ] as const) {
        const v = cell(r, key);
        if (QUANTITY.test(v) && Number(v) > 0) levels[field] = v;
      }
      if (Object.keys(levels).length > 0) {
        if (ctx.reorderSite.trim() === "") noSite++;
        else row["sites"] = [{ site: ctx.reorderSite.trim().toUpperCase(), ...levels }];
      }

      if (TIERS.some((t) => cell(r, t.key) !== "")) tiers++;

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
    if (tiers > 0) {
      out.findings.push({
        line: null,
        severity: "info",
        message: `${tiers} product${tiers === 1 ? " has" : "s have"} sell price tiers, read and not loaded: pricing does not choose between price lists yet, so only the default sell price loads.`,
      });
    }
    if (noSite > 0) {
      out.findings.push({
        line: null,
        severity: "warning",
        message: `${noSite} product${noSite === 1 ? " has" : "s have"} stock alert levels and no warehouse is chosen for them, so they are left out.`,
      });
    }
    return out;
  },
};
