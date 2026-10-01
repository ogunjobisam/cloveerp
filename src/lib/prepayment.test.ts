import { describe, expect, test } from "bun:test";

import { formatMinor } from "./money";
import {
  canAllocatePrepayment,
  orderPrepayment,
  prepaymentAllocationOutcome,
  showsPrepayment,
  supplierPrepayment,
} from "./prepayment";

const gbp = (n: number) => formatMinor(n, "GBP");

/** An order's prepayment as public.erp_order_prepayment answers it (20261004900000). */
const order = (over: Record<string, unknown> = {}) => ({
  order_id: "o1",
  order_number: "PO-000001",
  currency: "GBP",
  order_gross_minor: 100000,
  requested_minor: 30000,
  paid_minor: 30000,
  used_minor: 10000,
  left_minor: 20000,
  due_minor: 0,
  due_on: "2026-10-01",
  reason: "pro-forma 0042",
  open: true,
  may_request: true,
  payments: [
    {
      document_id: "pmt1",
      document_number: "PMT-000001",
      paid_minor: 30000,
      paid_on: "2026-10-01",
    },
  ],
  ...over,
});

/** A row as public.erp_supplier_prepayments answers it (20261004900000). */
const row = (over: Record<string, unknown> = {}) => ({
  order_id: "o6",
  order_number: "PO-000006",
  party_id: "s1",
  party_name: "Maison Brand",
  entity_id: "e1",
  company: "MAIN",
  currency: "GBP",
  paid_minor: 20000,
  left_minor: 15000,
  order_cancelled: false,
  allocatable: true,
  bills: [
    { document_id: "b1", document_number: "PINV-000005", owes_minor: 7000, due_on: "2026-10-31" },
  ],
  ...over,
});

describe("an order's prepayment", () => {
  test("reads what was asked for, paid, used and is left, with the payments that paid it", () => {
    expect(orderPrepayment(order())).toEqual({
      orderId: "o1",
      currency: "GBP",
      orderGrossMinor: 100000,
      requestedMinor: 30000,
      paidMinor: 30000,
      usedMinor: 10000,
      leftMinor: 20000,
      dueMinor: 0,
      dueOn: "2026-10-01",
      reason: "pro-forma 0042",
      mayRequest: true,
      payments: [{ documentId: "pmt1", number: "PMT-000001", paidMinor: 30000 }],
    });
  });

  test("is not an order's prepayment when the database answered nothing, or no order", () => {
    expect(orderPrepayment(null)).toBeNull();
    expect(orderPrepayment({ requested_minor: 0 })).toBeNull();
    expect(orderPrepayment([order()])).toBeNull();
  });

  test("is shown when something was asked for or paid, or the reader may ask, and not otherwise", () => {
    const none = { requested_minor: 0, paid_minor: 0, may_request: false };
    expect(showsPrepayment(orderPrepayment(order()))).toBe(true);
    expect(showsPrepayment(orderPrepayment(order({ ...none, may_request: true })))).toBe(true);
    expect(showsPrepayment(orderPrepayment(order({ ...none, paid_minor: 1 })))).toBe(true);
    expect(showsPrepayment(orderPrepayment(order(none)))).toBe(false);
    expect(showsPrepayment(null)).toBe(false);
  });

  test("a payment with no identifier is left out rather than drawn as a dead link", () => {
    const p = orderPrepayment(order({ payments: [{ document_number: "PMT-9", paid_minor: 1 }] }));
    expect(p?.payments).toEqual([]);
  });
});

describe("supplier prepayments", () => {
  test("a row the database says the reader may allocate, with a bill to take it, offers Allocate", () => {
    const p = supplierPrepayment(row());
    expect(p).toEqual({
      orderId: "o6",
      orderNumber: "PO-000006",
      supplier: "Maison Brand",
      currency: "GBP",
      leftMinor: 15000,
      cancelled: false,
      allocatable: true,
      bills: [{ documentId: "b1", number: "PINV-000005", owesMinor: 7000 }],
    });
    expect(canAllocatePrepayment(p)).toBe(true);
  });

  test("no Allocate where the reader may not, where nothing is left, or where no bill owes anything", () => {
    expect(canAllocatePrepayment(supplierPrepayment(row({ allocatable: false })))).toBe(false);
    expect(canAllocatePrepayment(supplierPrepayment(row({ left_minor: 0 })))).toBe(false);
    expect(canAllocatePrepayment(supplierPrepayment(row({ bills: [] })))).toBe(false);
    expect(
      canAllocatePrepayment(
        supplierPrepayment(row({ bills: [{ document_id: "b1", owes_minor: 0 }] })),
      ),
    ).toBe(false);
    expect(canAllocatePrepayment(null)).toBe(false);
  });

  test("a cancelled order's prepayment is read as cancelled", () => {
    expect(supplierPrepayment(row({ order_cancelled: true }))?.cancelled).toBe(true);
  });

  test("is not a row without an order or an amount left", () => {
    expect(supplierPrepayment(row({ order_id: null }))).toBeNull();
    expect(supplierPrepayment(row({ left_minor: "" }))).toBeNull();
    expect(supplierPrepayment("PO-000006")).toBeNull();
  });
});

describe("what allocating a prepayment did", () => {
  const answer = (over: Record<string, unknown> = {}) => ({
    order_id: "o6",
    order_number: "PO-000006",
    bill_id: "b1",
    bill_number: "PINV-000005",
    allocated_minor: 5000,
    currency: "GBP",
    prepayment_left_minor: 10000,
    bill_owes_minor: 2000,
    bill_state: "part_paid",
    journal_id: "j1",
    ...over,
  });

  test("says how much went to which bill, what the bill still owes and what is still prepaid, and links the bill", () => {
    expect(prepaymentAllocationOutcome(answer())).toEqual({
      message: `${gbp(5000)} of the prepayment on PO-000006 allocated to PINV-000005, which owes ${gbp(2000)}. ${gbp(10000)} is still prepaid on PO-000006.`,
      documents: [{ documentId: "b1", number: "PINV-000005" }],
    });
  });

  test("a bill left owing nothing is paid, and a prepayment used up says nothing more", () => {
    expect(
      prepaymentAllocationOutcome(answer({ bill_owes_minor: 0, prepayment_left_minor: 0 }))
        ?.message,
    ).toBe(`${gbp(5000)} of the prepayment on PO-000006 allocated to PINV-000005, which is paid.`);
  });

  test("an answer without the amounts or the bill is no outcome", () => {
    expect(prepaymentAllocationOutcome(answer({ allocated_minor: null }))).toBeNull();
    expect(prepaymentAllocationOutcome(answer({ bill_id: null }))).toBeNull();
    expect(prepaymentAllocationOutcome(null)).toBeNull();
  });
});
