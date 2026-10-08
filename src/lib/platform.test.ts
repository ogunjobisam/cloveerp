import { describe, expect, test } from "bun:test";

import {
  buildRecovery,
  buildRequestIsStale,
  customerChoices,
  customerChoiceText,
  deploymentAddress,
  hostOfOrigin,
  isPlatformOperator,
  organisationWhere,
  STALE_BUILD_REQUEST_MINUTES,
  type BuildRequestView,
} from "./platform";

describe("who runs the product for customers", () => {
  test("platform operators and owners", () => {
    expect(isPlatformOperator({ is_staff: true, role: "operator" })).toBe(true);
    expect(isPlatformOperator({ is_staff: true, role: "owner" })).toBe(true);
  });

  test("not support staff, and not a customer", () => {
    expect(isPlatformOperator({ is_staff: true, role: "support" })).toBe(false);
    expect(isPlatformOperator({ is_staff: false, role: null })).toBe(false);
  });

  test("not anybody whose answer has not arrived, or says staff with no role", () => {
    expect(isPlatformOperator(undefined)).toBe(false);
    expect(isPlatformOperator({ is_staff: true, role: null })).toBe(false);
  });
});

describe("a build that has stalled", () => {
  const NOW = new Date("2026-10-08T12:00:00Z");
  const ago = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000).toISOString();
  const row = (over: Partial<BuildRequestView> = {}): BuildRequestView => ({
    status: "requested",
    request_status: "requested",
    request_created_at: ago(5),
    request_claimed_at: null,
    request_settled_at: null,
    last_event: null,
    ...over,
  });

  test("twenty minutes is the line", () => {
    expect(STALE_BUILD_REQUEST_MINUTES).toBe(20);
    expect(buildRequestIsStale(row({ request_created_at: ago(19) }), NOW)).toBe(false);
    expect(buildRequestIsStale(row({ request_created_at: ago(20) }), NOW)).toBe(true);
  });

  test("a queued request is stale once it is twenty minutes old", () => {
    expect(buildRecovery(row({ request_created_at: ago(5) }), NOW)).toBeNull();
    expect(buildRecovery(row({ request_created_at: ago(25) }), NOW)).toBe("start-again");
  });

  test("a claimed request is judged from its claim, not its age alone", () => {
    const late = row({
      request_status: "claimed",
      request_created_at: ago(40),
      request_claimed_at: ago(3),
    });
    expect(buildRequestIsStale(late, NOW)).toBe(false);
    expect(buildRecovery(late, NOW)).toBeNull();
    const lost = row({
      request_status: "claimed",
      request_created_at: ago(40),
      request_claimed_at: ago(30),
    });
    expect(buildRecovery(lost, NOW)).toBe("start-again");
  });

  test("a done request whose run never got going is stale twenty minutes after the last sign of it", () => {
    const quiet = row({
      request_status: "done",
      request_created_at: ago(60),
      request_claimed_at: ago(55),
      request_settled_at: ago(50),
      last_event: { phase: "dispatch", status: "done", detail: "run 1 started", at: ago(49) },
    });
    expect(buildRecovery(quiet, NOW)).toBe("start-again");
    const moving = row({
      request_status: "done",
      request_settled_at: ago(50),
      last_event: { phase: "dispatch", status: "done", detail: "run 1 started", at: ago(4) },
    });
    expect(buildRecovery(moving, NOW)).toBeNull();
    const fresh = row({ request_status: "done", request_settled_at: ago(2), last_event: null });
    expect(buildRecovery(fresh, NOW)).toBeNull();
  });

  test("without the times nothing is judged stale, and nothing is offered while in flight", () => {
    const blind = row({ request_created_at: null, request_claimed_at: null });
    expect(buildRequestIsStale(blind, NOW)).toBe(false);
    expect(buildRecovery(blind, NOW)).toBeNull();
    const old = row({
      request_status: "done",
      request_settled_at: null,
      last_event: { phase: "retry", status: "done", detail: null, at: ago(90) },
    });
    expect(buildRecovery(old, NOW)).toBeNull();
    expect(buildRequestIsStale(row({ request_created_at: "not a date" }), NOW)).toBe(false);
  });

  test("the database's own answer decides Start again when the register gives it", () => {
    const now = row({ request_created_at: ago(5), restartable: true });
    expect(buildRecovery(now, NOW)).toBe("start-again");
    const refused = row({
      request_status: "done",
      request_created_at: ago(60),
      request_claimed_at: ago(55),
      request_settled_at: ago(50),
      last_event: { phase: "dispatch", status: "done", detail: "run 1 started", at: ago(49) },
      restartable: false,
    });
    expect(buildRecovery(refused, NOW)).toBe("retry");
    const waiting = row({ request_created_at: ago(30), restartable: false });
    expect(buildRecovery(waiting, NOW)).toBeNull();
  });

  test("Retry stays for a failed build, and for a request that is not in flight", () => {
    expect(buildRecovery(row({ status: "failed", request_status: "done" }), NOW)).toBe("retry");
    for (const s of ["failed", "cancelled", null] as const) {
      expect(buildRecovery(row({ request_status: s, request_created_at: ago(90) }), NOW)).toBe(
        "retry",
      );
      expect(
        buildRequestIsStale(row({ request_status: s, request_created_at: ago(90) }), NOW),
      ).toBe(false);
    }
  });

  test("nothing while a build runs, or once it is built", () => {
    for (const status of ["creating", "building", "built", "live", "retired"] as const) {
      expect(buildRecovery(row({ status, request_created_at: ago(90) }), NOW)).toBeNull();
      expect(buildRequestIsStale(row({ status, request_created_at: ago(90) }), NOW)).toBe(false);
    }
  });
});

describe("addresses", () => {
  test("an origin's host, or nothing", () => {
    expect(hostOfOrigin("https://acme.cloveerp.com")).toBe("acme.cloveerp.com");
    expect(hostOfOrigin("https://acme.cloveerp.com/")).toBe("acme.cloveerp.com");
    expect(hostOfOrigin(" https://cloveerp.com ")).toBe("cloveerp.com");
    expect(hostOfOrigin("")).toBeNull();
    expect(hostOfOrigin(null)).toBeNull();
    expect(hostOfOrigin(undefined)).toBeNull();
    expect(hostOfOrigin("acme")).toBeNull();
  });

  test("a client deployment reads as its subdomain", () => {
    expect(deploymentAddress({ code: "acme", origin: "https://acme.cloveerp.com" })).toBe(
      "acme.cloveerp.com",
    );
    expect(deploymentAddress({ code: "acme", origin: "" })).toBe("acme.cloveerp.com");
  });

  test("on the control plane an organisation is shared, at cloveerp.com/<code>", () => {
    const me = { deployment: "production" as const, origin: "https://cloveerp.com" };
    expect(organisationWhere("clove-foods", me)).toBe("cloveerp.com/clove-foods, shared");
    expect(organisationWhere("clove-foods", undefined)).toBe("cloveerp.com/clove-foods, shared");
  });

  test("on a client the organisation is at the project's own address", () => {
    expect(
      organisationWhere("acme", { deployment: "client", origin: "https://acme.cloveerp.com" }),
    ).toBe("acme.cloveerp.com, own project");
    expect(organisationWhere("acme", { deployment: "client", origin: null })).toBe(
      "this address, own project",
    );
  });

  test("on the demonstration organisations share its project", () => {
    expect(
      organisationWhere("demo-1c8dad90", {
        deployment: "demonstration",
        origin: "https://demo.cloveerp.com",
      }),
    ).toBe("demo.cloveerp.com, shared");
    expect(organisationWhere("demo-1", { deployment: "demonstration", origin: null })).toBe(
      "demo.cloveerp.com, shared",
    );
  });
});

describe("who a contract or quote can be for", () => {
  const candidates = [
    { code: "clove", name: "Clove ERP Ltd", is_demonstration: false },
    { code: "clove-foods", name: "Clove Foods", is_demonstration: false },
    { code: "demo-1", name: "Demo", is_demonstration: true },
  ];

  test("organisations first, less demonstrations and the platform organisation, then deployments", () => {
    const choices = customerChoices(
      candidates,
      [
        { code: "acme", name: "Acme Ltd", status: "live" },
        { code: "bolt", name: "Bolt", status: "requested" },
      ],
      "clove",
    );
    expect(choices).toEqual([
      { code: "clove-foods", name: "Clove Foods", where: "organisation" },
      { code: "acme", name: "Acme Ltd", where: "deployment" },
      { code: "bolt", name: "Bolt", where: "deployment" },
    ]);
  });

  test("a deployment being retired, or retired, is not offered", () => {
    const choices = customerChoices(
      [],
      [
        { code: "gone", name: "Gone", status: "retired" },
        { code: "going", name: "Going", status: "retiring" },
        { code: "kept", name: "Kept", status: "suspended" },
      ],
      null,
    );
    expect(choices.map((c) => c.code)).toEqual(["kept"]);
  });

  test("a database that lists no deployments offers its organisations as before", () => {
    expect(customerChoices(candidates, undefined, "clove").map((c) => c.code)).toEqual([
      "clove-foods",
    ]);
    expect(customerChoices(candidates, null, null).map((c) => c.code)).toEqual([
      "clove",
      "clove-foods",
    ]);
  });

  test("a code held by an organisation is the organisation's", () => {
    const choices = customerChoices(
      [{ code: "acme", name: "Acme", is_demonstration: false }],
      [{ code: "acme", name: "Acme", status: "live" }],
      null,
    );
    expect(choices).toEqual([{ code: "acme", name: "Acme", where: "organisation" }]);
  });

  test("a deployment says it is one in a picker", () => {
    expect(customerChoiceText({ code: "acme", name: "Acme Ltd", where: "deployment" })).toBe(
      "Acme Ltd (acme), client deployment at acme.cloveerp.com",
    );
    expect(customerChoiceText({ code: "clove-foods", name: "Clove Foods" })).toBe(
      "Clove Foods (clove-foods)",
    );
    expect(
      customerChoiceText({ code: "clove-foods", name: "Clove Foods", where: "organisation" }),
    ).toBe("Clove Foods (clove-foods)");
  });
});
