import { describe, expect, test } from "bun:test";

import {
  HEADERS_NOT_SENT,
  apiBase,
  authoriseUrl,
  clientIp,
  environmentOf,
  fraudHeaders,
  hmrcProblem,
  normaliseVrn,
  obligationFor,
  readObligations,
  readReceipt,
  relayTarget,
  returnBody,
  signState,
  stateHost,
  utcOffset,
  verifyState,
} from "./hmrc-mtd";

/**
 * HMRC MTD for VAT, against the examples in HMRC's own VAT API specification
 * (VAT (MTD) API 1.0): what is sent, how its answers are read, and the state
 * that travels through HMRC's sign-in and back. No sandbox account is needed
 * for any of it.
 */

describe("where and as whom", () => {
  test("sandbox unless production is said", () => {
    expect(environmentOf(null)).toBe("sandbox");
    expect(environmentOf("staging")).toBe("sandbox");
    expect(environmentOf("production")).toBe("production");
    expect(apiBase("sandbox")).toBe("https://test-api.service.hmrc.gov.uk");
    expect(apiBase("production")).toBe("https://api.service.hmrc.gov.uk");
  });

  test("a VAT number is nine digits, whatever way it was typed", () => {
    expect(normaliseVrn("GB 123 4567 89")).toBe("123456789");
    expect(normaliseVrn("123456789")).toBe("123456789");
    expect(normaliseVrn("12345678")).toBeNull();
    expect(normaliseVrn(null)).toBeNull();
  });

  test("HMRC's sign-in asks to read and write VAT and comes back to the one callback", () => {
    const url = new URL(
      authoriseUrl({
        environment: "sandbox",
        clientId: "client-1",
        redirectUri: "https://cloveerp.com/hmrc/callback",
        state: "s",
      }),
    );
    expect(url.origin + url.pathname).toBe("https://test-api.service.hmrc.gov.uk/oauth/authorize");
    expect(url.searchParams.get("scope")).toBe("read:vat write:vat");
    expect(url.searchParams.get("response_type")).toBe("code");
    expect(url.searchParams.get("redirect_uri")).toBe("https://cloveerp.com/hmrc/callback");
  });
});

describe("the state that travels through HMRC", () => {
  test("is trusted only with the key that signed it", async () => {
    const state = await signState("k", "ticket-1", "acme.cloveerp.com");
    expect(await verifyState("k", state)).toEqual({ ticket: "ticket-1", host: "acme.cloveerp.com" });
    expect(await verifyState("other", state)).toBeNull();
    const [payload] = state.split(".");
    expect(await verifyState("k", `${payload}.forged`)).toBeNull();
    expect(await verifyState("k", `${state}.extra`)).toBeNull();
  });

  test("tells the relay its host, and the relay sends nobody off cloveerp.com", async () => {
    const state = await signState("k", "t", "acme.cloveerp.com");
    expect(stateHost(state)).toBe("acme.cloveerp.com");
    expect(stateHost("not-a-state")).toBeNull();
    expect(relayTarget("acme.cloveerp.com", "cloveerp.com")).toBe("acme.cloveerp.com");
    expect(relayTarget("cloveerp.com", "cloveerp.com")).toBe("cloveerp.com");
    expect(relayTarget("evil.com", "cloveerp.com")).toBeNull();
    expect(relayTarget("cloveerp.com.evil.com", "cloveerp.com")).toBeNull();
    expect(relayTarget("a.b.cloveerp.com", "cloveerp.com")).toBeNull();
    expect(relayTarget(null, "cloveerp.com")).toBeNull();
  });
});

describe("obligations", () => {
  // HMRC's example: quarterly obligations, one fulfilled.
  const example = {
    obligations: [
      {
        start: "2017-01-01",
        end: "2017-03-31",
        due: "2017-05-07",
        status: "F",
        periodKey: "18A1",
        received: "2017-05-06",
      },
      { start: "2017-04-01", end: "2017-06-30", due: "2017-08-07", status: "O", periodKey: "18A2" },
      { start: "2017-07-01", periodKey: "bad" },
    ],
  };

  test("are read as HMRC gives them, the malformed left out", () => {
    const list = readObligations(example);
    expect(list.map((o) => o.periodKey)).toEqual(["18A1", "18A2"]);
    expect(list[0]?.received).toBe("2017-05-06");
    expect(readObligations(null)).toEqual([]);
  });

  test("a return answers the open obligation with its own dates, and no other", () => {
    const list = readObligations(example);
    expect(obligationFor(list, "2017-04-01", "2017-06-30")?.periodKey).toBe("18A2");
    expect(obligationFor(list, "2017-01-01", "2017-03-31")).toBeNull();
    expect(obligationFor(list, "2017-04-01", "2017-06-29")).toBeNull();
  });
});

describe("the return", () => {
  // The finalised return's MTD export, as erp.vat_return_export writes it.
  const exported = {
    periodKey: null,
    vatDueSales: 105.5,
    vatDueAcquisitions: 0,
    totalVatDue: 105.5,
    vatReclaimedCurrPeriod: 10.15,
    netVatDue: 95.35,
    totalValueSalesExVAT: 1000,
    totalValuePurchasesExVAT: 300,
    totalValueGoodsSuppliedExVAT: 0,
    totalAcquisitionsExVAT: 0,
    finalised: true,
    vrn: "123456789",
    periodStart: "2017-04-01",
    periodEnd: "2017-06-30",
  };

  test("goes with HMRC's period key and declared final, without the file's own fields", () => {
    const body = returnBody(exported, "18A2");
    expect(body["periodKey"]).toBe("18A2");
    expect(body["finalised"]).toBe(true);
    expect(body["netVatDue"]).toBe(95.35);
    expect(body).not.toHaveProperty("vrn");
    expect(body).not.toHaveProperty("periodStart");
    expect(Object.keys(body)).toHaveLength(11);
  });

  test("is not sent with a box missing", () => {
    const { netVatDue: _, ...short } = exported;
    expect(() => returnBody(short, "18A2")).toThrow("netVatDue");
  });

  test("HMRC's receipt is read from its body and headers", () => {
    // HMRC's example 201 response, and the headers the specification names.
    const headers = new Headers({
      "Receipt-ID": "2dd537bc-4244-4ebf-bac9-96321be13cdc",
      "Receipt-Timestamp": "2018-02-14T09:32:15Z",
      "X-CorrelationId": "c75f40a6-a3df-4429-a697-471eeec46435",
    });
    const r = readReceipt(
      {
        processingDate: "2018-01-16T08:20:27.895+0000",
        paymentIndicator: "BANK",
        formBundleNumber: "256660290587",
        chargeRefNumber: "aCxFaNx0FZsCvyWF",
      },
      headers,
    );
    expect(r.formBundleNumber).toBe("256660290587");
    expect(r.receiptId).toBe("2dd537bc-4244-4ebf-bac9-96321be13cdc");
    expect(r.correlationId).toBe("c75f40a6-a3df-4429-a697-471eeec46435");
    expect(() => readReceipt({}, headers)).toThrow("form bundle");
  });

  test("HMRC's refusals are said in words a person can act on", () => {
    expect(
      hmrcProblem(403, {
        code: "DUPLICATE_SUBMISSION",
        message: "The VAT return was already submitted for the given period",
      }),
    ).toEqual({ code: "DUPLICATE_SUBMISSION", words: "HMRC already holds a return for this period." });
    expect(hmrcProblem(400, { errors: [{ code: "VRN_INVALID" }] }).code).toBe("VRN_INVALID");
    expect(hmrcProblem(500, null)).toEqual({
      code: "HTTP_500",
      words: "HMRC refused the request (HTTP_500).",
    });
  });
});

describe("fraud prevention headers", () => {
  const client = {
    deviceId: "beec798b-b366-47fa-b1f8-92cede14a1ce",
    userAgent: "Mozilla/5.0 (Macintosh)",
    screens: [{ width: 1920, height: 1080, scalingFactor: 1.25, colourDepth: 24 }],
    window: { width: 1256, height: 803 },
    utcOffsetMinutes: 60,
  };
  const server = {
    clientPublicIp: "198.51.100.0",
    clientPublicIpAt: new Date("2026-10-13T09:00:00.123Z"),
    vendorPublicIp: "203.0.113.6",
    userIds: { "clove-erp": "jo@acme.test" },
    productName: "Clove ERP",
    versions: { "clove-erp": "1.0.0" },
  };

  test("say what HMRC asks of a web application its server calls for", () => {
    const h = fraudHeaders(client, server);
    expect(h["Gov-Client-Connection-Method"]).toBe("WEB_APP_VIA_SERVER");
    expect(h["Gov-Client-Screens"]).toBe("width=1920&height=1080&scaling-factor=1.25&colour-depth=24");
    expect(h["Gov-Client-Window-Size"]).toBe("width=1256&height=803");
    expect(h["Gov-Client-Timezone"]).toBe("UTC+01:00");
    expect(h["Gov-Client-User-IDs"]).toBe("clove-erp=jo%40acme.test");
    expect(h["Gov-Client-Public-IP-Timestamp"]).toBe("2026-10-13T09:00:00.123Z");
    expect(h["Gov-Vendor-Product-Name"]).toBe("Clove%20ERP");
    expect(h["Gov-Vendor-Forwarded"]).toBe("by=203.0.113.6&for=198.51.100.0");
  });

  test("leave out what cannot be collected rather than fill it with a placeholder", () => {
    const h = fraudHeaders(client, { ...server, clientPublicIp: null, vendorPublicIp: null });
    expect(h).not.toHaveProperty("Gov-Client-Public-IP");
    expect(h).not.toHaveProperty("Gov-Vendor-Forwarded");
    expect(Object.values(h).some((v) => v === "" || v === "null" || v === "undefined")).toBe(false);
    for (const name of Object.keys(HEADERS_NOT_SENT)) expect(h).not.toHaveProperty(name);
  });

  test("timezones west of UTC and a client behind a private address", () => {
    expect(utcOffset(-75)).toBe("UTC-01:15");
    expect(utcOffset(0)).toBe("UTC+00:00");
    expect(clientIp("198.51.100.7, 10.0.0.1")).toBe("198.51.100.7");
    expect(clientIp("10.0.0.1")).toBeNull();
    expect(clientIp("192.168.1.4")).toBeNull();
    expect(clientIp("2001:db8::1")).toBe("2001:db8::1");
    expect(clientIp(null)).toBeNull();
  });
});
