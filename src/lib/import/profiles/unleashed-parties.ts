import { parseMinor } from "../values";
import { cell, emptyResult, type Column, type Json, type PartyRole, type Profile } from "../types";
import { address, rolesFor, unleashedTerm } from "./party";

/**
 * Unleashed: Customers → Export and Suppliers → Export.
 *
 * Unleashed is the source of roles and terms. Each customer or supplier is one
 * party_profile row giving the role, the currency and payment term, and — for
 * a customer — the credit limit, with the addresses and contact where the party
 * is new. A party Xero's contacts already loaded is found by its name through
 * the crosswalk and keeps its Xero code, so the two systems land on one party;
 * one Xero never named is created under its Unleashed code.
 *
 * The headings here are Unleashed's documented export headings, not yet
 * confirmed against a real export.
 */

const col = (key: string, label: string, aliases: string[], required = false): Column => ({
  key,
  label,
  aliases,
  required,
});

function partyProfile(id: string, title: string, hint: string, role: PartyRole): Profile {
  const noun = role === "customer" ? "Customer" : "Supplier";
  const columns: Column[] = [
    col("code", `${noun} Code`, [`${noun}Code`, "Code"], true),
    col("name", `${noun} Name`, [`${noun}Name`, "Name"], true),
    col("currency", "Currency", ["Currency Code", "CurrencyCode"]),
    col("terms", "Payment Terms", ["PaymentTerms", "Payment Term"]),
    col("credit_limit", "Credit Limit", ["CreditLimit"]),
    col("tax_number", "GST/VAT Number", ["Tax Number", "VAT Number", "GSTVATNumber"]),
    col("email", "Email", ["Email Address"]),
    col("phone", "Phone", ["Phone Number", "Office Phone"]),
    col("contact_first", "Contact First Name", ["First Name"]),
    col("contact_last", "Contact Last Name", ["Last Name"]),
    col("postal_line1", "Postal Address Line 1", ["Postal Address Line1", "Address Line 1"]),
    col("postal_line2", "Postal Address Line 2", ["Postal Address Line2", "Address Line 2"]),
    col("postal_city", "Postal City", ["Postal Suburb", "City"]),
    col("postal_region", "Postal Region", ["Postal State", "Region"]),
    col("postal_postcode", "Postal Post Code", ["Postal Postcode", "Post Code", "Postcode"]),
    col("postal_country", "Postal Country", ["Country"]),
    col("delivery_line1", "Delivery Address Line 1", ["Delivery Address Line1"]),
    col("delivery_line2", "Delivery Address Line 2", ["Delivery Address Line2"]),
    col("delivery_city", "Delivery City", ["Delivery Suburb"]),
    col("delivery_region", "Delivery Region", ["Delivery State"]),
    col("delivery_postcode", "Delivery Post Code", ["Delivery Postcode"]),
    col("delivery_country", "Delivery Country", []),
    col("obsolete", "Obsolete", ["Is Obsolete"]),
  ];
  const field = role === "customer" ? "customer_terms" : "supplier_terms";

  return {
    id,
    source: "Unleashed",
    title,
    hint,
    target: { kind: "master", objectType: "party_profile" },
    columns,
    findsHeaderRow: false,
    transform(records, ctx) {
      const out = emptyResult();
      const seen = new Map<string, number>();

      for (const r of records) {
        const legacy = cell(r, "code");
        const name = cell(r, "name");
        if (legacy === "" || name === "") {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: `no ${noun.toLowerCase()} code or name`,
          });
          continue;
        }
        const earlier = seen.get(legacy.toUpperCase());
        if (earlier !== undefined) {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: `${legacy} is also on line ${earlier}`,
          });
          continue;
        }
        seen.set(legacy.toUpperCase(), r.line);
        if (/^(y|yes|true|1)$/i.test(cell(r, "obsolete"))) {
          out.findings.push({
            line: r.line,
            severity: "info",
            message: `skipped: ${legacy} is obsolete in Unleashed`,
          });
          continue;
        }

        // The party Xero already loaded, if Xero named one this way.
        const fromXero = ctx.partyCode(name);
        const code = fromXero.known ? fromXero.code : legacy.toUpperCase();
        if (fromXero.known && fromXero.code !== legacy.toUpperCase()) {
          out.findings.push({
            line: r.line,
            severity: "info",
            message: `${legacy} is ${fromXero.code} from Xero's contacts; it keeps that code`,
          });
        }

        const row: { [key: string]: Json } = {
          source: "unleashed",
          legacy_key: legacy,
          code,
          name,
        };
        const roles = rolesFor(legacy, [role], ctx);
        if (roles.length > 0) row["roles"] = roles;

        const terms: { [key: string]: Json } = {};
        const currency = cell(r, "currency").toUpperCase();
        if (/^[A-Z]{3}$/.test(currency)) terms["currency"] = currency;
        else if (currency !== "") {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `currency "${currency}" is not a code, so it is left out`,
          });
        }
        const termText = cell(r, "terms");
        const t = unleashedTerm(termText);
        if (t) {
          terms["payment_terms_code"] = t.code;
          if (t.note) out.findings.push({ line: r.line, severity: "warning", message: t.note });
        } else if (termText !== "") {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `payment term "${termText}" is not one Clove can read; set it on the party`,
          });
        }
        const limitText = cell(r, "credit_limit");
        if (role === "customer" && limitText !== "") {
          const limit = parseMinor(limitText);
          if (limit.ok && limit.minor > 0) terms["credit_limit_minor"] = limit.minor;
          else if (!limit.ok) {
            out.findings.push({
              line: r.line,
              severity: "warning",
              message: `credit limit "${limitText}" is not an amount, so it is left out`,
            });
          }
        }
        if (Object.keys(terms).length > 0 && roles.includes(role)) row[field] = terms;

        const addresses: Json[] = [];
        for (const [kind, key] of [
          ["billing", "postal"],
          ["delivery", "delivery"],
        ] as const) {
          const a = address(
            {
              kind,
              lines: [cell(r, `${key}_line1`), cell(r, `${key}_line2`)],
              locality: cell(r, `${key}_city`),
              region: cell(r, `${key}_region`),
              postcode: cell(r, `${key}_postcode`),
              country: cell(r, `${key}_country`),
            },
            r.line,
            out.findings,
          );
          if (a) addresses.push(a);
        }
        if (addresses.length > 0) row["addresses"] = addresses;

        const person = [cell(r, "contact_first"), cell(r, "contact_last")]
          .filter((p) => p !== "")
          .join(" ");
        const email = cell(r, "email");
        if (person !== "" || email !== "") {
          const contact: { [key: string]: Json } = {};
          if (person !== "") contact["name"] = person;
          if (email !== "") contact["email"] = email;
          if (cell(r, "phone") !== "") contact["phone"] = cell(r, "phone");
          row["contact"] = contact;
        }

        out.rows.push(row);
        out.lines.push(r.line);
        out.partyKeys[name] = code;
        out.parties.push({ line: r.line, key: legacy, name, roles });
      }
      return out;
    },
  };
}

export const unleashedCustomers = partyProfile(
  "unleashed-customers",
  "Customers",
  "Customers → View Customers → Export, as CSV.",
  "customer",
);

export const unleashedSuppliers = partyProfile(
  "unleashed-suppliers",
  "Suppliers",
  "Suppliers → View Suppliers → Export, as CSV.",
  "supplier",
);
