import { describe, expect, test } from "bun:test";

import {
  codesOf,
  deliveryWords,
  deploymentCountOf,
  deploymentSummary,
  deploymentsOf,
  everyClientChange,
  everyClientNowWords,
  everyClientOf,
  isReceived,
  mergeDeployments,
  namedWords,
  noticeReach,
  reachWords,
  readNamed,
  receivedAtOf,
  receivedCopy,
  withEveryClient,
  withEveryClientChange,
  type DeploymentReached,
} from "./incident-reach";

/**
 * What the incidents console and the service banner read off the incident
 * doors once incidents and maintenance reach every client (20261012060000).
 * Every key is new, so each case also holds a row from an older database —
 * one that says none of them — to what it always showed.
 */

const T1 = "2026-10-09T10:15:00Z";
const T2 = "2026-10-09T10:20:00Z";
const T3 = "2026-10-09T10:25:00Z";
const plain = (iso: string) => iso;

function reached(code: string, over: Partial<DeploymentReached> = {}): DeploymentReached {
  return { code, reach: null, namedAt: null, namedBy: null, sentAt: null, toldAt: null, ...over };
}

describe("a received copy", () => {
  test("is one that says when it arrived, or says it was received", () => {
    expect(isReceived({ code: "INC-1", received_at: T1 })).toBe(true);
    expect(receivedAtOf({ code: "INC-1", received_at: T1 })).toBe(T1);
    expect(isReceived({ code: "INC-1", received: true })).toBe(true);
    expect(receivedAtOf({ code: "INC-1", received: true })).toBeNull();
  });

  test("one made here, and a row from an older database, are not", () => {
    expect(isReceived({ code: "INC-1", received_at: null })).toBe(false);
    expect(isReceived({ code: "INC-1" })).toBe(false);
    expect(isReceived({ code: "INC-1", received_at: "" })).toBe(false);
    expect(isReceived({ code: "INC-1", received_at: "not a time" })).toBe(false);
    expect(isReceived({ code: "INC-1", received: "yes" })).toBe(false);
    expect(isReceived(null)).toBe(false);
    expect(isReceived(["INC-1"])).toBe(false);
  });

  test("the code typed into the console finds it, and only it", () => {
    const rows = [
      { code: "INC-1", received_at: T1 },
      { code: "INC-2", received_at: null },
    ];
    expect(receivedCopy("INC-1", rows)).toEqual({ code: "INC-1", receivedAt: T1 });
    expect(receivedCopy("  INC-1 ", rows)).toEqual({ code: "INC-1", receivedAt: T1 });
    expect(receivedCopy("INC-2", rows)).toBeNull();
    expect(receivedCopy("INC-3", rows)).toBeNull();
    expect(receivedCopy("", rows)).toBeNull();
    expect(receivedCopy("INC-1", undefined)).toBeNull();
  });
});

describe("every client", () => {
  test("is said only where the door says it", () => {
    expect(everyClientOf({ every_client: true })).toBe(true);
    expect(everyClientOf({ every_client: false })).toBe(false);
    expect(everyClientOf({ affects_all_tenants: true })).toBeNull();
    expect(everyClientOf({ every_client: "true" })).toBeNull();
    expect(everyClientOf(undefined)).toBeNull();
  });

  test("is sent last, and only when it is chosen", () => {
    const args = { p_code: "INC-1", p_scope: "pick", p_affects_all_tenants: false };
    const chosen = withEveryClient(args, true);
    expect(chosen).toEqual({ ...args, p_every_client: true });
    expect(Object.keys(chosen).at(-1)).toBe("p_every_client");
    expect(withEveryClient(args, false)).toEqual(args);
    expect("p_every_client" in withEveryClient(args, false)).toBe(false);
  });

  test("containing sends true or false when the form says other than the incident does", () => {
    // Said now, or withdrawn now: sent as said.
    expect(everyClientChange(false, true)).toBe(true);
    expect(everyClientChange(true, false)).toBe(false);
    // The same as the incident says, or untouched: nothing, which is "as declared".
    expect(everyClientChange(true, true)).toBeNull();
    expect(everyClientChange(false, false)).toBeNull();
    expect(everyClientChange(true, null)).toBeNull();
    expect(everyClientChange(false, null)).toBeNull();
    // Not known what the incident says: only a yes is sent.
    expect(everyClientChange(null, true)).toBe(true);
    expect(everyClientChange(null, false)).toBeNull();
    expect(everyClientChange(null, null)).toBeNull();

    const args = { p_code: "INC-1", p_scope: "pick", p_affects_all_tenants: false };
    const withdrawn = withEveryClientChange(args, true, false);
    expect(withdrawn).toEqual({ ...args, p_every_client: false });
    expect(Object.keys(withdrawn).at(-1)).toBe("p_every_client");
    expect(withEveryClientChange(args, false, true)).toEqual({ ...args, p_every_client: true });
    expect(withEveryClientChange(args, true, true)).toEqual(args);
    expect("p_every_client" in withEveryClientChange(args, true, null)).toBe(false);
  });

  test("the containment form says what the incident says now", () => {
    expect(everyClientNowWords(true)).toBe("Now it reaches every client deployment.");
    expect(everyClientNowWords(false)).toBe("Now it reaches only the client deployments named.");
    expect(everyClientNowWords(null)).toBeNull();
  });
});

describe("the client deployments reached", () => {
  test("a row's deployments are read under either name the ledger gives them", () => {
    const row = {
      code: "INC-1",
      deployments: [
        {
          code: "acme",
          named_at: T1,
          named_by: "ops@clove",
          last_pushed_at: T2,
          client_told_at: T3,
        },
        { deployment_code: "bravo", pushed_at: T2, told_at: null },
        { named_at: T1 },
        "carl",
        null,
      ],
    };
    expect(deploymentsOf(row)).toEqual([
      { code: "acme", reach: null, namedAt: T1, namedBy: "ops@clove", sentAt: T2, toldAt: T3 },
      { code: "bravo", reach: null, namedAt: null, namedBy: null, sentAt: T2, toldAt: null },
    ]);
    expect(deploymentCountOf(row)).toBe(2);
  });

  test("how each was reached is read from the ledger's own word", () => {
    const row = {
      deployments: [
        { code: "acme", reach: "named", named_at: T1, named_by: "ops" },
        { code: "bravo", reach: "every_client", named_at: T2, named_by: null },
        { code: "carl", reach: "something else", named_at: T1 },
      ],
    };
    expect(deploymentsOf(row).map((d) => [d.code, d.reach])).toEqual([
      ["acme", "named"],
      ["bravo", "every_client"],
      ["carl", null],
    ]);
  });

  test("a count instead of a list is a count, and an older row says nothing", () => {
    expect(deploymentsOf({ deployments: 3 })).toEqual([]);
    expect(deploymentCountOf({ deployments: 3 })).toBe(3);
    expect(deploymentCountOf({ deployments: "3" })).toBe(3);
    expect(deploymentCountOf({ deployments: -1 })).toBeNull();
    expect(deploymentCountOf({ code: "INC-1" })).toBeNull();
    expect(deploymentsOf({ code: "INC-1" })).toEqual([]);
    expect(deploymentsOf(undefined)).toEqual([]);
  });

  test("two doors' lists are one: a code once, each time the newest either knew", () => {
    const merged = mergeDeployments(
      [reached("bravo", { sentAt: T1 }), reached("acme", { namedAt: T1, namedBy: "ops" })],
      [reached("acme", { sentAt: T2, toldAt: T3 }), reached("bravo", { sentAt: T2 })],
    );
    expect(merged).toEqual([
      { code: "acme", reach: null, namedAt: T1, namedBy: "ops", sentAt: T2, toldAt: T3 },
      { code: "bravo", reach: null, namedAt: null, namedBy: null, sentAt: T2, toldAt: null },
    ]);
    // How it was reached is kept from whichever list said it.
    expect(
      mergeDeployments([reached("acme")], [reached("acme", { reach: "every_client" })])[0]!.reach,
    ).toBe("every_client");
    // An older send never overwrites a newer one.
    expect(
      mergeDeployments([reached("acme", { sentAt: T3 })], [reached("acme", { sentAt: T1 })])[0]!
        .sentAt,
    ).toBe(T3);
  });
});

describe("who has been named", () => {
  test("the organisations door as it has always answered", () => {
    const named = readNamed([
      { tenant_code: "clove-foods", named_at: T1, named_by: "ops" },
      { tenant_code: "" },
      "nonsense",
    ]);
    expect(named.organisations).toEqual([{ code: "clove-foods", namedAt: T1, namedBy: "ops" }]);
    expect(named.deployments).toEqual([]);
    expect(namedWords(named)).toBe("Named: clove-foods");
  });

  test("rows that are deployments are read as deployments", () => {
    const named = readNamed([
      { tenant_code: "clove-foods", named_at: T1, named_by: "ops" },
      { deployment_code: "acme", named_at: T1, named_by: "ops", last_pushed_at: T2 },
    ]);
    expect(named.organisations.map((o) => o.code)).toEqual(["clove-foods"]);
    expect(named.deployments).toEqual([
      { code: "acme", reach: null, namedAt: T1, namedBy: "ops", sentAt: T2, toldAt: null },
    ]);
    expect(namedWords(named)).toBe("Named: clove-foods; client deployments: acme");
  });

  test("a deployment reached as every client is not said to be named", () => {
    const named = readNamed([
      { tenant_code: "clove-foods", named_at: T1, named_by: "ops" },
      { deployment_code: "acme", reach: "named", named_at: T1, named_by: "ops" },
      { deployment_code: "bravo", reach: "every_client", named_at: T2, named_by: null },
    ]);
    expect(namedWords(named)).toBe(
      "Named: clove-foods; client deployments: acme; reached as every client: bravo",
    );
    expect(namedWords({ organisations: [], deployments: [named.deployments[1]!] })).toBe(
      "Reached as every client: bravo",
    );
    expect(
      namedWords({ organisations: named.organisations, deployments: [named.deployments[1]!] }),
    ).toBe("Named: clove-foods; reached as every client: bravo");
  });

  test("one object holding the two lists", () => {
    const named = readNamed({
      organisations: [{ tenant_code: "clove-foods" }],
      deployments: [{ code: "bravo" }, { code: "acme", client_told_at: T3 }],
    });
    expect(named.organisations.map((o) => o.code)).toEqual(["clove-foods"]);
    expect(named.deployments.map((d) => d.code)).toEqual(["acme", "bravo"]);
    expect(namedWords({ organisations: [], deployments: named.deployments })).toBe(
      "Named client deployments: acme, bravo",
    );
  });

  test("nothing, or nothing readable, is nobody named", () => {
    for (const raw of [null, undefined, [], {}, "x", 4]) {
      const named = readNamed(raw);
      expect(named).toEqual({ organisations: [], deployments: [] });
      expect(namedWords(named)).toBe(
        "Nobody named yet: everyone, or nobody, depending on the scope declared.",
      );
    }
  });
});

describe("how a deployment was reached, in plain words", () => {
  test("named, when and by whom", () => {
    expect(
      reachWords(reached("acme", { reach: "named", namedAt: T1, namedBy: "ops" }), plain),
    ).toBe(`Named ${T1} by ops`);
    expect(reachWords(reached("acme", { reach: "named", namedAt: T1 }), plain)).toBe(`Named ${T1}`);
    expect(reachWords(reached("acme", { reach: "named" }), plain)).toBe("Named");
  });

  test("as every client, from when the sweep first handed it out, never as named", () => {
    expect(
      reachWords(reached("acme", { reach: "every_client", namedAt: T2, namedBy: null }), plain),
    ).toBe(`Reached as every client, ${T2}`);
    expect(reachWords(reached("acme", { reach: "every_client" }), plain)).toBe(
      "Reached as every client",
    );
  });

  test("a door that does not say how reads as it always did", () => {
    expect(reachWords(reached("acme", { namedAt: T1, namedBy: "ops" }), plain)).toBe(
      `Named ${T1} by ops`,
    );
    expect(reachWords(reached("acme"), plain)).toBe("Reached as every client");
  });
});

describe("sent and told, in plain words", () => {
  test("an incident not yet sent, sent, and told", () => {
    expect(deliveryWords(reached("acme"), { tells: true, time: plain })).toBe("Not sent yet");
    expect(deliveryWords(reached("acme", { sentAt: T1 }), { tells: true, time: plain })).toBe(
      `Sent ${T1}; its people not told yet`,
    );
    expect(
      deliveryWords(reached("acme", { sentAt: T1, toldAt: T2 }), { tells: true, time: plain }),
    ).toBe(`Sent ${T1}; its people told ${T2}`);
  });

  test("a window is sent; told is said only where the client says it", () => {
    expect(deliveryWords(reached("acme", { sentAt: T1 }), { tells: false, time: plain })).toBe(
      `Sent ${T1}`,
    );
    expect(
      deliveryWords(reached("acme", { sentAt: T1, toldAt: T2 }), { tells: false, time: plain }),
    ).toBe(`Sent ${T1}; its people told ${T2}`);
  });

  test("the reader's own clock by default", () => {
    expect(deliveryWords(reached("acme", { sentAt: T1 }))).toMatch(/^Sent \d{1,2} Oct 2026, /);
  });

  test("a row's line: every client, how many, how many told", () => {
    const two = [reached("acme", { sentAt: T1, toldAt: T2 }), reached("bravo", { sentAt: T1 })];
    expect(deploymentSummary(true, [], null)).toBe("every client");
    expect(deploymentSummary(true, two, null)).toBe("every client · 2 client deployments, 1 told");
    expect(deploymentSummary(false, two, null)).toBe("2 client deployments, 1 told");
    expect(deploymentSummary(null, [two[0]!], null)).toBe("1 client deployment, 1 told");
    expect(deploymentSummary(null, [], 3)).toBe("3 client deployments");
    expect(deploymentSummary(null, [], null)).toBeNull();
    expect(deploymentSummary(false, [], 0)).toBeNull();
  });
});

describe("the codes typed", () => {
  test("organisations and deployments, by code or address, once each", () => {
    expect(codesOf("clove-foods, acme")).toEqual(["clove-foods", "acme"]);
    expect(codesOf(" acme ,acme.cloveerp.com;\nbravo  acme ")).toEqual([
      "acme",
      "acme.cloveerp.com",
      "bravo",
    ]);
  });

  test("nothing typed is nobody, not an empty list", () => {
    expect(codesOf("")).toBeNull();
    expect(codesOf(" , ; ")).toBeNull();
  });
});

describe("who the banner says an incident affects", () => {
  test("a copy the control plane sent affects this service", () => {
    expect(noticeReach({ affects_all_tenants: true, received_at: T1 }, false)).toBe("service");
    expect(noticeReach({ affects_all_tenants: true, received_at: T1 }, true)).toBe("service");
    expect(noticeReach({ affects_all_tenants: false, received: true }, false)).toBe("service");
  });

  test("on a client's own service every organisation is this one", () => {
    expect(noticeReach({ affects_all_tenants: true }, true)).toBe("service");
  });

  test("elsewhere every organisation is said as it always was", () => {
    expect(noticeReach({ affects_all_tenants: true }, false)).toBe("everyone");
    expect(noticeReach({ affects_all_tenants: true, received_at: null }, false)).toBe("everyone");
  });

  test("an incident named against this organisation alone says nothing more", () => {
    expect(noticeReach({ affects_all_tenants: false }, false)).toBeNull();
    expect(noticeReach({ affects_all_tenants: false }, true)).toBeNull();
    expect(noticeReach({}, true)).toBeNull();
    expect(noticeReach(null, true)).toBeNull();
  });
});
