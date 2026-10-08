import { describe, expect, test } from "bun:test";

import {
  APEX_HOST,
  DEMO_ADDRESS,
  DEMO_BACKEND,
  DEMO_HOST,
  PRODUCTION_BACKEND,
  chooseBackend,
  clientCodeOf,
  isClientHost,
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
