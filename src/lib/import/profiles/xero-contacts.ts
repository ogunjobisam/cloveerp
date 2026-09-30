import { countryToIso2, deriveCode, normaliseVat } from "../values";
import { cell, emptyResult, type Column, type Json, type Profile } from "../types";
import { address, rolesFor, xeroTerm } from "./party";

/**
 * Xero: Contacts → Export. One row per contact, headings on the first line,
 * required ones starred ("*ContactName").
 *
 * Each contact is one party_profile row: the party with its identifiers, its
 * postal address as billing and its street address as delivery, its default
 * contact, and its roles. The export does not say whether a contact is a
 * customer or a supplier, so the roles are the default the person chooses on
 * the role step, or their choice per contact.
 *
 * Xero is the source of identity; Unleashed is the source of terms. So Xero's
 * payment terms are staged only when the switch says the organisation has no
 * Unleashed to take them from — loading is additive, and the first terms
 * loaded are the ones that stand.
 */

const col = (key: string, label: string, aliases: string[], required = false): Column => ({
  key,
  label,
  aliases,
  required,
});

const addressColumns = (prefix: "PO" | "SA", key: "po" | "sa"): Column[] => [
  col(`${key}_line1`, `${prefix}AddressLine1`, [
    `${prefix} Address Line 1`,
    `${prefix}AttentionTo`,
  ]),
  col(`${key}_line2`, `${prefix}AddressLine2`, [`${prefix} Address Line 2`]),
  col(`${key}_line3`, `${prefix}AddressLine3`, [`${prefix} Address Line 3`]),
  col(`${key}_line4`, `${prefix}AddressLine4`, [`${prefix} Address Line 4`]),
  col(`${key}_city`, `${prefix}City`, [`${prefix} City`]),
  col(`${key}_region`, `${prefix}Region`, [`${prefix} Region`]),
  col(`${key}_postcode`, `${prefix}PostalCode`, [`${prefix} Postal Code`, `${prefix} Postcode`]),
  col(`${key}_country`, `${prefix}Country`, [`${prefix} Country`]),
];

const COLUMNS: Column[] = [
  col("name", "ContactName", ["Contact Name", "Name"], true),
  col("account_number", "AccountNumber", ["Account Number", "Account No"]),
  col("legal_name", "LegalName", ["Legal Name"]),
  col("tax_number", "TaxNumber", ["VAT Number", "Tax Number", "VAT Registration Number"]),
  col("registration_number", "CompanyNumber", [
    "Company Number",
    "BusinessRegistrationNumber",
    "Registration Number",
  ]),
  ...addressColumns("PO", "po"),
  ...addressColumns("SA", "sa"),
  col("first_name", "FirstName", ["First Name"]),
  col("last_name", "LastName", ["Last Name"]),
  col("email", "EmailAddress", ["Email", "Email Address"]),
  col("phone", "PhoneNumber", ["Phone", "Phone Number"]),
  col("sales_day", "DueDateSalesDay", []),
  col("sales_term", "DueDateSalesTerm", []),
  col("bill_day", "DueDateBillDay", []),
  col("bill_term", "DueDateBillTerm", []),
];

export const xeroContacts: Profile = {
  id: "xero-contacts",
  source: "Xero",
  title: "Contacts",
  hint: "Contacts → All contacts → Export, as CSV.",
  target: { kind: "master", objectType: "party_profile" },
  columns: COLUMNS,
  findsHeaderRow: false,
  transform(records, ctx) {
    const out = emptyResult();
    const taken = new Set<string>();
    const seenNames = new Map<string, number>();
    let termsHeld = 0;

    // Account numbers are codes a person chose; derived codes step round them.
    for (const r of records) {
      const given = cell(r, "account_number").toUpperCase();
      if (given === "") continue;
      if (taken.has(given)) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `AccountNumber ${given} is on more than one contact`,
        });
      }
      taken.add(given);
    }

    for (const r of records) {
      const name = cell(r, "name");
      if (name === "") {
        out.findings.push({ line: r.line, severity: "error", message: "no ContactName" });
        continue;
      }
      const first = seenNames.get(name.toLowerCase());
      if (first !== undefined) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${name} is also on line ${first}; Xero names are unique, so the file has been edited`,
        });
        continue;
      }
      seenNames.set(name.toLowerCase(), r.line);

      const given = cell(r, "account_number").toUpperCase();
      const code = given !== "" ? given : deriveCode(name, taken);
      if (given === "") {
        out.findings.push({
          line: r.line,
          severity: "info",
          message: `no AccountNumber; code ${code} derived from the name`,
        });
      }

      const row: { [key: string]: Json } = { source: "xero", legacy_key: name, code, name };

      const legal = cell(r, "legal_name");
      if (legal !== "") row["legal_name"] = legal;

      const vat = normaliseVat(cell(r, "tax_number"));
      if (vat) {
        row["tax_identifier"] = vat.value;
        if (!vat.wellFormed) {
          out.findings.push({
            line: r.line,
            severity: "warning",
            message: `TaxNumber ${vat.value} is not a UK VAT number in HMRC's form; kept as typed`,
          });
        }
      }

      const reg = cell(r, "registration_number");
      if (reg !== "") row["registration_number"] = reg;

      const countryText = cell(r, "po_country") || cell(r, "sa_country");
      if (countryText !== "") {
        const iso = countryToIso2(countryText);
        if (!iso) {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: `country not recognised: ${countryText}`,
          });
          continue;
        }
        row["country_code"] = iso;
      }

      const addresses: Json[] = [];
      for (const [kind, key] of [
        ["billing", "po"],
        ["delivery", "sa"],
      ] as const) {
        const a = address(
          {
            kind,
            lines: [1, 2, 3, 4].map((n) => cell(r, `${key}_line${n}`)),
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

      const person = [cell(r, "first_name"), cell(r, "last_name")]
        .filter((p) => p !== "")
        .join(" ");
      const email = cell(r, "email");
      const phone = cell(r, "phone");
      if (person !== "" || email !== "") {
        const contact: { [key: string]: Json } = {};
        if (person !== "") contact["name"] = person;
        if (email !== "") contact["email"] = email;
        if (phone !== "") contact["phone"] = phone;
        row["contact"] = contact;
      }

      const roles = rolesFor(name, [], ctx);
      if (roles.length > 0) row["roles"] = roles;

      const terms = [
        {
          role: "customer",
          field: "customer_terms",
          t: xeroTerm(cell(r, "sales_day"), cell(r, "sales_term")),
        },
        {
          role: "supplier",
          field: "supplier_terms",
          t: xeroTerm(cell(r, "bill_day"), cell(r, "bill_term")),
        },
      ] as const;
      for (const { role, field, t } of terms) {
        if (!t) continue;
        if (!ctx.termsFromXero) {
          termsHeld++;
          continue;
        }
        if (!roles.includes(role)) continue;
        row[field] = { payment_terms_code: t.code };
        if (t.note) out.findings.push({ line: r.line, severity: "warning", message: t.note });
      }

      out.rows.push(row);
      out.lines.push(r.line);
      out.partyKeys[name] = code;
      out.parties.push({ line: r.line, key: name, name, roles });
    }

    if (termsHeld > 0) {
      out.findings.push({
        line: null,
        severity: "info",
        message: `${termsHeld} Xero payment term${termsHeld === 1 ? " is" : "s are"} read and not staged: terms come from Unleashed. Switch on "Terms from Xero" if there is no Unleashed.`,
      });
    }
    const roleless = out.parties.filter((p) => p.roles.length === 0).length;
    if (roleless > 0) {
      out.findings.push({
        line: null,
        severity: "warning",
        message: `${roleless} contact${roleless === 1 ? " has" : "s have"} no role yet; choose customer or supplier on the role step, or let the Unleashed lists give them one`,
      });
    }
    return out;
  },
};
