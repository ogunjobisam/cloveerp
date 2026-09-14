import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import {
  CommercialEmailError,
  INVOICE_PATH,
  composeCommercialEmail,
  describeLine,
  describeTerm,
  formatDay,
  formatMoney,
  paymentBlock,
  type ClaimedCommercialEmail,
} from "./commercial-email.ts";

const ORIGIN = "https://cloveerp.com";

/* The VAT wording as the one function that holds it says it. */
const MIGRATION = readFileSync(
  new URL(
    "../../../supabase/migrations/20260914093000_an_order_form_shows_the_customer_its_price.sql",
    import.meta.url,
  ),
  "utf8",
);
const STATEMENT = "Clove ERP Ltd is not registered for VAT; no VAT is charged.";

function orderForm(over: Record<string, unknown> = {}): ClaimedCommercialEmail {
  return {
    email_id: "11111111-1111-1111-1111-111111111111",
    email_kind: "order_form",
    recipient_address: "dana@okafor.example",
    recipient_name: "Dana Okafor",
    sender_address: "Clove ERP <no-reply@cloveerp.com>",
    reply_address: "sam@cloveerp.com",
    send_key: "clove-order-form-x-1-y",
    payload: {
      kind: "order_form",
      document_number: "CQ-000123",
      quote_version: 1,
      customer_name: "Okafor Foods Ltd",
      recipient_name: "Dana Okafor",
      currency: "GBP",
      lines: [
        {
          line_no: 10,
          item_code: "PLAN-STANDARD",
          description: "Standard plan",
          quantity: 1,
          unit_price_minor: 1314000,
          discount_pct: 10,
          unit_net_minor: 1182600,
          net_minor: 1182600,
          charge: "recurring",
        },
        {
          line_no: 20,
          item_code: "USER-STANDARD",
          description: "Extra full user, Standard",
          quantity: 10,
          unit_price_minor: 58800,
          discount_pct: 5,
          unit_net_minor: 55860,
          net_minor: 558600,
          charge: "recurring",
        },
        {
          line_no: 30,
          item_code: "ONBOARD-GUIDED",
          description: "Guided onboarding",
          quantity: 1,
          unit_price_minor: 250000,
          discount_pct: 0,
          unit_net_minor: 250000,
          net_minor: 250000,
          charge: "one_off",
        },
      ],
      totals: {
        list_minor: 2152000,
        discount_minor: 160800,
        net_minor: 1991200,
        recurring_minor: 1741200,
        one_off_minor: 250000,
      },
      term_kind: "annual",
      term_months: 12,
      valid_until: "2026-10-14",
      price_book: "CLOVE-LIST v1",
      issuer_email: "sam@cloveerp.com",
      ...over,
    },
  };
}

function invoice(over: Record<string, unknown> = {}): ClaimedCommercialEmail {
  return {
    email_id: "22222222-2222-2222-2222-222222222222",
    email_kind: "contract_invoice",
    recipient_address: "accounts@okafor.example",
    recipient_name: "Accounts Team",
    sender_address: "Clove ERP <no-reply@cloveerp.com>",
    reply_address: "sam@cloveerp.com",
    send_key: "clove-contract-invoice-x-1-y",
    payload: {
      kind: "contract_invoice",
      reference: "INV-OKAFOR-202609-001",
      customer_name: "Okafor Foods Ltd",
      supplier_name: "Clove ERP Ltd",
      recipient_name: "Accounts Team",
      currency: "GBP",
      period_start: "2026-09-14",
      period_end: "2026-10-14",
      issued_on: "2026-09-14",
      due_on: "2026-09-28",
      lines: [
        {
          kind: "subscription",
          description: "standard plan, 2026-09-14 to 2026-10-14",
          net_minor: 145100,
        },
        {
          kind: "one_off",
          item_code: "ONBOARD-GUIDED",
          description: "Guided onboarding",
          quantity: 1,
          net_minor: 250000,
        },
      ],
      subscription_minor: 145100,
      overage_minor: 0,
      one_off_minor: 250000,
      recurring_minor: 145100,
      total_minor: 395100,
      tax_statement: STATEMENT,
      payment_details: {
        legal_name: "Example Supplier Ltd",
        registered_address: "1 Example Street, Exampletown",
        company_number: "00000000",
        bank_account_name: "Example Supplier Ltd",
        sort_code: "00-00-00",
        account_number: "00000000",
        payment_reference_guidance: null,
      },
      issuer_email: "sam@cloveerp.com",
      ...over,
    },
  };
}

describe("what a commercial email reads as", () => {
  test("money, dates and terms read as a person in the UK says them", () => {
    expect(formatMoney(1182600, "GBP")).toBe("£11,826.00");
    expect(formatMoney("250000", "GBP")).toBe("£2,500.00");
    expect(formatMoney(null, "GBP")).toBeNull();
    expect(formatMoney(100, "pounds")).toBeNull();
    expect(formatDay("2026-09-28")).toBe("28 September 2026");
    expect(formatDay("2026-09-28T23:30:00+00:00")).toBe("28 September 2026");
    expect(formatDay("soon")).toBeNull();
    expect(describeTerm("annual", 12)).toBe("12 months, billed yearly");
    expect(describeTerm("multi_year", 36)).toBe("3 years, billed yearly");
    expect(describeTerm("monthly", 12)).toBe("Month to month, billed monthly");
    expect(describeTerm("weekly", 1)).toBeNull();
  });

  test("a line says its quantity, price and discount before its net, and a one-off says so", () => {
    expect(
      describeLine(
        { quantity: 10, unit_price_minor: 58800, discount_pct: 5, net_minor: 558600 },
        "GBP",
      ),
    ).toBe("10 × £588.00, 5% off: £5,586.00");
    expect(
      describeLine(
        { quantity: 1, unit_price_minor: 1314000, discount_pct: 10, net_minor: 1182600 },
        "GBP",
      ),
    ).toBe("1 × £13,140.00, 10% off: £11,826.00");
    expect(
      describeLine(
        {
          quantity: 1,
          unit_price_minor: 250000,
          discount_pct: 0,
          net_minor: 250000,
          charge: "one_off",
        },
        "GBP",
      ),
    ).toBe("£2,500.00 (charged once)");
    expect(() => describeLine({ quantity: 1 }, "GBP")).toThrow(CommercialEmailError);
  });
});

describe("an order form email", () => {
  test("names the quote, shows every line's discount and net, the totals, the term and the date", () => {
    const email = composeCommercialEmail(orderForm(), ORIGIN);
    expect(email.subject).toBe("Your order form from Clove ERP: CQ-000123");
    expect(email.text).toContain("Your order form from Clove ERP: CQ-000123");
    expect(email.text).toContain("Hello Dana Okafor,");
    expect(email.text).toContain("Standard plan: 1 × £13,140.00, 10% off: £11,826.00");
    expect(email.text).toContain("Extra full user, Standard: 10 × £588.00, 5% off: £5,586.00");
    expect(email.text).toContain("Guided onboarding: £2,500.00 (charged once)");
    expect(email.text).toContain("Recurring: £17,412.00");
    expect(email.text).toContain("Charged once: £2,500.00");
    expect(email.text).toContain("Total: £19,912.00");
    expect(email.text).toContain("Term: 12 months, billed yearly");
    expect(email.text).toContain("Valid until: 14 October 2026");
    expect(email.html).toContain("CQ-000123");
  });

  test("its button replies to whoever issued it, with the quote in the subject, and offers no sign-in", () => {
    const email = composeCommercialEmail(orderForm(), ORIGIN);
    expect(email.text).toContain(
      "Reply to accept or ask a question: mailto:sam@cloveerp.com?subject=Order%20form%20CQ-000123",
    );
    expect(email.text).not.toContain(INVOICE_PATH);
    expect(email.text).not.toContain("Visit cloveerp.com");
    const noIssuer = composeCommercialEmail(
      { ...orderForm({ issuer_email: "system" }), reply_address: null },
      ORIGIN,
    );
    expect(noIssuer.text).toContain("Visit cloveerp.com: https://cloveerp.com");
  });

  test("never says cost or margin, whatever the payload carries", () => {
    const email = composeCommercialEmail(
      orderForm({ cost_minor: 450000, margin_pct: 62.5 }),
      ORIGIN,
    );
    expect(email.text.toLowerCase()).not.toContain("cost");
    expect(email.text.toLowerCase()).not.toContain("margin");
    expect(email.text).not.toContain("450");
  });

  test("escapes what a customer's name could carry", () => {
    const email = composeCommercialEmail(
      orderForm({ customer_name: "<b>Okafor</b> & Sons" }),
      ORIGIN,
    );
    expect(email.html).not.toContain("<b>Okafor</b>");
    expect(email.html).toContain("&lt;b&gt;Okafor&lt;/b&gt; &amp; Sons");
  });

  test("a payload without a number, lines or a total is refused rather than half-sent", () => {
    expect(() => composeCommercialEmail(orderForm({ document_number: null }), ORIGIN)).toThrow(
      CommercialEmailError,
    );
    expect(() => composeCommercialEmail(orderForm({ lines: [] }), ORIGIN)).toThrow(
      CommercialEmailError,
    );
    expect(() => composeCommercialEmail(orderForm({ totals: {} }), ORIGIN)).toThrow(
      CommercialEmailError,
    );
    expect(() =>
      composeCommercialEmail({ ...orderForm(), payload: "not an object" }, ORIGIN),
    ).toThrow(CommercialEmailError);
  });
});

describe("an invoice email", () => {
  test("says when it is due in its subject and heading, with its lines, total and the VAT statement", () => {
    const email = composeCommercialEmail(invoice(), ORIGIN);
    expect(email.subject).toBe("Invoice INV-OKAFOR-202609-001 is due on 28 September 2026");
    expect(email.text).toContain("Invoice INV-OKAFOR-202609-001 is due on 28 September 2026");
    expect(email.text).toContain(
      "Clove ERP Ltd has issued invoice INV-OKAFOR-202609-001 to Okafor Foods Ltd for £3,951.00.",
    );
    expect(email.text).toContain("Subscription: £1,451.00");
    expect(email.text).toContain("Guided onboarding: £2,500.00 (charged once)");
    expect(email.text).toContain("Total: £3,951.00");
    expect(email.text).toContain("Due: 28 September 2026");
    expect(email.text).toContain(`VAT: ${STATEMENT}`);
    expect(email.text).not.toMatch(/VAT: £|\bVAT \(/);
  });

  test("the VAT statement is the one the database holds, word for word", () => {
    expect(MIGRATION).toContain("' is not registered for VAT; no VAT is charged.'");
    expect(STATEMENT.endsWith(" is not registered for VAT; no VAT is charged.")).toBe(true);
  });

  test("carries the payment details as a block to copy, quoting the invoice's reference", () => {
    const email = composeCommercialEmail(invoice(), ORIGIN);
    expect(email.text).toContain(
      "Please pay by 28 September 2026 into the account below, quoting INV-OKAFOR-202609-001.",
    );
    expect(email.text).toContain("Account name: Example Supplier Ltd");
    expect(email.text).toContain("Sort code: 00-00-00");
    expect(email.text).toContain("Account number: 00000000");
    expect(email.text).toContain("Payment reference: INV-OKAFOR-202609-001");
    expect(email.text).toContain("Example Supplier Ltd, company number 00000000");
  });

  test("without payment details it says they will follow from the accounts team", () => {
    const email = composeCommercialEmail(invoice({ payment_details: null }), ORIGIN);
    expect(email.text).toContain(
      "Please pay by 28 September 2026. Payment details will follow from our accounts team.",
    );
    expect(email.text).not.toContain("Sort code");
    expect(paymentBlock({ bank_account_name: "X", sort_code: "00-00-00" }, "INV-1")).toBeNull();
  });

  test("its button opens the invoice in Clove ERP", () => {
    const email = composeCommercialEmail(invoice(), "https://cloveerp.com/");
    expect(email.text).toContain(
      "View your invoice: https://cloveerp.com/administration/commercial",
    );
  });

  test("an invoice without a due date, a total or a VAT statement is refused", () => {
    for (const broken of [{ due_on: null }, { total_minor: null }, { tax_statement: "" }]) {
      expect(() => composeCommercialEmail(invoice(broken), ORIGIN)).toThrow(CommercialEmailError);
    }
    expect(() =>
      composeCommercialEmail(
        { ...invoice(), payload: { kind: "receipt" }, email_kind: "receipt" },
        ORIGIN,
      ),
    ).toThrow(CommercialEmailError);
  });
});
