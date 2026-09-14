import { describe, expect, test } from "bun:test";

import {
  describeSend,
  latestSends,
  recipientLabel,
  recipientsSentence,
  sourceWords,
  type CommercialSend,
} from "./commercial-sends";

function send(over: Partial<CommercialSend>): CommercialSend {
  return {
    id: "s1",
    kind: "order_form",
    document_id: "q1",
    send_number: 1,
    to_address: "dana@okafor.example",
    to_name: "Dana Buyer",
    recipient_source: "customer_contact",
    status: "queued",
    attempts: 0,
    sent_at: null,
    failure_reason: null,
    requested_by: "sam@cloveerp.com",
    created_at: "2026-09-14T10:00:00Z",
    ...over,
  };
}

describe("what the console says about a send", () => {
  test("a recipient reads as a name and an address, or the address alone", () => {
    expect(recipientLabel("dana@okafor.example", "Dana Buyer")).toBe(
      "Dana Buyer <dana@okafor.example>",
    );
    expect(recipientLabel("dana@okafor.example", "  ")).toBe("dana@okafor.example");
    expect(recipientLabel("dana@okafor.example", null)).toBe("dana@okafor.example");
  });

  test("sent says to whom and when; failed says why; waiting says it is waiting", () => {
    const sent = describeSend(send({ status: "sent", sent_at: "2026-09-14T10:15:00Z" }));
    expect(sent.tone).toBe("ok");
    expect(sent.text).toMatch(
      /^Sent to Dana Buyer <dana@okafor\.example> at 14 Sept? 2026, \d\d:15$/,
    );
    expect(
      describeSend(send({ status: "failed", failure_reason: "resend responded 422" })),
    ).toEqual({
      tone: "bad",
      text: "Not sent to Dana Buyer <dana@okafor.example>: resend responded 422",
    });
    expect(describeSend(send({ status: "queued" }))).toEqual({
      tone: "muted",
      text: "Waiting to go to Dana Buyer <dana@okafor.example>",
    });
    expect(
      describeSend(send({ status: "queued", failure_reason: "resend responded 503", attempts: 1 }))
        .tone,
    ).toBe("warn");
    expect(
      describeSend(
        send({
          status: "cancelled",
          failure_reason: "a demonstration organisation sends no email",
        }),
      ).text,
    ).toBe(
      "Not sent to Dana Buyer <dana@okafor.example>: a demonstration organisation sends no email",
    );
    expect(describeSend(send({ status: "sending" })).text).toBe(
      "Being sent to Dana Buyer <dana@okafor.example>",
    );
  });

  test("the latest send of a document is every recipient of its highest send number", () => {
    const rows = [
      send({ id: "a", send_number: 1, status: "sent" }),
      send({ id: "b", send_number: 2, to_address: "zed@okafor.example" }),
      send({ id: "c", send_number: 2, to_address: "amy@okafor.example" }),
      send({ id: "d", document_id: "q2", send_number: 5 }),
    ];
    expect(latestSends(rows, "q1").map((s) => s.id)).toEqual(["c", "b"]);
    expect(latestSends(rows, "q3")).toEqual([]);
  });

  test("who it goes to reads as a sentence, and nobody says so plainly", () => {
    expect(recipientsSentence("order_form", [], false)).toBe("No customer email on this quote");
    expect(recipientsSentence("contract_invoice", [], false)).toContain("no billing contact");
    expect(
      recipientsSentence(
        "order_form",
        [{ address: "a@b.example", name: null, source: "customer_contact" }],
        true,
      ),
    ).toBe("A demonstration organisation is never emailed.");
    expect(
      recipientsSentence(
        "contract_invoice",
        [{ address: "accounts@okafor.example", name: "Accounts", source: "billing_contact" }],
        false,
      ),
    ).toBe("Goes to Accounts <accounts@okafor.example>, the contract's billing contact.");
    expect(
      recipientsSentence(
        "contract_invoice",
        [
          { address: "a@okafor.example", name: "Amy", source: "administrator" },
          { address: "b@okafor.example", name: null, source: "administrator" },
          { address: "c@okafor.example", name: "Cal", source: "administrator" },
        ],
        false,
      ),
    ).toBe(
      "Goes to Amy <a@okafor.example>, b@okafor.example and Cal <c@okafor.example>, the administrators of the customer's organisation.",
    );
    expect(sourceWords("something new")).toBe("a recipient");
  });
});
