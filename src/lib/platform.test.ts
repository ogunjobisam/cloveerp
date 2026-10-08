import { describe, expect, test } from "bun:test";

import {
  agoText,
  buildRecovery,
  buildRequestIsStale,
  customerChoices,
  customerChoiceText,
  databaseSizeText,
  dayText,
  deploymentAddress,
  deploymentHealthLine,
  deploymentLifecycleNotes,
  deploymentOrigin,
  earliestPurgeDate,
  fleetActions,
  hostOfOrigin,
  isDeploymentAddress,
  isPlatformOperator,
  lastExportText,
  OFFBOARDING_COOL_OFF_DAYS,
  organisationWhere,
  STALE_BUILD_REQUEST_MINUTES,
  SWEEP_STARTS,
  type BuildRequestView,
  type ClientDeployment,
  type ClientDeploymentStatus,
  type DeploymentHealth,
  type FleetAction,
  type PlatformRole,
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

  test("a renamed deployment reads as its address, under its origin's apex, and its code stays", () => {
    // The register's origin may still spell the code; the address is what is served.
    const renamed = { code: "acme", origin: "https://acme.cloveerp.com", address: "acme-group" };
    expect(deploymentAddress(renamed)).toBe("acme-group.cloveerp.com");
    expect(deploymentOrigin(renamed)).toBe("https://acme-group.cloveerp.com");
    expect(deploymentAddress({ ...renamed, origin: "https://acme.example.test" })).toBe(
      "acme-group.example.test",
    );
    expect(deploymentAddress({ ...renamed, origin: "" })).toBe("acme-group.cloveerp.com");
    // A register older than renaming gives no address: the origin, then the code.
    expect(deploymentOrigin({ code: "acme", origin: "https://acme.cloveerp.com" })).toBe(
      "https://acme.cloveerp.com",
    );
    expect(deploymentAddress({ code: "acme", origin: "", address: "" })).toBe("acme.cloveerp.com");
  });

  test("an address a deployment can be given has the database's shape", () => {
    for (const ok of ["acme", "acme-group", "a1b", "0ab", `a${"b".repeat(61)}c`]) {
      expect(isDeploymentAddress(ok)).toBe(true);
    }
    for (const bad of [
      "",
      "ab",
      "-acme",
      "acme-",
      "Acme",
      "acme group",
      "acme.group",
      "acme_group",
      `a${"b".repeat(62)}c`,
    ]) {
      expect(isDeploymentAddress(bad)).toBe(false);
    }
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

describe("how long ago", () => {
  const NOW = new Date("2026-10-08T12:00:00Z");
  const ago = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000).toISOString();

  test("minutes, then hours up to two days, then days", () => {
    expect(agoText(ago(0), NOW)).toBe("just now");
    expect(agoText(ago(0.5), NOW)).toBe("just now");
    expect(agoText(ago(1), NOW)).toBe("1 minute ago");
    expect(agoText(ago(59), NOW)).toBe("59 minutes ago");
    expect(agoText(ago(60), NOW)).toBe("1 hour ago");
    expect(agoText(ago(119), NOW)).toBe("1 hour ago");
    expect(agoText(ago(26 * 60), NOW)).toBe("26 hours ago");
    expect(agoText(ago(47 * 60 + 59), NOW)).toBe("47 hours ago");
    expect(agoText(ago(48 * 60), NOW)).toBe("2 days ago");
    expect(agoText(ago(10 * 24 * 60), NOW)).toBe("10 days ago");
  });

  test("a time ahead of the clock is just now; one that cannot be read is nothing", () => {
    expect(agoText(ago(-5), NOW)).toBe("just now");
    expect(agoText("not a time", NOW)).toBeNull();
    expect(agoText(null, NOW)).toBeNull();
    expect(agoText(undefined, NOW)).toBeNull();
  });
});

describe("a database's size", () => {
  const MB = 1_048_576;

  test("in megabytes, with a decimal under ten and thousands grouped above", () => {
    expect(databaseSizeText(0)).toBe("0.0 MB");
    expect(databaseSizeText(8.44 * MB)).toBe("8.4 MB");
    expect(databaseSizeText(9.96 * MB)).toBe("10 MB");
    expect(databaseSizeText(312.4 * MB)).toBe("312 MB");
    expect(databaseSizeText(1536 * MB)).toBe("1,536 MB");
    expect(databaseSizeText(1_234_567 * MB)).toBe("1,234,567 MB");
  });

  test("nothing for what is not a size", () => {
    expect(databaseSizeText(-1)).toBeNull();
    expect(databaseSizeText(Number.NaN)).toBeNull();
    expect(databaseSizeText(Number.POSITIVE_INFINITY)).toBeNull();
    expect(databaseSizeText(null)).toBeNull();
    expect(databaseSizeText(undefined)).toBeNull();
  });
});

describe("a deployment's health line", () => {
  const NOW = new Date("2026-10-08T12:00:00Z");
  const ago = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000).toISOString();
  type Row = Pick<ClientDeployment, "status" | "health" | "health_at" | "silent">;
  const healthy: DeploymentHealth = {
    release_sha: "6f0bd91a2b3c4d5e",
    assurance_failures: 0,
    assurance_at: ago(30),
    database_bytes: 312 * 1_048_576,
    last_drain_pass_at: ago(2),
    open_support_windows: 0,
    staff_in_step: true,
    backups_latest_at: ago(6 * 60),
    backups_count: 7,
    errors: [],
    polled_at: ago(5),
  };
  const row = (over: Partial<Row> = {}): Row => ({
    status: "live",
    health: healthy,
    health_at: ago(5),
    silent: false,
    ...over,
  });
  const texts = (r: Row) => deploymentHealthLine(r, NOW)?.parts.map((p) => p.text) ?? null;

  test("a healthy deployment: every phrase, in order, and only assurance in colour", () => {
    const line = deploymentHealthLine(row(), NOW);
    expect(line?.silence).toBeNull();
    expect(line?.errors).toEqual([]);
    expect(line?.parts).toEqual([
      { key: "polled", text: "polled 5 minutes ago", tone: "muted" },
      { key: "assurance", text: "assurance clean", tone: "ok" },
      { key: "size", text: "database 312 MB", tone: "muted" },
      { key: "drain", text: "queue drained 2 minutes ago", tone: "muted" },
      { key: "support", text: "no support window open", tone: "muted" },
      { key: "staff", text: "staff in step", tone: "muted" },
      { key: "backup", text: "backup 6 hours ago (7 kept)", tone: "muted" },
    ]);
  });

  test("what wants attention is coloured for it", () => {
    const line = deploymentHealthLine(
      row({
        health: {
          ...healthy,
          assurance_failures: 2,
          open_support_windows: 1,
          staff_in_step: false,
          backups_count: 0,
          backups_latest_at: null,
          errors: ["the backups could not be listed: 429", "  ", "pooler timed out "],
        },
      }),
      NOW,
    );
    expect(line?.parts.filter((p) => p.tone !== "muted")).toEqual([
      { key: "assurance", text: "2 assurance checks failing", tone: "bad" },
      { key: "support", text: "1 support window open", tone: "warn" },
      { key: "staff", text: "staff out of step", tone: "warn" },
      { key: "backup", text: "no backup yet", tone: "warn" },
    ]);
    expect(line?.errors).toEqual(["the backups could not be listed: 429", "pooler timed out"]);
    expect(texts(row({ health: { ...healthy, assurance_failures: 1 } }))).toContain(
      "1 assurance check failing",
    );
    expect(texts(row({ health: { ...healthy, open_support_windows: 3 } }))).toContain(
      "3 support windows open",
    );
  });

  test("only what the poll read is said", () => {
    expect(texts(row({ health: { polled_at: ago(5) } }))).toEqual(["polled 5 minutes ago"]);
    expect(texts(row({ health: {}, health_at: ago(90) }))).toEqual(["polled 1 hour ago"]);
    expect(texts(row({ health: {}, health_at: null }))).toEqual([]);
    expect(texts(row({ health: { backups_latest_at: ago(60) } }))).toEqual([
      "polled 5 minutes ago",
      "backup 1 hour ago",
    ]);
    expect(texts(row({ health: { backups_count: 1 } }))).toContain("1 backup kept");
    expect(texts(row({ health: { backups_count: 4 } }))).toContain("4 backups kept");
  });

  test("a count written as text is read; anything else is not known", () => {
    const loose = {
      assurance_failures: "3",
      database_bytes: String(10 * 1_048_576),
      open_support_windows: -1,
      backups_count: 1.5,
      staff_in_step: "yes",
      errors: "not a list",
    } as unknown as DeploymentHealth;
    expect(texts(row({ health: loose }))).toEqual([
      "polled 5 minutes ago",
      "3 assurance checks failing",
      "database 10 MB",
    ]);
    expect(deploymentHealthLine(row({ health: loose }), NOW)?.errors).toEqual([]);
  });

  test("silent: said first, with when the poll last read it, or that it never has", () => {
    const stale = deploymentHealthLine(
      row({ silent: true, health: { ...healthy, polled_at: ago(3 * 24 * 60) } }),
      NOW,
    );
    expect(stale?.silence).toBe(
      "Not heard from for over a day: the fleet poll last read it 3 days ago.",
    );
    // The poll's age is in the sentence, so it is not said twice.
    expect(stale?.parts.map((p) => p.key)).not.toContain("polled");
    expect(stale?.parts.map((p) => p.key)).toContain("assurance");

    const never = deploymentHealthLine(row({ silent: true, health: null, health_at: null }), NOW);
    expect(never).toEqual({
      silence: "Not heard from yet: the fleet poll has never read it.",
      parts: [],
      errors: [],
    });
  });

  test("only where the project is up, and only when the register says something", () => {
    // Suspended and offboarding projects keep running, and the poll reads them.
    for (const status of ["built", "live", "suspended", "retiring"] as const) {
      expect(deploymentHealthLine(row({ status }), NOW)).not.toBeNull();
    }
    for (const status of ["requested", "creating", "building", "retired", "failed"] as const) {
      expect(deploymentHealthLine(row({ status, silent: true }), NOW)).toBeNull();
    }
    // A register older than the poll gives neither health nor silence.
    expect(deploymentHealthLine({ status: "live" }, NOW)).toBeNull();
    expect(deploymentHealthLine(row({ health: null, silent: false }), NOW)).toBeNull();
  });
});

describe("when the sweep starts a request", () => {
  test("within a minute when it can be woken, otherwise within ten, naming no token", () => {
    expect(SWEEP_STARTS).toContain("within a minute");
    expect(SWEEP_STARTS).toContain("otherwise within ten");
    expect(SWEEP_STARTS).not.toMatch(/token|secret|vault/i);
  });
});

describe("what a row in the Fleet view offers", () => {
  const NOW = new Date("2026-10-08T12:00:00Z");
  const row = (status: ClientDeploymentStatus): BuildRequestView => ({
    status,
    request_status: status === "requested" ? "requested" : null,
    request_created_at: NOW.toISOString(),
    request_claimed_at: null,
    request_settled_at: null,
    last_event: null,
  });
  const offers = (status: ClientDeploymentStatus, role: PlatformRole | null) =>
    fleetActions(row(status), role, NOW);

  test("the owner, by state, in the order the row shows them", () => {
    const owner: Record<ClientDeploymentStatus, FleetAction[]> = {
      requested: ["retire"],
      creating: [],
      building: [],
      built: ["open-console", "onboard", "suspend", "rename", "export", "offboard", "retire"],
      live: ["open-console", "onboard", "suspend", "rename", "export", "offboard", "retire"],
      suspended: ["reinstate", "rename", "export", "offboard", "retire"],
      retiring: ["open-console", "export", "retire"],
      retired: [],
      failed: ["retry", "retire"],
    };
    for (const [status, expected] of Object.entries(owner)) {
      expect(offers(status as ClientDeploymentStatus, "owner")).toEqual(expected);
    }
  });

  test("an operator or administrator may export and open, and change nothing else", () => {
    for (const role of ["operator", "administrator"] as const) {
      expect(offers("live", role)).toEqual(["open-console", "onboard", "export"]);
      expect(offers("suspended", role)).toEqual(["export"]);
      expect(offers("retiring", role)).toEqual(["open-console", "export"]);
      expect(offers("failed", role)).toEqual([]);
    }
  });

  test("support, and anybody without a rank, may only open what is served", () => {
    for (const role of ["support", null] as const) {
      expect(offers("live", role)).toEqual(["open-console", "onboard"]);
      expect(offers("suspended", role)).toEqual([]);
      expect(offers("retiring", role)).toEqual(["open-console"]);
    }
  });

  test("a suspended client's console is not offered: its address shows only the suspension", () => {
    for (const role of ["owner", "operator", "support"] as const) {
      expect(offers("suspended", role)).not.toContain("open-console");
      expect(offers("suspended", role)).not.toContain("onboard");
    }
  });

  test("Start again is offered with the rest once a request has stalled", () => {
    const stalled: BuildRequestView = {
      ...row("requested"),
      request_created_at: new Date(NOW.getTime() - 25 * 60_000).toISOString(),
    };
    expect(fleetActions(stalled, "owner", NOW)).toEqual(["start-again", "retire"]);
    expect(fleetActions(stalled, "operator", NOW)).toEqual([]);
  });
});

describe("where a deployment stands in its lifecycle", () => {
  const NOW = new Date("2026-10-12T12:00:00Z");
  type Row = Parameters<typeof deploymentLifecycleNotes>[0];
  const row = (over: Partial<Row> = {}): Row => ({
    code: "acme",
    origin: "https://acme.cloveerp.com",
    status: "live",
    previous_address: null,
    previous_address_until: null,
    purge_due_at: null,
    suspended_reason: null,
    ...over,
  });

  test("a live deployment that never moved says nothing", () => {
    expect(deploymentLifecycleNotes(row(), NOW)).toEqual([]);
    // A register older than the lifecycle says nothing either.
    expect(
      deploymentLifecycleNotes(
        { code: "acme", origin: "https://acme.cloveerp.com", status: "live" },
        NOW,
      ),
    ).toEqual([]);
  });

  test("suspended: why, or that its address shows only the suspension", () => {
    expect(
      deploymentLifecycleNotes(
        row({ status: "suspended", suspended_reason: " invoice sixty days overdue " }),
        NOW,
      ),
    ).toEqual([{ key: "suspended", text: "Suspended: invoice sixty days overdue", tone: "warn" }]);
    expect(deploymentLifecycleNotes(row({ status: "suspended" }), NOW)).toEqual([
      {
        key: "suspended",
        text: "Its address shows only that its service is suspended.",
        tone: "warn",
      },
    ]);
    // A reason left over from an earlier suspension is not said of a live one.
    expect(deploymentLifecycleNotes(row({ suspended_reason: "old" }), NOW)).toEqual([]);
  });

  test("being offboarded: the day its project is due to be purged", () => {
    expect(
      deploymentLifecycleNotes(
        row({ status: "retiring", purge_due_at: "2027-01-30T00:00:00Z" }),
        NOW,
      ),
    ).toEqual([
      {
        key: "purge",
        text: "Being offboarded: its project is due to be purged on 30 January 2027.",
        tone: "warn",
      },
    ]);
    expect(deploymentLifecycleNotes(row({ status: "retiring" }), NOW)).toEqual([
      { key: "purge", text: "Being offboarded.", tone: "warn" },
    ]);
  });

  test("moved: the old address, while it still sends people on", () => {
    const moved = row({
      origin: "https://acme-group.cloveerp.com",
      previous_address: "acme",
      previous_address_until: "2027-01-10T12:00:00Z",
    });
    expect(deploymentLifecycleNotes(moved, NOW)).toEqual([
      {
        key: "moved",
        text: "Was acme.cloveerp.com, which sends people here until 10 January 2027.",
        tone: "muted",
      },
    ]);
    // Once the ninety days are over, the old address is nobody's and is not said.
    expect(deploymentLifecycleNotes(moved, new Date("2027-01-10T12:00:00Z"))).toEqual([]);
    expect(
      deploymentLifecycleNotes({ ...moved, previous_address_until: "not a time" }, NOW),
    ).toEqual([]);
  });

  test("the notes come in order: standing first, then the move", () => {
    const keys = deploymentLifecycleNotes(
      row({
        status: "suspended",
        suspended_reason: "unpaid",
        previous_address: "acme",
        previous_address_until: "2027-01-10T12:00:00Z",
      }),
      NOW,
    ).map((n) => n.key);
    expect(keys).toEqual(["suspended", "moved"]);
  });
});

describe("the days the lifecycle names", () => {
  test("a day reads the same wherever the console is opened", () => {
    expect(dayText("2027-01-09T23:30:00Z")).toBe("9 January 2027");
    expect(dayText("2026-12-31")).toBe("31 December 2026");
    expect(dayText("yesterday")).toBeNull();
    expect(dayText(null)).toBeNull();
    expect(dayText(undefined)).toBeNull();
  });

  test("a project is purged thirty days after offboarding begins at the earliest", () => {
    expect(OFFBOARDING_COOL_OFF_DAYS).toBe(30);
    expect(earliestPurgeDate(new Date("2026-10-12T09:00:00Z"))).toBe("2026-11-11T09:00:00.000Z");
  });

  test("the last export, as long ago as it was, or nothing", () => {
    const now = new Date("2026-10-12T12:00:00Z");
    expect(lastExportText({ last_export_at: "2026-10-12T09:00:00Z" }, now)).toBe(
      "exported 3 hours ago",
    );
    expect(lastExportText({ last_export_at: null }, now)).toBeNull();
    expect(lastExportText({}, now)).toBeNull();
  });
});

describe("a deployment row as the register lists it", () => {
  test("every lifecycle key is optional, so an older register still reads", () => {
    const older: ClientDeployment = {
      code: "acme",
      client_name: "Acme Ltd",
      status: "live",
      owner_email: null,
      project_ref: "abcdefghijklmnopqrst",
      api_url: "https://abcdefghijklmnopqrst.supabase.co",
      region: "eu-west-2",
      instance_size: "micro",
      origin: "https://acme.cloveerp.com",
      build_run_id: null,
      built_at: null,
      last_release_sha: null,
      last_release_at: null,
      last_release_outcome: null,
      last_release_run_id: null,
      checklist: {},
      note: null,
      created_at: "2026-10-08T12:00:00Z",
      updated_at: "2026-10-08T12:00:00Z",
      request_status: null,
      request_run_id: null,
      last_event: null,
    };
    expect(deploymentAddress(older)).toBe("acme.cloveerp.com");
    expect(deploymentLifecycleNotes(older, new Date("2026-10-12T12:00:00Z"))).toEqual([]);
    expect(lastExportText(older, new Date("2026-10-12T12:00:00Z"))).toBeNull();
  });
});
