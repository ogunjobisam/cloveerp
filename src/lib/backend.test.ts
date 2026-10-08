import { describe, expect, test } from "bun:test";

import {
  APEX_HOST,
  APEX_ORIGIN,
  DEMO_ADDRESS,
  DEMO_BACKEND,
  DEMO_HOST,
  PRODUCTION_BACKEND,
  apexHref,
  apexRedirect,
  chooseBackend,
  clientCodeOf,
  isClientHost,
  isDirectoryHost,
  isPublicSiteHost,
  marketingIsElsewhere,
  normalHost,
  pageHost,
} from "./backend";
import { demonstrationsLiveElsewhere } from "./platform";

/**
 * One build, two projects, chosen by the address the page was opened at
 * (6 October): demo.cloveerp.com talks to the demonstration, everywhere else
 * does what it did before.
 */
describe("the project a page talks to", () => {
  const none = { url: undefined, key: undefined };
  const stack = { url: "http://127.0.0.1:54321", key: "a-local-stack-key" };

  test("opened at demo.cloveerp.com, it talks to the demonstration project", () => {
    expect(chooseBackend(DEMO_HOST, none)).toEqual(DEMO_BACKEND);
    expect(chooseBackend("DEMO.cloveerp.com", none)).toEqual(DEMO_BACKEND);
  });

  test("whatever the build was given, so production's build cannot send a prospect to production", () => {
    expect(chooseBackend(DEMO_HOST, stack)).toEqual(DEMO_BACKEND);
    expect(chooseBackend(DEMO_HOST, PRODUCTION_BACKEND)).toEqual(DEMO_BACKEND);
  });

  test("opened anywhere else with nothing in the environment, it talks to production as before", () => {
    expect(chooseBackend("cloveerp.com", none)).toEqual(PRODUCTION_BACKEND);
    expect(chooseBackend("www.cloveerp.com", none)).toEqual(PRODUCTION_BACKEND);
    expect(chooseBackend(null, none)).toEqual(PRODUCTION_BACKEND);
  });

  test("anywhere else the environment still wins where it is set", () => {
    expect(chooseBackend("127.0.0.1", stack)).toEqual(stack);
    expect(chooseBackend("id-preview--clove.lovable.app", stack)).toEqual(stack);
  });

  test("a host that only looks like the demonstration's is not it", () => {
    expect(chooseBackend("demo.cloveerp.com.example.net", none)).toEqual(PRODUCTION_BACKEND);
  });

  test("a subdomain nobody in this build knows is nobody's until the directory says so, never production's", () => {
    expect(chooseBackend("notdemo.cloveerp.com", none)).toBeNull();
    expect(chooseBackend("acme.cloveerp.com", none)).toBeNull();
    expect(chooseBackend("Acme.CloveERP.com", stack)).toBeNull();
    // Not under the apex at all: the environment, then production, as before.
    expect(chooseBackend("acme.cloveerp.com.example.net", none)).toEqual(PRODUCTION_BACKEND);
    expect(chooseBackend("acme.example.com", stack)).toEqual(stack);
  });

  test("every other name under the apex fails closed, whatever its shape, never production", () => {
    for (const host of [
      "ab.cloveerp.com",
      "a.cloveerp.com",
      "a.b.cloveerp.com",
      "abc.def.cloveerp.com",
      "-x.cloveerp.com",
      "x-.cloveerp.com",
      "a_b.cloveerp.com",
      `${"a".repeat(64)}.cloveerp.com`,
      "acme.cloveerp.com.",
      "ACME.CLOVEERP.COM.",
    ]) {
      expect(chooseBackend(host, none)).toBeNull();
      expect(chooseBackend(host, stack)).toBeNull();
    }
  });

  test("a fully qualified name is the same host as the one without its trailing dot", () => {
    expect(chooseBackend("demo.cloveerp.com.", none)).toEqual(DEMO_BACKEND);
    expect(chooseBackend("cloveerp.com.", none)).toEqual(PRODUCTION_BACKEND);
    expect(chooseBackend("www.cloveerp.com.", none)).toEqual(PRODUCTION_BACKEND);
    expect(normalHost(" Acme.CloveERP.com. ")).toBe("acme.cloveerp.com");
    expect(normalHost("cloveerp.com")).toBe("cloveerp.com");
  });

  test("a client's host is one label under the apex, and the label is its code", () => {
    expect(isClientHost("acme.cloveerp.com")).toBe(true);
    expect(clientCodeOf("Acme-Tools.cloveerp.com")).toBe("acme-tools");
    for (const notClient of [
      APEX_HOST,
      `www.${APEX_HOST}`,
      DEMO_HOST,
      "a.b.cloveerp.com",
      "-x.cloveerp.com",
      "localhost",
      null,
    ]) {
      expect(isClientHost(notClient)).toBe(false);
      expect(clientCodeOf(notClient)).toBeNull();
    }
  });

  test("a directory host is any name under the apex but the apex, www and the demonstration", () => {
    for (const host of [
      "acme.cloveerp.com",
      "ab.cloveerp.com",
      "a.cloveerp.com",
      "a.b.cloveerp.com",
      "-x.cloveerp.com",
      "acme.cloveerp.com.",
      "Acme.CloveERP.com",
    ]) {
      expect(isDirectoryHost(host)).toBe(true);
    }
    for (const host of [
      APEX_HOST,
      `www.${APEX_HOST}`,
      DEMO_HOST,
      "cloveerp.com.",
      "www.cloveerp.com.",
      "demo.cloveerp.com.",
      "acme.cloveerp.com.example.net",
      "notcloveerp.com",
      "acmecloveerp.com",
      "localhost",
      "127.0.0.1",
      null,
    ]) {
      expect(isDirectoryHost(host)).toBe(false);
    }
  });

  test("every host shaped like a client's is a directory host", () => {
    for (const host of ["acme.cloveerp.com", "acme-tools.cloveerp.com", "abc.cloveerp.com"]) {
      expect(isClientHost(host)).toBe(true);
      expect(isDirectoryHost(host)).toBe(true);
    }
  });

  test("the two projects are two, and each key belongs to its own", () => {
    expect(DEMO_BACKEND.url).not.toBe(PRODUCTION_BACKEND.url);
    expect(DEMO_BACKEND.url).toMatch(/^https:\/\/[a-z0-9]{20}\.supabase\.co$/);
    expect(PRODUCTION_BACKEND.url).toMatch(/^https:\/\/[a-z0-9]{20}\.supabase\.co$/);
    expect(DEMO_BACKEND.key.startsWith("sb_publishable_")).toBe(true);
    const ref = PRODUCTION_BACKEND.url.replace(/^https:\/\//, "").split(".")[0];
    const payload = JSON.parse(
      Buffer.from(PRODUCTION_BACKEND.key.split(".")[1] ?? "", "base64").toString("utf8"),
    ) as { ref?: string; role?: string };
    expect(payload.ref).toBe(ref);
    expect(payload.role).toBe("anon");
  });

  test("the demonstration's address is the host the choice is made on", () => {
    expect(DEMO_ADDRESS).toBe(`https://${DEMO_HOST}`);
  });

  test("with no page, there is no host", () => {
    expect(pageHost()).toBeNull();
  });
});

describe("where demonstrations are made", () => {
  test("production links to the demonstration instead of making one", () => {
    expect(demonstrationsLiveElsewhere({ deployment: "production" })).toBe(true);
  });

  test("the demonstration, and a database older than the marker, make them as before", () => {
    expect(demonstrationsLiveElsewhere({ deployment: "demonstration" })).toBe(false);
    expect(demonstrationsLiveElsewhere({})).toBe(false);
    expect(demonstrationsLiveElsewhere(undefined)).toBe(false);
  });
});

describe("the apex's own pages", () => {
  test("the public site is the apex and www, and nowhere else", () => {
    expect(isPublicSiteHost(APEX_HOST)).toBe(true);
    expect(isPublicSiteHost("www.cloveerp.com")).toBe(true);
    expect(isPublicSiteHost("CloveERP.com.")).toBe(true);
    for (const host of [DEMO_HOST, "acme.cloveerp.com", "ab.cloveerp.com", "localhost", null]) {
      expect(isPublicSiteHost(host)).toBe(false);
    }
  });

  test("are elsewhere on the demonstration and on every directory host", () => {
    for (const host of [DEMO_HOST, "demo.cloveerp.com.", "acme.cloveerp.com", "a.b.cloveerp.com"]) {
      expect(marketingIsElsewhere(host)).toBe(true);
    }
    for (const host of [APEX_HOST, "www.cloveerp.com", "localhost", "127.0.0.1", null]) {
      expect(marketingIsElsewhere(host)).toBe(false);
    }
  });

  test("a link to one goes to the apex from a host where they are elsewhere, and stays a path elsewhere", () => {
    expect(apexHref("/product", DEMO_HOST)).toBe(`${APEX_ORIGIN}/product`);
    expect(apexHref("/contact", "acme.cloveerp.com")).toBe(`${APEX_ORIGIN}/contact`);
    expect(apexHref("/product", APEX_HOST)).toBe("/product");
    expect(apexHref("/contact", "www.cloveerp.com")).toBe("/contact");
    expect(apexHref("/contact", "localhost")).toBe("/contact");
    expect(apexHref("/contact", null)).toBe("/contact");
  });

  test("asked for where they are elsewhere, the page is the apex's, query and all", () => {
    expect(apexRedirect("/product", "", DEMO_HOST)).toBe(`${APEX_ORIGIN}/product`);
    expect(apexRedirect("/contact", "?plan=growth", "acme.cloveerp.com")).toBe(
      `${APEX_ORIGIN}/contact?plan=growth`,
    );
    expect(apexRedirect("/product/", "", "ab.cloveerp.com")).toBe(`${APEX_ORIGIN}/product`);
  });

  test("anything else stays where it is", () => {
    expect(apexRedirect("/product", "", APEX_HOST)).toBeNull();
    expect(apexRedirect("/contact", "", "www.cloveerp.com")).toBeNull();
    expect(apexRedirect("/product", "", "localhost")).toBeNull();
    expect(apexRedirect("/product", "", null)).toBeNull();
    expect(apexRedirect("/signin", "", DEMO_HOST)).toBeNull();
    expect(apexRedirect("/", "", "acme.cloveerp.com")).toBeNull();
    expect(apexRedirect("/products", "", DEMO_HOST)).toBeNull();
  });
});
