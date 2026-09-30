import { countryToIso2, deriveCode, normaliseVat } from "../values";
import { cell, emptyResult, type Column, type Profile } from "../types";
import { deferredColumns } from "./common";

/**
 * Xero: Contacts → Export. One row per contact, headings on the first line,
 * required ones starred ("*ContactName").
 *
 * Today's party door takes the code, the name, the legal name, the VAT and
 * company numbers and a country. Addresses, the default contact and payment
 * terms are read and reported here, and arrive with the party_profile object
 * (PR 3); roles are not in the export at all and come from the ledgers.
 */

const col = (key: string, label: string, aliases: string[], required = false): Column => ({
  key,
  label,
  aliases,
  required,
});

const ADDRESS = [
  "AddressLine1",
  "AddressLine2",
  "AddressLine3",
  "AddressLine4",
  "City",
  "Region",
  "PostalCode",
];

const DEFERRED: Column[] = [
  ...ADDRESS.map((a) => col(`po_${a}`, `PO${a}`, [`PO${a}`, `POAttention${a}`])),
  ...ADDRESS.map((a) => col(`sa_${a}`, `SA${a}`, [`SA${a}`])),
  col("first_name", "FirstName", ["First Name"]),
  col("last_name", "LastName", ["Last Name"]),
  col("email", "EmailAddress", ["Email", "Email Address"]),
  col("phone", "PhoneNumber", ["Phone", "Phone Number"]),
  col("sales_day", "DueDateSalesDay", []),
  col("sales_term", "DueDateSalesTerm", []),
  col("bill_day", "DueDateBillDay", []),
  col("bill_term", "DueDateBillTerm", []),
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
  col("po_country", "POCountry", ["PO Country"]),
  col("sa_country", "SACountry", ["SA Country"]),
  ...DEFERRED,
];

export const xeroContacts: Profile = {
  id: "xero-contacts",
  source: "Xero",
  title: "Contacts",
  hint: "Contacts → All contacts → Export, as CSV.",
  target: { kind: "master", objectType: "party" },
  columns: COLUMNS,
  findsHeaderRow: false,
  transform(records) {
    const out = emptyResult();
    const taken = new Set<string>();
    const seenNames = new Map<string, number>();

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
      const key = name.toLowerCase();
      const first = seenNames.get(key);
      if (first !== undefined) {
        out.findings.push({
          line: r.line,
          severity: "error",
          message: `${name} is also on line ${first}; Xero names are unique, so the file has been edited`,
        });
        continue;
      }
      seenNames.set(key, r.line);

      const given = cell(r, "account_number").toUpperCase();
      const code = given !== "" ? given : deriveCode(name, taken);
      if (given === "") {
        out.findings.push({
          line: r.line,
          severity: "info",
          message: `no AccountNumber; code ${code} derived from the name`,
        });
      }

      const row: Record<string, string> = { code, name };
      let refused = false;

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
        if (iso) row["country_code"] = iso;
        else {
          out.findings.push({
            line: r.line,
            severity: "error",
            message: `country not recognised: ${countryText}`,
          });
          refused = true;
        }
      }

      if (refused) continue;
      out.rows.push(row);
      out.lines.push(r.line);
      out.partyKeys[name] = code;
    }

    out.deferred = deferredColumns(records, DEFERRED, "arrives with the party profile import");
    return out;
  },
};
