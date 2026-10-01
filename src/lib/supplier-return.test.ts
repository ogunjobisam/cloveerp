import { describe, expect, test } from "bun:test";

import { formatMinor } from "./money";
import {
  canAllocateCredit,
  canReceiveReplacement,
  supplierCredit,
  supplierCreditOutcome,
  supplierReturn,
} from "./supplier-return";

const gbp = (n: number) => formatMinor(n, "GBP");

/** A return as public.erp_supplier_return answers it (20261004910000). */
const ret = (over: Record<string, unknown> = {}) => ({
  return_id: "r1",
  return_number: "PCN-000004",
  outcome: "replacement",
  rma: "RMA-88",
  inspection_id: null,
  state: "issued",
  currency: "GBP",
  credit_left_minor: 0,
  awaited: 1,
  lines: [{ line_id: "l1", item: "COAT", description: "x", quantity: 1, awaited: 1 }],
  receipts: [],
  may_receive: true,
  ...over,
});

/** A row as public.erp_supplier_credit_notes answers it (20261004910000). */
const row = (over: Record<string, unknown> = {}) => ({
  credit_note_id: "c1",
  credit_note_number: "PCN-000003",
  party_id: "s1",
  party_name: "Maison Brand",
  entity_id: "e1",
  company: "MAIN",
  currency: "GBP",
  issued_on: "2026-10-01",
  left_minor: 20000,
  rma: null,
  allocatable: true,
  bills: [
    { document_id: "b1", document_number: "PINV-000005", owes_minor: 30000, due_on: "2026-10-31" },
  ],
  ...over,
});

describe("a supplier return", () => {
  test("reads what it went back for, the supplier's authorisation and what a replacement awaits", () => {
    expect(supplierReturn(ret())).toEqual({
      returnId: "r1",
      outcome: "replacement",
      rma: "RMA-88",
      currency: "GBP",
      creditLeftMinor: 0,
      awaited: 1,
      mayReceive: true,
      receipts: [],
    });
  });

  test("anything but replacement is a return for credit", () => {
    expect(supplierReturn(ret({ outcome: "credit" }))?.outcome).toBe("credit");
    expect(supplierReturn(ret({ outcome: null }))?.outcome).toBe("credit");
  });

  test("offers Receive only on a replacement the reader may receive that still awaits something", () => {
    expect(canReceiveReplacement(supplierReturn(ret()))).toBe(true);
    expect(canReceiveReplacement(supplierReturn(ret({ awaited: 0 })))).toBe(false);
    expect(canReceiveReplacement(supplierReturn(ret({ may_receive: false })))).toBe(false);
    expect(canReceiveReplacement(supplierReturn(ret({ outcome: "credit" })))).toBe(false);
    expect(canReceiveReplacement(null)).toBe(false);
  });

  test("names the receipts that brought the replacement, and drops one without an identifier", () => {
    const r = supplierReturn(
      ret({
        receipts: [{ document_id: "g1", document_number: "GRN-000009" }, { document_number: "x" }],
      }),
    );
    expect(r?.receipts).toEqual([{ documentId: "g1", number: "GRN-000009" }]);
  });

  test("is not a return without its identifier", () => {
    expect(supplierReturn(ret({ return_id: null }))).toBeNull();
    expect(supplierReturn(null)).toBeNull();
  });
});

describe("supplier credit notes", () => {
  test("a row the reader may allocate, with a bill to take it, offers Allocate", () => {
    const c = supplierCredit(row());
    expect(c).toEqual({
      creditNoteId: "c1",
      creditNoteNumber: "PCN-000003",
      supplier: "Maison Brand",
      currency: "GBP",
      leftMinor: 20000,
      allocatable: true,
      bills: [{ documentId: "b1", number: "PINV-000005", owesMinor: 30000 }],
    });
    expect(canAllocateCredit(c)).toBe(true);
  });

  test("no Allocate where the reader may not, where nothing is left, or where no bill owes anything", () => {
    expect(canAllocateCredit(supplierCredit(row({ allocatable: false })))).toBe(false);
    expect(canAllocateCredit(supplierCredit(row({ left_minor: 0 })))).toBe(false);
    expect(canAllocateCredit(supplierCredit(row({ bills: [] })))).toBe(false);
    expect(canAllocateCredit(null)).toBe(false);
  });
});

describe("what allocating a supplier credit did", () => {
  const answer = (over: Record<string, unknown> = {}) => ({
    credit_note_id: "c1",
    credit_note_number: "PCN-000003",
    bill_id: "b1",
    bill_number: "PINV-000005",
    allocated_minor: 5000,
    currency: "GBP",
    credit_left_minor: 15000,
    bill_owes_minor: 25000,
    bill_state: "part_paid",
    journal_id: "j1",
    ...over,
  });

  test("says how much of which credit went to which bill, and what is still to use", () => {
    expect(supplierCreditOutcome(answer())).toEqual({
      message: `${gbp(5000)} of PCN-000003 allocated to PINV-000005, which owes ${gbp(25000)}. ${gbp(15000)} of PCN-000003 is still to use.`,
      documents: [{ documentId: "b1", number: "PINV-000005" }],
    });
  });

  test("a bill left owing nothing is paid, and a credit used up says nothing more", () => {
    expect(
      supplierCreditOutcome(answer({ bill_owes_minor: 0, credit_left_minor: 0 }))?.message,
    ).toBe(`${gbp(5000)} of PCN-000003 allocated to PINV-000005, which is paid.`);
  });

  test("an answer without the amounts or the bill is no outcome", () => {
    expect(supplierCreditOutcome(answer({ allocated_minor: null }))).toBeNull();
    expect(supplierCreditOutcome(answer({ bill_id: null }))).toBeNull();
    expect(supplierCreditOutcome(null)).toBeNull();
  });
});
