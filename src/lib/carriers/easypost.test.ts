import { describe, expect, test } from "bun:test";

import {
  EASYPOST_API,
  LabelRefused,
  LabelUnavailable,
  boughtLabel,
  buyLabel,
  chooseRate,
  minorOf,
  ouncesOf,
  parseTrackingEvent,
  ratesOf,
  shipmentBody,
  verifyCarrierWebhook,
  webhookSignature,
  type LabelRequest,
} from "./easypost";

/** A shipment.buy payload as erp.request_carrier_label() queues it (20261004965000). */
const request = (over: Partial<LabelRequest> = {}): LabelRequest => ({
  shipment_id: "s1",
  reference: "SHP-000001",
  direction: "inbound",
  from_address: {
    name: "Maison Brand",
    street1: "12 rue du Faubourg",
    city: "Paris",
    zip: "75008",
    country: "FR",
  },
  to_address: {
    name: "Main warehouse",
    company: "Clove Retail",
    street1: "1 Dock Road",
    city: "London",
    zip: "E16 1AA",
    country: "GB",
  },
  parcel: { weight_g: 2000 },
  carrier_account: "ca_dhl",
  service: "Express",
  ...over,
});

/** A created shipment as EasyPost answers it, trimmed to what is read. */
const created = {
  id: "shp_123",
  rates: [
    {
      id: "rate_a",
      service: "Express",
      carrier_account_id: "ca_dhl",
      rate: "41.20",
      currency: "GBP",
    },
    {
      id: "rate_b",
      service: "Economy",
      carrier_account_id: "ca_dhl",
      rate: "18.05",
      currency: "GBP",
    },
    {
      id: "rate_c",
      service: "Express",
      carrier_account_id: "ca_ups",
      rate: "12.00",
      currency: "GBP",
    },
  ],
};

const bought = {
  id: "shp_123",
  tracking_code: "EZ1000000001",
  postage_label: {
    label_url: "https://easypost-files.example/label.png",
    label_pdf_url: "https://easypost-files.example/label.pdf",
  },
  selected_rate: { rate: "41.20", currency: "GBP" },
};

describe("the shipment EasyPost is asked to create", () => {
  test("carries both addresses, the weight in ounces, the linked carrier account and a PDF label", () => {
    expect(shipmentBody(request())).toEqual({
      shipment: {
        reference: "SHP-000001",
        from_address: {
          name: "Maison Brand",
          street1: "12 rue du Faubourg",
          city: "Paris",
          zip: "75008",
          country: "FR",
        },
        to_address: {
          name: "Main warehouse",
          company: "Clove Retail",
          street1: "1 Dock Road",
          city: "London",
          zip: "E16 1AA",
          country: "GB",
        },
        parcel: { weight: 70.5 },
        carrier_accounts: ["ca_dhl"],
        options: { label_format: "PDF" },
      },
    });
  });

  test("a shipment with no weight, or an address with no street, postcode or country, is refused before anything leaves", () => {
    expect(() => shipmentBody(request({ parcel: { weight_g: 0 } }))).toThrow(LabelRefused);
    expect(() => shipmentBody(request({ to_address: { name: "Nobody", country: "GB" } }))).toThrow(
      "the recipient's address has no street1, zip",
    );
  });

  test("weights and rates convert as the carrier reads them", () => {
    expect(ouncesOf(28.35)).toBe(1);
    expect(ouncesOf(1)).toBe(0.1);
    expect(minorOf("41.2")).toBe(4120);
    expect(minorOf("7")).toBe(700);
    expect(minorOf("cheap")).toBeNull();
  });
});

describe("the rate bought", () => {
  test("is the booked service at the linked account, else the account's cheapest, else nothing", () => {
    const rates = ratesOf(created);
    expect(chooseRate(rates, "express", "ca_dhl")?.id).toBe("rate_a");
    expect(chooseRate(rates, "Overnight", "ca_dhl")?.id).toBe("rate_b");
    expect(chooseRate(rates, null, null)?.id).toBe("rate_c");
    expect(chooseRate(rates, "Express", "ca_fedex")).toBeNull();
  });
});

describe("buying a label", () => {
  test("creates the shipment, buys the chosen rate, and answers what the database keeps", async () => {
    const calls: Array<{ url: string; body: unknown; auth: string | null }> = [];
    const fake = async (url: string, init: RequestInit) => {
      calls.push({
        url,
        body: JSON.parse(String(init.body)),
        auth: new Headers(init.headers).get("authorization"),
      });
      return new Response(JSON.stringify(calls.length === 1 ? created : bought), { status: 200 });
    };
    const label = await buyLabel(request(), "EZTKtestkey", { fetch: fake });
    expect(calls.map((c) => c.url)).toEqual([
      `${EASYPOST_API}/shipments`,
      `${EASYPOST_API}/shipments/shp_123/buy`,
    ]);
    expect(calls[1]?.body).toEqual({ rate: { id: "rate_a" } });
    expect(calls[0]?.auth).toBe(`Basic ${btoa("EZTKtestkey:")}`);
    expect(label).toEqual({
      tracking_code: "EZ1000000001",
      label_url: "https://easypost-files.example/label.pdf",
      carrier_shipment_id: "shp_123",
      rate_minor: 4120,
      currency: "GBP",
    });
  });

  test("a 4xx is refused for good, a 5xx or no answer may be tried again, and the key is never in the error", async () => {
    const answering = (status: number) => async () => new Response("bad address", { status });
    const refused = await buyLabel(request(), "EZTKsecret", { fetch: answering(422) }).catch(
      (e: unknown) => e,
    );
    expect(refused).toBeInstanceOf(LabelRefused);
    expect(String((refused as Error).message)).not.toContain("EZTKsecret");
    expect(
      await buyLabel(request(), "k", { fetch: answering(503) }).catch((e: unknown) => e),
    ).toBeInstanceOf(LabelUnavailable);
    const silent = await buyLabel(request(), "k", {
      fetch: async () => {
        throw new Error("socket");
      },
    }).catch((e: unknown) => e);
    expect(silent).toBeInstanceOf(LabelUnavailable);
    expect((silent as LabelUnavailable).answered).toBe(false);
  });

  test("an answer without a tracking code is not a label", () => {
    expect(() => boughtLabel({ id: "shp_1" })).toThrow(LabelRefused);
  });
});

describe("the carrier webhook", () => {
  const body = JSON.stringify({
    id: "evt_1",
    description: "tracker.updated",
    result: {
      object: "Tracker",
      tracking_code: "EZ1000000001",
      status: "in_transit",
      updated_at: "2026-10-02T09:00:00Z",
      tracking_details: [
        { message: "Picked up", datetime: "2026-10-01T17:00:00Z" },
        { message: "Departed Paris", datetime: "2026-10-02T08:30:00Z" },
      ],
    },
  });

  test("is EasyPost's only when signed with the organisation's secret over the exact body", async () => {
    const signature = await webhookSignature("whsec-org", body);
    expect(signature).toMatch(/^hmac-sha256-hex=[0-9a-f]{64}$/);
    expect(await verifyCarrierWebhook({ body, signature, secret: "whsec-org" })).toEqual({
      ok: true,
    });
    expect(
      (await verifyCarrierWebhook({ body: `${body} `, signature, secret: "whsec-org" })).ok,
    ).toBe(false);
    expect((await verifyCarrierWebhook({ body, signature, secret: "another" })).ok).toBe(false);
    expect((await verifyCarrierWebhook({ body, signature: null, secret: "whsec-org" })).ok).toBe(
      false,
    );
    expect((await verifyCarrierWebhook({ body, signature, secret: null })).ok).toBe(false);
  });

  test("a tracker event reads its id, tracking code, status and latest detail; anything else is not one", () => {
    expect(parseTrackingEvent(body)).toEqual({
      eventId: "evt_1",
      trackingCode: "EZ1000000001",
      status: "in_transit",
      occurredAt: "2026-10-02T08:30:00Z",
      detail: "Departed Paris",
    });
    expect(
      parseTrackingEvent(JSON.stringify({ id: "evt_2", description: "batch.created", result: {} })),
    ).toBeNull();
    expect(parseTrackingEvent("not json")).toBeNull();
    const odd = JSON.parse(body) as { result: { status: string } };
    odd.result.status = "teleported";
    expect(parseTrackingEvent(JSON.stringify(odd))?.status).toBe("unknown");
  });
});
