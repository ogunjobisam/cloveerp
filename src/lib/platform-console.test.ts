import { describe, expect, test } from "bun:test";

import {
  CONSOLE_SECTIONS,
  consoleSearch,
  isDemoCode,
  locate,
  parseConsoleSearch,
  sectionsFor,
} from "./platform-console";

describe("the console's address", () => {
  test("a bookmark to an organisation's page reads back as that page", () => {
    const search = parseConsoleSearch({
      section: "customers",
      view: "organisations",
      org: "demo-cbb10384",
    });
    expect(search).toEqual({ section: "customers", view: "organisations", org: "demo-cbb10384" });
    const place = locate(search);
    expect(place.section.key).toBe("customers");
    expect(place.view.key).toBe("organisations");
    expect(place.org).toBe("demo-cbb10384");
  });

  test("the bare address is Today", () => {
    expect(parseConsoleSearch({})).toEqual({});
    expect(locate({}).section.key).toBe("today");
    expect(locate({}).view.key).toBe("today");
  });

  test("a section with no view opens its first tab", () => {
    expect(parseConsoleSearch({ section: "platform" })).toEqual({
      section: "platform",
      view: "health",
    });
    expect(parseConsoleSearch({ section: "sales", view: "" })).toEqual({
      section: "sales",
      view: "enquiries",
    });
  });

  test("an unknown section or view falls back to Today, never to a guess", () => {
    expect(parseConsoleSearch({ section: "overview" })).toEqual({});
    expect(parseConsoleSearch({ section: "customers", view: "contracts" })).toEqual({});
    expect(parseConsoleSearch({ section: "sales", view: "nonsense" })).toEqual({});
    expect(parseConsoleSearch({ section: 7, view: ["x"] })).toEqual({});
    expect(locate(parseConsoleSearch({ section: "health" })).section.key).toBe("today");
  });

  test("an organisation is kept only where there is a page to show it on", () => {
    expect(parseConsoleSearch({ section: "sales", view: "contracts", org: "acme" })).toEqual({
      section: "sales",
      view: "contracts",
    });
    expect(parseConsoleSearch({ section: "customers", view: "ownership", org: "acme" })).toEqual({
      section: "customers",
      view: "ownership",
    });
    expect(parseConsoleSearch({ section: "customers", org: "acme" })).toEqual({
      section: "customers",
      view: "organisations",
      org: "acme",
    });
  });

  test("an organisation code that looks like a number survives the router's parser", () => {
    expect(parseConsoleSearch({ section: "customers", view: "organisations", org: 1234 }).org).toBe(
      "1234",
    );
  });

  test("a blank or absurd organisation code is dropped", () => {
    expect(
      parseConsoleSearch({ section: "customers", view: "organisations", org: "   " }).org,
    ).toBeUndefined();
    expect(
      parseConsoleSearch({ section: "customers", view: "organisations", org: "x".repeat(101) }).org,
    ).toBeUndefined();
  });

  test("links are built from the same reading", () => {
    expect(consoleSearch("today")).toEqual({});
    expect(consoleSearch("billing")).toEqual({ section: "billing", view: "revenue" });
    expect(consoleSearch("customers", "organisations", "acme")).toEqual({
      section: "customers",
      view: "organisations",
      org: "acme",
    });
  });

  test("every view key is unique across the console, so a key names one tab", () => {
    const keys = CONSOLE_SECTIONS.flatMap((s) => s.views.map((v) => v.key));
    expect(new Set(keys).size).toBe(keys.length);
  });

  test("the sections the owner asked for, in order", () => {
    expect(CONSOLE_SECTIONS.map((s) => s.label)).toEqual([
      "Today",
      "Customers",
      "Sales",
      "Catalogue",
      "Billing",
      "Platform",
    ]);
  });
});

describe("the console a deployment offers", () => {
  const views = (deployment: Parameters<typeof sectionsFor>[0]) =>
    sectionsFor(deployment).flatMap((s) => s.views.map((v) => `${s.key}/${v.key}`));

  test("the control plane offers everything, including the register of client deployments", () => {
    expect(sectionsFor("production").map((s) => s.key)).toEqual(CONSOLE_SECTIONS.map((s) => s.key));
    expect(views("production")).toContain("customers/fleet");
  });

  test("a client's own console has no Sales, Catalogue or Billing, and no register", () => {
    expect(sectionsFor("client").map((s) => s.key)).toEqual(["today", "customers", "platform"]);
    expect(views("client")).not.toContain("customers/fleet");
    expect(views("client")).toContain("customers/organisations");
  });

  test("the demonstration, and a database older than the marker, are as they were, less the register", () => {
    for (const d of ["demonstration", undefined] as const) {
      expect(sectionsFor(d).map((s) => s.key)).toEqual(CONSOLE_SECTIONS.map((s) => s.key));
      expect(views(d)).not.toContain("customers/fleet");
    }
  });
});

describe("a demonstration organisation", () => {
  test("is one whose code starts demo-", () => {
    expect(isDemoCode("demo-cbb10384")).toBe(true);
    expect(isDemoCode("acme")).toBe(false);
    expect(isDemoCode("my-demo-co")).toBe(false);
    expect(isDemoCode(null)).toBe(false);
  });
});
