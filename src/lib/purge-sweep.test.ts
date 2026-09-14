import { describe, expect, test } from "bun:test";

import { purgeSweepSummary, readPurgeSweep } from "./purge-sweep";

/** The shape erp_platform_purge_due_tenants builds with jsonb_build_object. */
const answer = (codes: string[], grace_days = 7) => ({
  purged: codes.length,
  organisations: codes.map((code, i) => ({
    tenant_id: `00000000-0000-0000-0000-00000000000${i}`,
    code,
    deleted_at: "2026-09-01T09:00:00+00:00",
  })),
  grace_days,
});

/** What the screen says for an answer; an unreadable one fails the test here. */
const said = (data: unknown) => {
  const sweep = readPurgeSweep(data);
  if (sweep === null) throw new Error("the sweep's answer could not be read");
  return purgeSweepSummary(sweep);
};

describe("reading the deletion sweep's answer", () => {
  test("is one object with a count, not a list whose length is the count", () => {
    const sweep = readPurgeSweep(answer(["acme", "beta"]));
    expect(sweep?.purged).toBe(2);
    expect(sweep?.organisations.map((o) => o.code)).toEqual(["acme", "beta"]);
    expect(sweep?.grace_days).toBe(7);
  });

  test("an empty sweep is a real zero from the database", () => {
    expect(readPurgeSweep(answer([]))).toEqual({ purged: 0, organisations: [], grace_days: 7 });
  });

  test("takes the door's count when the list is missing, and the list when the count is", () => {
    expect(readPurgeSweep({ purged: 3 })?.purged).toBe(3);
    expect(readPurgeSweep({ organisations: answer(["acme"]).organisations })?.purged).toBe(1);
  });

  test("keeps only entries that name an organisation", () => {
    const sweep = readPurgeSweep({
      purged: 1,
      organisations: [{ code: "acme" }, { tenant_id: "x" }, null],
    });
    expect(sweep?.organisations).toEqual([{ tenant_id: "", code: "acme", deleted_at: null }]);
  });

  test("anything else cannot be read, rather than reading as nothing purged", () => {
    expect(readPurgeSweep(null)).toBeNull();
    expect(readPurgeSweep("2")).toBeNull();
    expect(readPurgeSweep([{ purged: 1 }])).toBeNull();
    expect(readPurgeSweep({ purged: "2" })).toBeNull();
    expect(readPurgeSweep({ grace_days: 7 })).toBeNull();
  });
});

describe("saying what the sweep did", () => {
  test("names every organisation it purged", () => {
    expect(said(answer(["acme", "beta"]))).toBe("Purged 2 organisations: acme, beta.");
    expect(said(answer(["acme"]))).toBe("Purged 1 organisation: acme.");
  });

  test("still gives the count when no organisation is named", () => {
    expect(said({ purged: 2 })).toBe("Purged 2 organisations.");
  });

  test("says why nothing was purged, in the grace period that was asked for", () => {
    expect(said(answer([]))).toBe(
      "No organisation was purged: none had asked to be deleted more than 7 days ago.",
    );
    expect(said(answer([], 1))).toBe(
      "No organisation was purged: none had asked to be deleted more than 1 day ago.",
    );
    expect(said({ purged: 0 })).toBe("No organisation was purged: none was past its grace period.");
  });
});
