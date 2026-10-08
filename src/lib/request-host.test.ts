import { describe, expect, test } from "bun:test";

import {
  CLOSED_ROBOTS,
  PUBLIC_ROBOTS,
  hostKindOf,
  requestHost,
  robotsFor,
  sitemapRedirect,
} from "./request-host";

describe("the host a page was opened at", () => {
  test("every host this build knows is static; any other name under the apex waits for the directory", () => {
    expect(hostKindOf("cloveerp.com")).toBe("static");
    expect(hostKindOf("www.cloveerp.com")).toBe("static");
    expect(hostKindOf("demo.cloveerp.com")).toBe("static");
    expect(hostKindOf("localhost")).toBe("static");
    expect(hostKindOf(null)).toBe("static");
    expect(hostKindOf("acme.cloveerp.com")).toBe("directory");
    expect(hostKindOf("ab.cloveerp.com")).toBe("directory");
    expect(hostKindOf("a.b.cloveerp.com")).toBe("directory");
    expect(hostKindOf("acme.cloveerp.com.")).toBe("directory");
  });

  test("the request's host is its own URL's, whatever a header claims", () => {
    const at = (headers: Record<string, string>, url = "https://acme.cloveerp.com/x") =>
      requestHost(new Request(url, { headers }));
    expect(at({})).toBe("acme.cloveerp.com");
    expect(at({}, "https://Acme.CloveERP.com:443/signin")).toBe("acme.cloveerp.com");
    expect(at({}, "http://10.0.0.1:3000/x")).toBe("10.0.0.1");
    // A visitor can send any x-forwarded-host to a Worker; it never names the host.
    expect(at({ "x-forwarded-host": "cloveerp.com" })).toBe("acme.cloveerp.com");
    expect(at({ "x-forwarded-host": "demo.cloveerp.com", host: "internal" })).toBe(
      "acme.cloveerp.com",
    );
  });
});

describe("what a crawler is told", () => {
  test("the public site keeps its robots.txt as it was", () => {
    expect(robotsFor("cloveerp.com")).toBe(PUBLIC_ROBOTS);
    expect(robotsFor("www.cloveerp.com")).toBe(PUBLIC_ROBOTS);
    expect(PUBLIC_ROBOTS).toContain("User-agent: *\nAllow: /");
    expect(PUBLIC_ROBOTS).toContain("Sitemap: https://cloveerp.com/sitemap.xml");
  });

  test("every other host is closed to crawlers", () => {
    for (const host of [
      "demo.cloveerp.com",
      "acme.cloveerp.com",
      "ab.cloveerp.com",
      "localhost",
      null,
    ]) {
      expect(robotsFor(host)).toBe(CLOSED_ROBOTS);
    }
    expect(CLOSED_ROBOTS).toBe("User-agent: *\nDisallow: /\n");
  });

  test("the sitemap is the apex's, and every other host sends a crawler there", () => {
    expect(sitemapRedirect("cloveerp.com")).toBeNull();
    expect(sitemapRedirect("cloveerp.com.")).toBeNull();
    for (const host of [
      "www.cloveerp.com",
      "demo.cloveerp.com",
      "acme.cloveerp.com",
      "localhost",
      null,
    ]) {
      expect(sitemapRedirect(host)).toBe("https://cloveerp.com/sitemap.xml");
    }
  });
});
