import { describe, expect, test } from "bun:test";

import { carrierAccount, shipmentTracking, trackingWords, webhookAddress } from "./carrier-account";

describe("the carrier account", () => {
  test("reads whether it is connected, in which mode, and where its webhook posts", () => {
    expect(
      carrierAccount({
        provider: "easypost",
        connected: true,
        mode: "test",
        tracking: true,
        connected_at: "2026-10-02T09:00:00Z",
        webhook_path: "/functions/v1/carrier_webhook?org=acme",
        may_connect: true,
      }),
    ).toEqual({
      provider: "easypost",
      connected: true,
      mode: "test",
      tracking: true,
      connectedAt: "2026-10-02T09:00:00Z",
      webhookPath: "/functions/v1/carrier_webhook?org=acme",
      mayConnect: true,
    });
  });

  test("an account never connected reads as not connected, with no mode", () => {
    const a = carrierAccount({ provider: "easypost", connected: false, mode: null });
    expect(a?.connected).toBe(false);
    expect(a?.mode).toBeNull();
    expect(carrierAccount(null)).toBeNull();
  });

  test("the webhook address joins the project's host and the path", () => {
    expect(webhookAddress("https://x.supabase.co/", "/functions/v1/carrier_webhook?org=acme")).toBe(
      "https://x.supabase.co/functions/v1/carrier_webhook?org=acme",
    );
    expect(webhookAddress("https://x.supabase.co", null)).toBeNull();
  });
});

describe("a shipment's tracking", () => {
  test("reads the label, the tracking code and the latest status", () => {
    const t = shipmentTracking({
      shipment_id: "s1",
      direction: "inbound",
      tracking_reference: "EZ1000000001",
      tracking_status: "in_transit",
      tracking_status_at: "2026-10-02T08:30:00Z",
      tracking_detail: "Departed Paris",
      label_url: "https://easypost-files.example/label.pdf",
      label_rate_minor: 4120,
      currency: "GBP",
      provider: "easypost",
      label_command_status: "succeeded",
    });
    expect(t?.direction).toBe("inbound");
    expect(t?.status).toBe("in_transit");
    expect(t?.labelRateMinor).toBe(4120);
    expect(shipmentTracking({ nope: 1 })).toBeNull();
  });

  test("every status reads in words, and one nobody knows reads as not yet tracked", () => {
    expect(trackingWords("delivered")).toEqual({ words: "Delivered", tone: "ok" });
    expect(trackingWords("return_to_sender").tone).toBe("bad");
    expect(trackingWords(null).words).toBe("Not yet tracked");
  });
});
