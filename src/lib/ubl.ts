export const PEPPOL_BILLING_CUSTOMIZATION_ID =
  "urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0";
export const PEPPOL_BILLING_PROFILE_ID =
  "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0";

export type ElectronicAddress = {
  value: string;
  schemeId: string;
};

export type UblAddress = {
  lines: string[];
  city: string;
  postcode: string;
  countryCode: string;
};

export type UblParty = {
  name: string;
  legalName: string;
  registrationNumber: string;
  registrationSchemeId?: string;
  vatNumber: string;
  endpoint: ElectronicAddress;
  address: UblAddress;
};

export type UblPayment = {
  meansCode: string;
  accountId: string;
  accountName?: string;
  providerId?: string;
  terms?: string;
};

export type UblTax = {
  categoryCode: string;
  rate: string;
  taxableAmount: string;
  taxAmount: string;
  exemptionReason?: string;
};

export type UblLine = {
  id: string;
  quantity: string;
  unitCode: string;
  name: string;
  description?: string;
  itemId?: string;
  itemSchemeId?: string;
  price: string;
  netAmount: string;
  taxCategoryCode: string;
  taxRate: string;
};

export type BillingContract = {
  kind: "sales_invoice" | "credit_note";
  number: string;
  issueDate: string;
  dueDate?: string;
  currency: string;
  buyerReference?: string;
  orderReference?: string;
  precedingInvoiceReference?: string;
  seller: UblParty;
  buyer: UblParty;
  payment?: UblPayment;
  lines: UblLine[];
  taxes: UblTax[];
  totals: {
    lineExtension: string;
    taxExclusive: string;
    taxInclusive: string;
    allowanceTotal?: string;
    chargeTotal?: string;
    payable: string;
  };
};

export type UblValidationFailure = {
  code: string;
  message: string;
  field: string;
  fixPath: "/administration/organisation" | "/master-data/partners" | "/documents";
  lineId?: string;
};

const xml = (value: string) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");

const element = (name: string, value: string | undefined, attributes = "") =>
  value === undefined ? "" : `<${name}${attributes}>${xml(value)}</${name}>`;

function validateParty(role: "seller" | "buyer", party: UblParty): UblValidationFailure[] {
  const fixPath = role === "seller" ? "/administration/organisation" : "/master-data/partners";
  const label = role === "seller" ? "Seller" : "Customer";
  const failures: UblValidationFailure[] = [];
  const required: Array<[string, string, string]> = [
    ["name", party.name, `${label} name`],
    ["legalName", party.legalName, `${label} legal name`],
    ["registrationNumber", party.registrationNumber, `${label} registration number`],
    ["vatNumber", party.vatNumber, `${label} VAT number`],
    ["endpoint.value", party.endpoint.value, `${label} electronic address`],
    ["endpoint.schemeId", party.endpoint.schemeId, `${label} electronic address scheme`],
    ["address.city", party.address.city, `${label} city`],
    ["address.postcode", party.address.postcode, `${label} postcode`],
    ["address.countryCode", party.address.countryCode, `${label} country`],
  ];
  for (const [field, value, description] of required) {
    if (!value.trim()) {
      failures.push({
        code: `CLOVEERP_PEPPOL_MISSING_${role.toUpperCase()}_${field.replaceAll(".", "_").toUpperCase()}`,
        message: `${description} is needed before this electronic document can be issued.`,
        field: `${role}.${field}`,
        fixPath,
      });
    }
  }
  if (!/^[A-Z]{2}$/.test(party.address.countryCode)) {
    failures.push({
      code: `CLOVEERP_PEPPOL_INVALID_${role.toUpperCase()}_COUNTRY`,
      message: `${label} country must use its two-letter country code.`,
      field: `${role}.address.countryCode`,
      fixPath,
    });
  }
  return failures;
}

export function validateBillingContract(contract: BillingContract): UblValidationFailure[] {
  const failures = [...validateParty("seller", contract.seller), ...validateParty("buyer", contract.buyer)];
  if (contract.lines.length === 0) {
    failures.push({
      code: "CLOVEERP_PEPPOL_NO_LINES",
      message: "Add at least one line before issuing this electronic document.",
      field: "lines",
      fixPath: "/documents",
    });
  }
  if (!contract.buyerReference?.trim() && !contract.orderReference?.trim()) {
    failures.push({
      code: "CLOVEERP_PEPPOL_BUYER_REFERENCE_REQUIRED",
      message: "Add a buyer reference or purchase order reference before issuing this electronic document.",
      field: "buyerReference",
      fixPath: "/documents",
    });
  }
  if (contract.kind === "sales_invoice" && !contract.payment) {
    failures.push({
      code: "CLOVEERP_PEPPOL_PAYMENT_DETAILS_REQUIRED",
      message: "Add payment method and account details before issuing this electronic invoice.",
      field: "payment",
      fixPath: "/administration/organisation",
    });
  }
  if (contract.kind === "credit_note" && !contract.precedingInvoiceReference?.trim()) {
    failures.push({
      code: "CLOVEERP_PEPPOL_PRECEDING_INVOICE_REQUIRED",
      message: "Select the original invoice this credit note corrects.",
      field: "precedingInvoiceReference",
      fixPath: "/documents",
    });
  }
  for (const line of contract.lines) {
    if (!line.unitCode.trim()) {
      failures.push({
        code: "CLOVEERP_PEPPOL_LINE_UNIT_REQUIRED",
        message: `Line ${line.id} needs a standard unit of measure.`,
        field: "lines.unitCode",
        fixPath: "/documents",
        lineId: line.id,
      });
    }
    if (!line.taxCategoryCode.trim()) {
      failures.push({
        code: "CLOVEERP_PEPPOL_LINE_TAX_CATEGORY_REQUIRED",
        message: `Line ${line.id} needs a VAT category.`,
        field: "lines.taxCategoryCode",
        fixPath: "/documents",
        lineId: line.id,
      });
    }
  }
  return failures;
}

function address(value: UblAddress) {
  return `<cac:PostalAddress>${value.lines.map((line) => element("cbc:AddressLine", line)).join("")}${element("cbc:CityName", value.city)}${element("cbc:PostalZone", value.postcode)}<cac:Country>${element("cbc:IdentificationCode", value.countryCode)}</cac:Country></cac:PostalAddress>`;
}

function party(name: "AccountingSupplierParty" | "AccountingCustomerParty", value: UblParty) {
  const registrationScheme = value.registrationSchemeId
    ? ` schemeID="${xml(value.registrationSchemeId)}"`
    : "";
  return `<cac:${name}><cac:Party>${element("cbc:EndpointID", value.endpoint.value, ` schemeID="${xml(value.endpoint.schemeId)}"`)}<cac:PartyIdentification>${element("cbc:ID", value.registrationNumber, registrationScheme)}</cac:PartyIdentification><cac:PartyName>${element("cbc:Name", value.name)}</cac:PartyName>${address(value.address)}<cac:PartyTaxScheme>${element("cbc:CompanyID", value.vatNumber)}<cac:TaxScheme>${element("cbc:ID", "VAT")}</cac:TaxScheme></cac:PartyTaxScheme><cac:PartyLegalEntity>${element("cbc:RegistrationName", value.legalName)}${element("cbc:CompanyID", value.registrationNumber, registrationScheme)}</cac:PartyLegalEntity></cac:Party></cac:${name}>`;
}

export function serializeBillingContract(contract: BillingContract): string {
  const failures = validateBillingContract(contract);
  if (failures.length > 0) throw new Error(failures[0]?.message ?? "Electronic document validation failed.");
  const credit = contract.kind === "credit_note";
  const root = credit ? "CreditNote" : "Invoice";
  const namespace = `urn:oasis:names:specification:ubl:schema:xsd:${root}-2`;
  const quantityElement = credit ? "cbc:CreditedQuantity" : "cbc:InvoicedQuantity";
  const lineElement = credit ? "cac:CreditNoteLine" : "cac:InvoiceLine";
  const typeElement = credit ? "cbc:CreditNoteTypeCode" : "cbc:InvoiceTypeCode";
  const typeCode = credit ? "381" : "380";
  const preceding = credit
    ? `<cac:BillingReference><cac:InvoiceDocumentReference>${element("cbc:ID", contract.precedingInvoiceReference)}</cac:InvoiceDocumentReference></cac:BillingReference>`
    : "";
  const payment = contract.payment
    ? `<cac:PaymentMeans>${element("cbc:PaymentMeansCode", contract.payment.meansCode)}<cac:PayeeFinancialAccount>${element("cbc:ID", contract.payment.accountId)}${element("cbc:Name", contract.payment.accountName)}${element("cbc:FinancialInstitutionBranch", contract.payment.providerId)}</cac:PayeeFinancialAccount></cac:PaymentMeans>${element("cbc:Note", contract.payment.terms)}`
    : "";
  const taxes = contract.taxes
    .map((tax) => `<cac:TaxSubtotal>${element("cbc:TaxableAmount", tax.taxableAmount, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:TaxAmount", tax.taxAmount, ` currencyID="${xml(contract.currency)}"`)}<cac:TaxCategory>${element("cbc:ID", tax.categoryCode)}${element("cbc:Percent", tax.rate)}${element("cbc:TaxExemptionReason", tax.exemptionReason)}<cac:TaxScheme>${element("cbc:ID", "VAT")}</cac:TaxScheme></cac:TaxCategory></cac:TaxSubtotal>`)
    .join("");
  const lines = contract.lines
    .map((line) => `<${lineElement}>${element("cbc:ID", line.id)}${element(quantityElement, line.quantity, ` unitCode="${xml(line.unitCode)}"`)}${element("cbc:LineExtensionAmount", line.netAmount, ` currencyID="${xml(contract.currency)}"`)}<cac:Item>${element("cbc:Description", line.description)}${element("cbc:Name", line.name)}${line.itemId ? `<cac:StandardItemIdentification>${element("cbc:ID", line.itemId, line.itemSchemeId ? ` schemeID="${xml(line.itemSchemeId)}"` : "")}</cac:StandardItemIdentification>` : ""}<cac:ClassifiedTaxCategory>${element("cbc:ID", line.taxCategoryCode)}${element("cbc:Percent", line.taxRate)}<cac:TaxScheme>${element("cbc:ID", "VAT")}</cac:TaxScheme></cac:ClassifiedTaxCategory></cac:Item><cac:Price>${element("cbc:PriceAmount", line.price, ` currencyID="${xml(contract.currency)}"`)}</cac:Price></${lineElement}>`)
    .join("");
  return `<?xml version="1.0" encoding="UTF-8"?><${root} xmlns="${namespace}" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">${element("cbc:CustomizationID", PEPPOL_BILLING_CUSTOMIZATION_ID)}${element("cbc:ProfileID", PEPPOL_BILLING_PROFILE_ID)}${element("cbc:ID", contract.number)}${element("cbc:IssueDate", contract.issueDate)}${element("cbc:DueDate", contract.dueDate)}${element(typeElement, typeCode)}${element("cbc:DocumentCurrencyCode", contract.currency)}${element("cbc:BuyerReference", contract.buyerReference)}${contract.orderReference ? `<cac:OrderReference>${element("cbc:ID", contract.orderReference)}</cac:OrderReference>` : ""}${preceding}${party("AccountingSupplierParty", contract.seller)}${party("AccountingCustomerParty", contract.buyer)}${payment}<cac:TaxTotal>${element("cbc:TaxAmount", contract.taxes.reduce((sum, tax) => sum + Number(tax.taxAmount), 0).toFixed(2), ` currencyID="${xml(contract.currency)}"`)}${taxes}</cac:TaxTotal><cac:LegalMonetaryTotal>${element("cbc:LineExtensionAmount", contract.totals.lineExtension, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:TaxExclusiveAmount", contract.totals.taxExclusive, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:TaxInclusiveAmount", contract.totals.taxInclusive, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:AllowanceTotalAmount", contract.totals.allowanceTotal, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:ChargeTotalAmount", contract.totals.chargeTotal, ` currencyID="${xml(contract.currency)}"`)}${element("cbc:PayableAmount", contract.totals.payable, ` currencyID="${xml(contract.currency)}"`)}</cac:LegalMonetaryTotal>${lines}</${root}>`;
}