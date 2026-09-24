/**
 * What an invoice must carry by law, as the two doors that set it take it
 * (20260924200000): a company's registration number, registered office and
 * VAT number, and a business partner's address of one kind.
 *
 * The forms have two address lines; the doors take a list, and an empty
 * second line is no line at all.
 */

const trimmed = (values: Record<string, string>, key: string): string | null => {
  const raw = (values[key] ?? "").trim();
  return raw === "" ? null : raw;
};

const lines = (values: Record<string, string>, keys: readonly string[]): string[] | null => {
  const given = keys.map((k) => trimmed(values, k)).filter((l): l is string => l !== null);
  return given.length === 0 ? null : given;
};

/** erp_set_company_invoice_details: what was left empty is left as recorded. */
export const companyInvoiceDetailsArgs = (
  values: Record<string, string>,
): Record<string, unknown> => ({
  p_entity_code: trimmed(values, "p_entity_code"),
  p_registration_number: trimmed(values, "p_registration_number"),
  p_office_lines: lines(values, ["office_line_1", "office_line_2"]),
  p_office_locality: trimmed(values, "p_office_locality"),
  p_office_postcode: trimmed(values, "p_office_postcode"),
  p_office_country_code: trimmed(values, "p_office_country_code"),
  p_vat_number: trimmed(values, "p_vat_number"),
  p_vat_registered_from: trimmed(values, "p_vat_registered_from"),
});

/** erp_set_party_address. */
export const partyAddressArgs = (values: Record<string, string>): Record<string, unknown> => ({
  p_party_id: trimmed(values, "p_party_id"),
  p_address_kind: trimmed(values, "p_address_kind") ?? "billing",
  p_lines: lines(values, ["line_1", "line_2"]) ?? [],
  p_locality: trimmed(values, "p_locality"),
  p_postcode: trimmed(values, "p_postcode"),
  p_country_code: trimmed(values, "p_country_code"),
  p_label: trimmed(values, "p_label"),
});
