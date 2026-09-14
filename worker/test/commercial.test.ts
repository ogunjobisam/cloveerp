import { describe, expect, test } from "bun:test";

import { CommercialEmailError } from "../../src/lib/email/commercial-email.ts";
import { COMMERCIAL_EMAIL_BATCH, worthRetrying } from "../src/core/commercial.ts";
import { PermanentSendFailure, resendHeaders } from "../src/core/resend.ts";

describe("an order form or invoice on its way", () => {
  test("carries its idempotency key to the provider, and nothing when it has none", () => {
    const headers = resendHeaders("re_test", { idempotency_key: " clove-contract-invoice-abc-2-def " });
    expect(headers["idempotency-key"]).toBe("clove-contract-invoice-abc-2-def");
    expect(headers["authorization"]).toBe("Bearer re_test");
    expect(headers["content-type"]).toBe("application/json");
    expect("idempotency-key" in resendHeaders("re_test", {})).toBe(false);
    expect("idempotency-key" in resendHeaders("re_test", { idempotency_key: "  " })).toBe(false);
    expect(resendHeaders("re_test", { idempotency_key: "k".repeat(400) })["idempotency-key"]).toHaveLength(256);
  });

  test("a provider's never and a payload that cannot be written are failed; anything else is tried again", () => {
    expect(worthRetrying(new PermanentSendFailure("resend responded 422"))).toBe(false);
    expect(worthRetrying(new CommercialEmailError("the invoice has no due date"))).toBe(false);
    expect(worthRetrying(new Error("resend responded 503"))).toBe(true);
    expect(worthRetrying("a string thrown by something")).toBe(true);
  });

  test("a pass claims a bounded batch", () => {
    expect(COMMERCIAL_EMAIL_BATCH).toBeGreaterThan(0);
    expect(COMMERCIAL_EMAIL_BATCH).toBeLessThanOrEqual(50);
  });
});
