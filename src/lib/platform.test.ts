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
  exportDescription,
  exportedSinceServiceStopped,
  exportOwedText,
  fleetActions,
  hostOfOrigin,
  isDeploymentAddress,
  isPlatformOperator,
  LAST_COPY_RULE,
  lastExportText,
  OFFBOARDING_COOL_OFF_DAYS,
  offboardingStepsLeft,
  organisationWhere,
  purgeDateHasCome,
  renameAddressHint,
  renameDescription,
  serviceSuspended,
  STALE_BUILD_REQUEST_MINUTES,
  SWEEP_STARTS,
  takesReleases,
  type BuildRequestView,
  type ClientDeployment,
  type ClientDeploymentStatus,
  type DeploymentHealth,
  type FleetAction,
  type FleetRowView,
  type LifecycleNote,
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

  test("a deployment says it is one in a picker, and not where it is served", () => {
    // A rename moves its address while its code stays: the picker names no address.
    expect(customerChoiceText({ code: "acme", name: "Acme Ltd", where: "deployment" })).toBe(
      "Acme Ltd (acme), a client deployment",
    );
    expect(customerChoiceText({ code: "acme", name: "Acme Ltd", where: "deployment" })).not.toMatch(
      /cloveerp\.com/,
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
  const at = (days: number) => new Date(NOW.getTime() + days * 86_400_000).toISOString();
  /** The states a build has finished in: the register says when. */
  const BUILT: ReadonlySet<ClientDeploymentStatus> = new Set([
    "built",
    "live",
    "suspended",
    "retiring",
    "retired",
  ]);
  const row = (status: ClientDeploymentStatus, over: Partial<FleetRowView> = {}): FleetRowView => ({
    status,
    request_status: status === "requested" ? "requested" : null,
    request_created_at: NOW.toISOString(),
    request_claimed_at: null,
    request_settled_at: null,
    last_event: null,
    built_at: BUILT.has(status) ? at(-90) : null,
    suspended_reason: status === "suspended" ? "The August invoice is sixty days overdue." : null,
    suspended_at: status === "suspended" ? at(-20) : null,
    // Being offboarded: begun a week ago, its purge date three weeks away,
    // still served, and a copy taken the day after it began, while served.
    offboarding_at: status === "retiring" ? at(-7) : null,
    purge_due_at: status === "retiring" ? at(23) : null,
    last_export_taken_at: status === "retiring" ? at(-6) : null,
    last_export_service_stopped: false,
    ...over,
  });
  const offers = (
    status: ClientDeploymentStatus,
    role: PlatformRole | null,
    over: Partial<FleetRowView> = {},
  ) => fleetActions(row(status, over), role, NOW);
  /** Being offboarded, its purge date come. */
  const due = { purge_due_at: at(-1) };
  /**
   * Its service suspended a day before its offboarding began, so the copy
   * taken the day after it began was taken once its own organisation was
   * stopped.
   */
  const stopped = {
    suspended_reason: "The client stopped paying during its notice.",
    suspended_at: at(-8),
    last_export_service_stopped: true,
  };

  test("the owner, by state, in the order the row shows them", () => {
    const owner: Record<ClientDeploymentStatus, FleetAction[]> = {
      requested: ["offboard", "retire"],
      creating: [],
      building: [],
      built: ["open-console", "onboard", "suspend", "rename", "export", "offboard", "retire"],
      live: ["open-console", "onboard", "suspend", "rename", "export", "offboard", "retire"],
      suspended: ["reinstate", "rename", "export", "offboard", "retire"],
      retiring: ["open-console", "suspend", "export", "cancel-offboarding"],
      retired: [],
      failed: ["retry", "offboard", "retire"],
    };
    for (const [status, expected] of Object.entries(owner)) {
      expect(offers(status as ClientDeploymentStatus, "owner")).toEqual(expected);
    }
  });

  test("a client being offboarded and suspended is reinstated, not served, and still exported", () => {
    expect(offers("retiring", "owner", stopped)).toEqual([
      "reinstate",
      "export",
      "cancel-offboarding",
    ]);
    expect(offers("retiring", "owner", { ...stopped, ...due })).toEqual([
      "reinstate",
      "export",
      "cancel-offboarding",
      "retire",
    ]);
    expect(offers("retiring", "operator", stopped)).toEqual(["export"]);
    expect(offers("retiring", "support", stopped)).toEqual([]);
  });

  test("being offboarded, Retire waits for the purge date", () => {
    expect(offers("retiring", "owner", stopped)).not.toContain("retire");
    expect(offers("retiring", "owner", { ...stopped, purge_due_at: at(0) })).toContain("retire");
    // A purge date that cannot be read, or none, has not come.
    expect(offers("retiring", "owner", { ...stopped, purge_due_at: null })).not.toContain("retire");
    expect(offers("retiring", "owner", { ...stopped, purge_due_at: "soon" })).not.toContain(
      "retire",
    );
  });

  test("being offboarded, one still served is not retired, even exported and on its purge date", () => {
    // Its people can still change its data, so no copy is its last.
    expect(offers("retiring", "owner", due)).toEqual([
      "open-console",
      "suspend",
      "export",
      "cancel-offboarding",
    ]);
    expect(offers("retiring", "owner", { ...due, last_export_taken_at: at(-1) })).not.toContain(
      "retire",
    );
  });

  test("being offboarded, Retire waits for a copy taken since its service stopped", () => {
    // Never exported, or only before offboarding began.
    expect(
      offers("retiring", "owner", { ...stopped, ...due, last_export_taken_at: null }),
    ).not.toContain("retire");
    expect(
      offers("retiring", "owner", { ...stopped, ...due, last_export_taken_at: at(-30) }),
    ).not.toContain("retire");
    // Taken the moment it began counts, its service already stopped.
    expect(
      offers("retiring", "owner", { ...stopped, ...due, last_export_taken_at: at(-7) }),
    ).toContain("retire");
    // Offboarded while served, the copy it began with was taken while its
    // people could still change its data: suspended since, it is owed another.
    const late = { ...stopped, ...due, suspended_at: at(-3) };
    expect(offers("retiring", "owner", late)).not.toContain("retire");
    expect(offers("retiring", "owner", { ...late, last_export_taken_at: at(-3) })).toContain(
      "retire",
    );
    expect(offers("retiring", "owner", { ...late, last_export_taken_at: at(-2) })).toContain(
      "retire",
    );
    // Without the day it began, or the moment its service stopped, no export
    // can be shown to be since.
    expect(offers("retiring", "owner", { ...stopped, ...due, offboarding_at: null })).not.toContain(
      "retire",
    );
    expect(offers("retiring", "owner", { ...stopped, ...due, suspended_at: null })).not.toContain(
      "retire",
    );
  });

  test("being offboarded, a copy whose dump began before the suspension is not the last, however late it was recorded", () => {
    // Offboarded while served, its export claimed and its dump begun 35
    // minutes before the owner suspended it; recorded after. The copy holds
    // the data as it stood when the dump began, while its people could still
    // write: it is owed another (the second review's eighth finding).
    const suspendedAt = Date.parse(at(-3));
    const dumpBegan = new Date(suspendedAt - 35 * 60_000).toISOString();
    const inFlight = {
      ...stopped,
      ...due,
      suspended_at: at(-3),
      last_export_taken_at: dumpBegan,
      last_export_service_stopped: false,
    };
    expect(offers("retiring", "owner", inFlight)).not.toContain("retire");
    expect(offers("retiring", "owner", inFlight)).toContain("export");
    // Whatever the run says of the organisation, a dump begun before the
    // suspension is before it.
    expect(
      offers("retiring", "owner", { ...inFlight, last_export_service_stopped: true }),
    ).not.toContain("retire");
  });

  test("being offboarded, a copy taken after the suspension counts only once its own organisation was stopped", () => {
    // Suspended at the register, but the run could not show that the
    // client's own organisation was stopped before its dump began: open
    // sessions may still have been writing (the second review's ninth
    // finding). The copy is kept, and does not count.
    const unconfirmed = {
      ...stopped,
      ...due,
      suspended_at: at(-3),
      last_export_taken_at: at(-2),
      last_export_service_stopped: false,
    };
    expect(offers("retiring", "owner", unconfirmed)).not.toContain("retire");
    expect(
      offers("retiring", "owner", { ...unconfirmed, last_export_service_stopped: true }),
    ).toContain("retire");
  });

  test("one whose build never finished has nothing to serve, stop or export, and is retired on its purge date", () => {
    const neverBuilt = { built_at: null, last_export_at: null };
    // Its address answers nothing, so there is no console to open and no
    // service to suspend.
    expect(offers("retiring", "owner", neverBuilt)).toEqual(["cancel-offboarding"]);
    expect(offers("retiring", "owner", { ...neverBuilt, ...due })).toEqual([
      "cancel-offboarding",
      "retire",
    ]);
    for (const role of ["administrator", "operator", "support", null] as const) {
      expect(offers("retiring", role, neverBuilt)).toEqual([]);
    }
  });

  test("a requested or failed deployment can be offboarded; one building cannot", () => {
    expect(offers("requested", "owner")).toContain("offboard");
    expect(offers("failed", "owner")).toContain("offboard");
    for (const status of ["creating", "building", "retiring", "retired"] as const) {
      expect(offers(status, "owner")).not.toContain("offboard");
    }
  });

  test("only an owner offboards, cancels an offboarding, suspends or retires", () => {
    for (const role of ["administrator", "operator", "support", null] as const) {
      for (const status of ["requested", "failed", "live", "suspended", "retiring"] as const) {
        const offered = offers(status, role, due);
        for (const owners of [
          "suspend",
          "reinstate",
          "rename",
          "offboard",
          "cancel-offboarding",
          "retire",
        ] as const) {
          expect(offered).not.toContain(owners);
        }
      }
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

  test("export only where there is a database: built, and up", () => {
    expect(offers("live", "operator", { built_at: null })).not.toContain("export");
    for (const status of ["requested", "creating", "building", "failed", "retired"] as const) {
      expect(offers(status, "owner", { built_at: at(-1) })).not.toContain("export");
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
      expect(offers("retiring", role, { suspended_reason: "unpaid" })).not.toContain(
        "open-console",
      );
    }
  });

  test("Start again is offered with the rest once a request has stalled", () => {
    const stalled = row("requested", {
      request_created_at: new Date(NOW.getTime() - 25 * 60_000).toISOString(),
    });
    expect(fleetActions(stalled, "owner", NOW)).toEqual(["start-again", "offboard", "retire"]);
    expect(fleetActions(stalled, "operator", NOW)).toEqual([]);
  });
});

describe("a client's suspension, purge date and export", () => {
  const NOW = new Date("2026-10-12T12:00:00Z");

  test("suspended, or being offboarded with a reason, is a suspended service", () => {
    expect(serviceSuspended({ status: "suspended", suspended_reason: "unpaid" })).toBe(true);
    // The status alone says so, whatever the register gives as the reason.
    expect(serviceSuspended({ status: "suspended" })).toBe(true);
    expect(serviceSuspended({ status: "retiring", suspended_reason: "unpaid" })).toBe(true);
    expect(serviceSuspended({ status: "retiring", suspended_reason: null })).toBe(false);
    expect(serviceSuspended({ status: "retiring" })).toBe(false);
    for (const status of ["built", "live", "requested", "failed", "retired"] as const) {
      expect(serviceSuspended({ status, suspended_reason: "left over" })).toBe(false);
    }
  });

  test("a purge date has come on the day, and never when it cannot be read", () => {
    expect(purgeDateHasCome({ purge_due_at: "2026-10-12T12:00:00Z" }, NOW)).toBe(true);
    expect(purgeDateHasCome({ purge_due_at: "2026-10-01T00:00:00Z" }, NOW)).toBe(true);
    expect(purgeDateHasCome({ purge_due_at: "2026-10-12T12:00:01Z" }, NOW)).toBe(false);
    expect(purgeDateHasCome({ purge_due_at: "next month" }, NOW)).toBe(false);
    expect(purgeDateHasCome({ purge_due_at: null }, NOW)).toBe(false);
    expect(purgeDateHasCome({}, NOW)).toBe(false);
  });

  test("a copy taken since its service stopped and its offboarding began, its organisation stopped, or never built", () => {
    const built = "2026-06-01T09:00:00Z";
    const began = "2026-10-01T09:00:00Z";
    const before = "2026-09-20T09:00:00Z";
    const after = "2026-10-05T09:00:00Z";
    const since = (over: {
      suspended_at?: string | null;
      last_export_taken_at?: string | null;
      last_export_service_stopped?: boolean;
    }) =>
      exportedSinceServiceStopped({
        built_at: built,
        offboarding_at: began,
        last_export_service_stopped: true,
        ...over,
      });
    // Suspended before its offboarding began: a copy taken since it began
    // counts, the moment it began included.
    expect(since({ suspended_at: before, last_export_taken_at: "2026-10-01T10:00:00Z" })).toBe(
      true,
    );
    expect(since({ suspended_at: before, last_export_taken_at: began })).toBe(true);
    expect(since({ suspended_at: before, last_export_taken_at: "2026-09-30T09:00:00Z" })).toBe(
      false,
    );
    // Suspended after it began: only a copy taken since the suspension counts.
    expect(since({ suspended_at: after, last_export_taken_at: "2026-10-02T09:00:00Z" })).toBe(
      false,
    );
    expect(since({ suspended_at: after, last_export_taken_at: after })).toBe(true);
    expect(since({ suspended_at: after, last_export_taken_at: "2026-10-06T09:00:00Z" })).toBe(true);
    // Never exported, never suspended, or a time that cannot be read.
    expect(since({ suspended_at: before, last_export_taken_at: null })).toBe(false);
    expect(since({ suspended_at: null, last_export_taken_at: after })).toBe(false);
    expect(since({ last_export_taken_at: after })).toBe(false);
    expect(since({ suspended_at: "last week", last_export_taken_at: after })).toBe(false);
    expect(since({ suspended_at: before, last_export_taken_at: "this morning" })).toBe(false);
    expect(
      exportedSinceServiceStopped({
        built_at: built,
        suspended_at: before,
        last_export_taken_at: after,
        last_export_service_stopped: true,
      }),
    ).toBe(false);
    // Never built: nothing to export.
    expect(exportedSinceServiceStopped({ built_at: null })).toBe(true);
  });

  test("only a copy taken once its own organisation was stopped counts", () => {
    const built = "2026-06-01T09:00:00Z";
    const began = "2026-10-01T09:00:00Z";
    const suspended = "2026-10-05T09:00:00Z";
    const taken = "2026-10-05T10:00:00Z";
    const copy = { built_at: built, offboarding_at: began, suspended_at: suspended };
    expect(
      exportedSinceServiceStopped({
        ...copy,
        last_export_taken_at: taken,
        last_export_service_stopped: true,
      }),
    ).toBe(true);
    // Taken after the suspension, but the run could not show the organisation
    // was stopped: its open sessions may still have been writing.
    expect(
      exportedSinceServiceStopped({
        ...copy,
        last_export_taken_at: taken,
        last_export_service_stopped: false,
      }),
    ).toBe(false);
    // A register older than the rule does not say, so no copy counts.
    expect(exportedSinceServiceStopped({ ...copy, last_export_taken_at: taken })).toBe(false);
  });

  test("a copy is dated by when its dump began, not by when it was recorded", () => {
    // Dumped before the suspension, recorded after it: the register's row
    // carries both times, and only the first says what the copy holds.
    const row: Parameters<typeof exportedSinceServiceStopped>[0] & {
      last_export_at: string;
    } = {
      built_at: "2026-06-01T09:00:00Z",
      offboarding_at: "2026-10-01T09:00:00Z",
      suspended_at: "2026-10-05T09:00:00Z",
      last_export_at: "2026-10-05T09:20:00Z",
      last_export_taken_at: "2026-10-05T08:25:00Z",
      last_export_service_stopped: true,
    };
    expect(exportedSinceServiceStopped(row)).toBe(false);
    expect(
      exportedSinceServiceStopped({ ...row, last_export_taken_at: "2026-10-05T09:05:00Z" }),
    ).toBe(true);
  });
});

describe("what is left before a client being offboarded is retired", () => {
  const NOW = new Date("2026-10-12T12:00:00Z");
  type Row = Parameters<typeof offboardingStepsLeft>[0];
  /** Built, offboarded on 1 October while served, a copy taken the next day, purge date come. */
  const row = (over: Partial<Row> = {}): Row => ({
    status: "retiring",
    built_at: "2026-06-01T09:00:00Z",
    offboarding_at: "2026-10-01T09:00:00Z",
    purge_due_at: "2026-10-12T00:00:00Z",
    suspended_reason: null,
    suspended_at: null,
    last_export_taken_at: "2026-10-02T09:00:00Z",
    last_export_service_stopped: false,
    ...over,
  });
  const stopped = { suspended_reason: "Its notice ended.", suspended_at: "2026-10-12T09:00:00Z" };
  /** A copy taken after its own organisation was stopped. */
  const last = { last_export_taken_at: "2026-10-12T10:00:00Z", last_export_service_stopped: true };

  test("served on its purge date: suspend it, export it, then retire it", () => {
    expect(offboardingStepsLeft(row(), NOW)).toEqual(["suspend", "export", "retire"]);
    // A copy taken while it was served does not count, however recent.
    expect(
      offboardingStepsLeft(row({ last_export_taken_at: "2026-10-12T11:00:00Z" }), NOW),
    ).toEqual(["suspend", "export", "retire"]);
  });

  test("suspended, and no copy taken since: export it, then retire it", () => {
    expect(offboardingStepsLeft(row(stopped), NOW)).toEqual(["export", "retire"]);
  });

  test("suspended and a copy taken since, its organisation stopped: only retiring it is left", () => {
    expect(offboardingStepsLeft(row({ ...stopped, ...last }), NOW)).toEqual(["retire"]);
  });

  test("suspended, but its last copy began before the suspension or its organisation was not shown stopped: export it again", () => {
    // Its dump began half an hour before the suspension, and was recorded after.
    expect(
      offboardingStepsLeft(row({ ...stopped, last_export_taken_at: "2026-10-12T08:30:00Z" }), NOW),
    ).toEqual(["export", "retire"]);
    // Taken after the suspension, but its organisation could not be shown stopped.
    expect(
      offboardingStepsLeft(row({ ...stopped, ...last, last_export_service_stopped: false }), NOW),
    ).toEqual(["export", "retire"]);
  });

  test("nothing before its purge date, for one never built, or for one not being offboarded", () => {
    expect(offboardingStepsLeft(row({ purge_due_at: "2026-11-01T00:00:00Z" }), NOW)).toEqual([]);
    expect(offboardingStepsLeft(row({ purge_due_at: null }), NOW)).toEqual([]);
    expect(offboardingStepsLeft(row({ built_at: null, last_export_taken_at: null }), NOW)).toEqual(
      [],
    );
    for (const status of ["built", "live", "suspended", "retired"] as const) {
      expect(offboardingStepsLeft(row({ status }), NOW)).toEqual([]);
    }
  });

  test("what the fleet row offers agrees with what is left", () => {
    const view = (over: Partial<Row>): FleetRowView => ({
      ...row(over),
      request_status: null,
      last_event: null,
    });
    for (const over of [
      {},
      stopped,
      { ...stopped, ...last },
      { ...stopped, ...last, last_export_service_stopped: false },
      {
        ...stopped,
        last_export_taken_at: "2026-10-12T08:30:00Z",
        last_export_service_stopped: true,
      },
    ]) {
      const left = offboardingStepsLeft(row(over), NOW);
      const offered = fleetActions(view(over), "owner", NOW);
      expect(offered.includes("retire")).toBe(left.length === 1 && left[0] === "retire");
      if (left.includes("suspend")) expect(offered).toContain("suspend");
      if (left.includes("export")) expect(offered).toContain("export");
    }
  });
});

describe("an export owed before the purge date", () => {
  const NOW = new Date("2026-10-12T12:00:00Z");
  type Row = Parameters<typeof exportOwedText>[0];
  /**
   * Built, offboarded on 1 October, a copy taken on 2 October while served,
   * suspended on 5 October, purge date still to come.
   */
  const row = (over: Partial<Row> = {}): Row => ({
    status: "retiring",
    built_at: "2026-06-01T09:00:00Z",
    offboarding_at: "2026-10-01T09:00:00Z",
    purge_due_at: "2026-11-01T00:00:00Z",
    suspended_reason: "Its notice ended.",
    suspended_at: "2026-10-05T09:00:00Z",
    last_export_at: "2026-10-02T09:40:00Z",
    last_export_taken_at: "2026-10-02T09:00:00Z",
    last_export_service_stopped: false,
    ...over,
  });
  const RULE =
    "Only a copy taken after its own organisation was stopped counts as the last one and lets it be retired: an export asked for now makes sure of that first.";

  test("the rule it says is the one the console says everywhere", () => {
    expect(RULE.startsWith(LAST_COPY_RULE)).toBe(true);
  });

  test("suspended and no copy taken since its organisation was stopped: said, until the purge date", () => {
    expect(exportOwedText(row(), NOW)).toBe(`Its last copy does not count. ${RULE}`);
    expect(exportOwedText(row({ last_export_at: null, last_export_taken_at: null }), NOW)).toBe(
      `Not exported yet. ${RULE}`,
    );
    // From the purge date the lifecycle note names it with every step left.
    expect(exportOwedText(row({ purge_due_at: "2026-10-12T00:00:00Z" }), NOW)).toBeNull();
  });

  test("a copy whose dump began before the suspension is owed again, however late it was recorded", () => {
    expect(
      exportOwedText(
        row({
          last_export_taken_at: "2026-10-05T08:25:00Z",
          last_export_at: "2026-10-05T09:20:00Z",
        }),
        NOW,
      ),
    ).toBe(`Its last copy does not count. ${RULE}`);
  });

  test("a copy taken after the suspension, its organisation not shown stopped, is owed again", () => {
    expect(
      exportOwedText(
        row({
          last_export_taken_at: "2026-10-05T10:00:00Z",
          last_export_at: "2026-10-05T10:40:00Z",
        }),
        NOW,
      ),
    ).toBe(`Its last copy does not count. ${RULE}`);
  });

  test("a copy taken once its organisation was stopped, but before its offboarding began, says so", () => {
    expect(
      exportOwedText(
        row({
          suspended_at: "2026-09-20T09:00:00Z",
          last_export_taken_at: "2026-09-25T09:00:00Z",
          last_export_at: "2026-09-25T09:40:00Z",
          last_export_service_stopped: true,
        }),
        NOW,
      ),
    ).toBe(`Its last copy was taken before its offboarding began, so it does not count. ${RULE}`);
  });

  test("nothing when a copy was taken since its organisation was stopped, still served, or never built", () => {
    expect(
      exportOwedText(
        row({ last_export_taken_at: "2026-10-05T10:00:00Z", last_export_service_stopped: true }),
        NOW,
      ),
    ).toBeNull();
    // Still served, its people can change its data, so no export is owed yet.
    expect(exportOwedText(row({ suspended_reason: null, suspended_at: null }), NOW)).toBeNull();
    expect(
      exportOwedText(
        row({ built_at: null, last_export_at: null, last_export_taken_at: null }),
        NOW,
      ),
    ).toBeNull();
    expect(exportOwedText(row({ status: "suspended" }), NOW)).toBeNull();
  });
});

describe("what the Export dialog says", () => {
  const STOPS =
    "Its service is suspended, so the export first makes sure its own organisation is stopped, then takes the copy.";

  test("where the copy goes, when it starts, and that asking again queues nothing more", () => {
    const text = exportDescription({ code: "acme", status: "live", suspended_reason: null });
    expect(text).toContain("under exports/acme/");
    expect(text).toContain(SWEEP_STARTS);
    expect(text).toContain(
      "While one is waiting or being written, asking again queues nothing more.",
    );
    expect(text).not.toContain(STOPS);
    expect(text).not.toContain(LAST_COPY_RULE);
  });

  test("suspended: the export stops its own organisation first, and one begun before does not stop a new one", () => {
    const text = exportDescription({
      code: "acme",
      status: "suspended",
      suspended_reason: "unpaid",
    });
    expect(text).toContain(STOPS);
    expect(text).toContain("one that started before the suspension does not stop a new one.");
    // Not being offboarded, no copy is anybody's last.
    expect(text).not.toContain(LAST_COPY_RULE);
  });

  test("being offboarded and still served: this is not the last copy, suspend it first", () => {
    const text = exportDescription({ code: "acme", status: "retiring", suspended_reason: null });
    expect(text).toContain(
      `Its people can still change its data, so this is not the copy it is retired with. ${LAST_COPY_RULE}: suspend it first, and an export asked for after that makes sure of it.`,
    );
    expect(text).not.toContain(STOPS);
  });

  test("being offboarded and suspended: this copy is the last one, unless its organisation cannot be shown stopped", () => {
    const text = exportDescription({
      code: "acme",
      status: "retiring",
      suspended_reason: "Its notice ended.",
    });
    expect(text).toContain(
      "Its service is suspended, so the export first makes sure its own organisation is stopped, then takes the copy.",
    );
    expect(text).toContain(`${LAST_COPY_RULE}, and lets it be retired;`);
    expect(text).toContain(
      "if the organisation cannot be shown to be stopped, the copy is still taken, but it does not count.",
    );
    expect(text).toContain("one that started before the suspension does not stop a new one.");
  });
});

describe("who a release goes to", () => {
  test("a client whose project is up, and one being offboarded only once it was built", () => {
    const built = "2026-06-01T09:00:00Z";
    for (const status of ["built", "live", "suspended", "retiring"] as const) {
      expect(takesReleases({ status, built_at: built })).toBe(true);
    }
    // Offboarded before its build finished: no database, and the door refuses its code.
    expect(takesReleases({ status: "retiring", built_at: null })).toBe(false);
    for (const status of ["requested", "creating", "building", "failed", "retired"] as const) {
      expect(takesReleases({ status, built_at: null })).toBe(false);
    }
    expect(takesReleases({ status: "retired", built_at: built })).toBe(false);
  });
});

describe("what the rename dialog says", () => {
  test("an address asked for in a rename stays the client's, so asking again works", () => {
    const text = renameDescription({
      code: "acme",
      origin: "https://acme.cloveerp.com",
      address: "acme",
    });
    expect(text).toContain("Its old address, acme.cloveerp.com, sends them on for ninety days");
    expect(text).toContain("never given to another client");
    expect(text).toContain(
      "The new address is its own from the moment it is asked for, even if the rename stops, so asking for it again finishes the move.",
    );
    expect(text).toContain("Its code, acme, stays the same.");
    expect(text).toContain(SWEEP_STARTS);
  });

  test("under the address: its shape, that it is the address now, or who may have it", () => {
    expect(renameAddressHint("-acme", "acme")).toContain("Three to sixty-three");
    expect(renameAddressHint("acme", "acme")).toBe("That is its address now.");
    for (const typed of ["", "acme-group"]) {
      const rule = renameAddressHint(typed, "acme");
      expect(rule).toContain(
        "refused if any other client has it, ever had it or was ever asked to move to it",
      );
      expect(rule).toContain("any address it was asked to move to can be given to it");
    }
  });
});

describe("where a deployment stands in its lifecycle", () => {
  const NOW = new Date("2026-10-12T12:00:00Z");
  type Row = Parameters<typeof deploymentLifecycleNotes>[0];
  const row = (over: Partial<Row> = {}): Row => ({
    code: "acme",
    origin: "https://acme.cloveerp.com",
    status: "live",
    built_at: "2026-06-01T09:00:00Z",
    previous_address: null,
    previous_address_until: null,
    purge_due_at: null,
    offboarding_at: null,
    suspended_reason: null,
    suspended_at: null,
    last_export_taken_at: null,
    last_export_service_stopped: false,
    ...over,
  });
  const COPY_RULE =
    "Only a copy taken after its own organisation was stopped counts as the last one: an export asked for after suspending it makes sure of that first.";

  test("a live deployment that never moved says nothing", () => {
    expect(deploymentLifecycleNotes(row(), NOW)).toEqual([]);
    // A register older than the lifecycle says nothing either.
    expect(
      deploymentLifecycleNotes(
        {
          code: "acme",
          origin: "https://acme.cloveerp.com",
          status: "live",
          built_at: "2026-06-01T09:00:00Z",
        },
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

  test("being offboarded, once the purge date has come, says so and what is left, in order", () => {
    const come = {
      status: "retiring" as const,
      offboarding_at: "2026-10-01T09:00:00Z",
      purge_due_at: "2026-10-12T00:00:00Z",
      last_export_taken_at: "2026-10-01T10:00:00Z",
    };
    const purge: LifecycleNote = {
      key: "purge",
      text: "Being offboarded: its purge date, 12 October 2026, has come.",
      tone: "warn",
    };
    // Still served: the copy it began with was taken while its data could
    // still change.
    expect(deploymentLifecycleNotes(row(come), NOW)).toEqual([
      purge,
      {
        key: "steps",
        text: `Left to do, in order: suspend it, export it, then retire it. ${COPY_RULE}`,
        tone: "warn",
      },
    ]);
    expect(COPY_RULE.startsWith(LAST_COPY_RULE)).toBe(true);
    // Suspended since: the suspension is said first, then what is left.
    const stopped = {
      ...come,
      suspended_reason: "Its notice ended.",
      suspended_at: "2026-10-12T08:00:00Z",
    };
    expect(deploymentLifecycleNotes(row(stopped), NOW)).toEqual([
      { key: "suspended", text: "Suspended: Its notice ended.", tone: "warn" },
      purge,
      {
        key: "steps",
        text: `Left to do, in order: export it, then retire it. ${COPY_RULE}`,
        tone: "warn",
      },
    ]);
    // A copy taken since its own organisation was stopped: only retiring it
    // is left, and which copy counts goes unsaid.
    expect(
      deploymentLifecycleNotes(
        row({
          ...stopped,
          last_export_taken_at: "2026-10-12T09:00:00Z",
          last_export_service_stopped: true,
        }),
        NOW,
      ),
    ).toEqual([
      { key: "suspended", text: "Suspended: Its notice ended.", tone: "warn" },
      purge,
      { key: "steps", text: "Left to do: retire it.", tone: "warn" },
    ]);
    // Its dump began before the suspension and was recorded after it: export
    // it again.
    expect(
      deploymentLifecycleNotes(
        row({
          ...stopped,
          last_export_taken_at: "2026-10-12T07:40:00Z",
          last_export_service_stopped: false,
        }),
        NOW,
      ).find((n) => n.key === "steps")?.text,
    ).toBe(`Left to do, in order: export it, then retire it. ${COPY_RULE}`);
  });

  test("before the purge date, or never built, no steps are named", () => {
    expect(
      deploymentLifecycleNotes(
        row({ status: "retiring", purge_due_at: "2027-01-30T00:00:00Z" }),
        NOW,
      ).map((n) => n.key),
    ).toEqual(["purge"]);
    expect(
      deploymentLifecycleNotes(
        row({ status: "retiring", built_at: null, purge_due_at: "2026-10-12T00:00:00Z" }),
        NOW,
      ),
    ).toEqual([
      {
        key: "purge",
        text: "Being offboarded: its purge date, 12 October 2026, has come.",
        tone: "warn",
      },
    ]);
  });

  test("suspended while being offboarded: both are said, the suspension first", () => {
    expect(
      deploymentLifecycleNotes(
        row({
          status: "retiring",
          suspended_reason: "The client stopped paying during its notice.",
          purge_due_at: "2027-01-30T00:00:00Z",
        }),
        NOW,
      ),
    ).toEqual([
      {
        key: "suspended",
        text: "Suspended: The client stopped paying during its notice.",
        tone: "warn",
      },
      {
        key: "purge",
        text: "Being offboarded: its project is due to be purged on 30 January 2027.",
        tone: "warn",
      },
    ]);
  });

  test("moved: the old address, while it still sends people on, and that it stays the client's", () => {
    const moved = row({
      origin: "https://acme-group.cloveerp.com",
      previous_address: "acme",
      previous_address_until: "2027-01-10T12:00:00Z",
    });
    expect(deploymentLifecycleNotes(moved, NOW)).toEqual([
      {
        key: "moved",
        text: "Was acme.cloveerp.com, which sends people here until 10 January 2027 and is never given to another client.",
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
    // Without the times a copy is judged by, none counts.
    const exportedBefore: ClientDeployment = {
      ...older,
      status: "retiring",
      built_at: "2026-06-01T09:00:00Z",
      offboarding_at: "2026-10-01T09:00:00Z",
      purge_due_at: "2026-10-12T00:00:00Z",
      suspended_reason: "Its notice ended.",
      suspended_at: "2026-10-05T09:00:00Z",
      last_export_at: "2026-10-06T09:00:00Z",
    };
    expect(exportedSinceServiceStopped(exportedBefore)).toBe(false);
    expect(offboardingStepsLeft(exportedBefore, new Date("2026-10-12T12:00:00Z"))).toEqual([
      "export",
      "retire",
    ]);
  });
});
