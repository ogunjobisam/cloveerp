import { describe, expect, test } from "bun:test";

import { purchaseOrderSends, sendStatus } from "./purchase-order-send";

/** An answer as public.erp_purchase_order_sends gives it (20261004920000). */
const answer = (over: Record<string, unknown> = {}) => ({
  order_id: "o1",
  default_to: "orders@maison.example",
  may_send: true,
  needs_reason: true,
  sends: [
    {
      document_email_id: "m2",
      document_issue_id: "i2",
      issued_number: "PO-000042 (2)",
      issue_status: "reserved",
      reason: "line 1 is now 14",
      to_address: "new@maison.example",
      cc: [],
      status: "sent",
      queued_at: "2026-10-01T10:00:00Z",
      sent_at: "2026-10-01T10:01:00Z",
      failure_reason: null,
      delivery_state: "bounced",
      delivery_state_at: "2026-10-01T10:02:00Z",
      delivery_detail: "Permanent: mailbox does not exist",
      document_kept: false,
      document_problem: "no storage is configured",
      sent_by: "Bea Buyer",
    },
    {
      document_email_id: "m1",
      issued_number: "PO-000042",
      to_address: "orders@maison.example",
      cc: ["buying@okafor.example"],
      status: "sent",
      queued_at: "2026-09-30T09:00:00Z",
      sent_at: "2026-09-30T09:01:00Z",
      delivery_state: "delivered",
      delivery_state_at: "2026-09-30T09:01:30Z",
      document_kept: true,
      sent_by: "Bea Buyer",
    },
  ],
  ...over,
});

describe("a purchase order's sends", () => {
  test("reads the address, whether the reader may send, whether a reason is needed, and each send newest first", () => {
    const s = purchaseOrderSends(answer());
    expect(s?.defaultTo).toBe("orders@maison.example");
    expect(s?.maySend).toBe(true);
    expect(s?.needsReason).toBe(true);
    expect(s?.sends.map((x) => x.id)).toEqual(["m2", "m1"]);
    expect(s?.sends[0]).toMatchObject({
      status: "bounced",
      reason: "line 1 is now 14",
      problem: "Permanent: mailbox does not exist",
      copyKept: false,
      when: "2026-10-01T10:02:00Z",
    });
    expect(s?.sends[1]).toMatchObject({
      status: "delivered",
      cc: ["buying@okafor.example"],
      copyKept: true,
      problem: null,
    });
  });

  test("a send's word is what the provider reported once it has, otherwise the queue's own", () => {
    expect(sendStatus("queued", null)).toBe("queued");
    expect(sendStatus("sending", null)).toBe("sending");
    expect(sendStatus("sent", null)).toBe("sent");
    expect(sendStatus("sent", "delivered")).toBe("delivered");
    expect(sendStatus("sent", "opened")).toBe("opened");
    expect(sendStatus("sent", "complained")).toBe("bounced");
    expect(sendStatus("failed", "delivered")).toBe("failed");
  });

  test("a send without an identifier or an address is left out, and an answer without an order is nothing", () => {
    expect(purchaseOrderSends(answer({ sends: [{ to_address: "x@y.example" }] }))?.sends).toEqual(
      [],
    );
    expect(purchaseOrderSends({ sends: [] })).toBeNull();
    expect(purchaseOrderSends(null)).toBeNull();
  });
});
