import { describe, expect, test } from "bun:test";

import { formatMinor } from "./money";
import { allocationOutcome, canAllocate, onAccountCredit } from "./on-account";

const gbp = (n: number) => formatMinor(n, "GBP");

/** A row as public.erp_on_account_credits answers it (20260930400000). */
const row = (over: Record<string, unknown> = {}) => ({
  credit_item_id: "c1",
  party_id: "p1",
  party_name: "Acme Retail",
  entity_id: "e1",
  company: "MAIN",
  currency: "GBP",
  kept_on: "2026-09-27",
  credit_minor: 10000,
  left_minor: 10000,
  receipt_id: "r1",
  receipt_number: "RCPT-000001",
  allocatable: true,
  invoices: [
    { document_id: "i1", document_number: "INV-000002", owes_minor: 30000, due_on: "2026-10-27" },
  ],
  ...over,
});

describe("credit on account", () => {
  test("a row the database says the reader may allocate, with an invoice to take it, offers Allocate", () => {
    const credit = onAccountCredit(row());
    expect(credit).toEqual({
      creditItemId: "c1",
      customer: "Acme Retail",
      currency: "GBP",
      leftMinor: 10000,
      allocatable: true,
      invoices: [{ documentId: "i1", number: "INV-000002", owesMinor: 30000 }],
    });
    expect(canAllocate(credit)).toBe(true);
  });

  test("no Allocate where the database says no, where no invoice can take it, or nothing is left", () => {
    expect(canAllocate(onAccountCredit(row({ allocatable: false })))).toBe(false);
    // A flag that is not the boolean true is not a yes.
    expect(canAllocate(onAccountCredit(row({ allocatable: "true" })))).toBe(false);
    expect(canAllocate(onAccountCredit(row({ invoices: [] })))).toBe(false);
    expect(canAllocate(onAccountCredit(row({ invoices: null })))).toBe(false);
    expect(canAllocate(onAccountCredit(row({ left_minor: 0 })))).toBe(false);
    expect(
      canAllocate(
        onAccountCredit(
          row({ invoices: [{ document_id: "i1", document_number: "INV-1", owes_minor: 0 }] }),
        ),
      ),
    ).toBe(false);
  });

  test("a row that is not a credit is nothing", () => {
    expect(onAccountCredit(null)).toBeNull();
    expect(onAccountCredit([])).toBeNull();
    expect(onAccountCredit(row({ credit_item_id: null }))).toBeNull();
    expect(onAccountCredit(row({ left_minor: null }))).toBeNull();
    expect(canAllocate(null)).toBe(false);
  });

  test("an allocation says what it moved, to which invoice, what the invoice owes and what is still on account", () => {
    const answer = {
      credit_item_id: "c1",
      invoice_id: "i1",
      invoice_number: "INV-000002",
      allocated_minor: 10000,
      currency: "GBP",
      credit_left_minor: 0,
      invoice_owes_minor: 20000,
      invoice_state: "part_paid",
      journal_id: "j1",
      receipt_id: "r1",
      receipt_number: "RCPT-000001",
    };
    expect(allocationOutcome(answer)).toEqual({
      message: `${gbp(10000)} of the credit on account allocated to INV-000002, which owes ${gbp(20000)}.`,
      documents: [{ documentId: "i1", number: "INV-000002" }],
    });
    expect(
      allocationOutcome({ ...answer, invoice_owes_minor: 0, credit_left_minor: 2500 })?.message,
    ).toBe(
      `${gbp(10000)} of the credit on account allocated to INV-000002, which is paid. ${gbp(2500)} is still on account.`,
    );
    expect(allocationOutcome(null)).toBeNull();
    expect(allocationOutcome({ allocated_minor: 1 })).toBeNull();
  });
});
