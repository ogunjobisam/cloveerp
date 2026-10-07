import { describe, expect, test } from "bun:test";

import { hostKindOf, requestHost } from "./request-host";

describe("the host a page was opened at", () => {
  test("every host this build knows is static; a client's waits for the directory", () => {
    expect(hostKindOf("cloveerp.com")).toBe("static");
    expect(hostKindOf("www.cloveerp.com")).toBe("static");
    expect(hostKindOf("demo.cloveerp.com")).toBe("static");
    expect(hostKindOf("localhost")).toBe("static");
    expect(hostKindOf(null)).toBe("static");
    expect(hostKindOf("acme.cloveerp.com")).toBe("directory");
  });

  test("the request's host is read as the visitor typed it, before any proxy", () => {
    const at = (headers: Record<string, string>, url = "http://10.0.0.1:3000/x") =>
      requestHost(new Request(url, { headers }));
    expect(at({ "x-forwarded-host": "Acme.cloveerp.com:443", host: "internal" })).toBe(
      "acme.cloveerp.com",
    );
    expect(at({ host: "demo.cloveerp.com" })).toBe("demo.cloveerp.com");
    expect(at({ "x-forwarded-host": "acme.cloveerp.com, edge.internal" })).toBe(
      "acme.cloveerp.com",
    );
    expect(at({})).toBe("10.0.0.1");
  });
});
