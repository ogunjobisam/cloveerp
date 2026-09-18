import { describe, expect, test } from "bun:test";

import { checkFinding, checkName, readAssurance, type AssuranceCheck } from "./assurance";

/**
 * The assurance screen says one thing, and this is the thing.
 *
 * The screen ran a hundred and some checks and drew a hundred and some rows.
 * The reader's question was never "what are the checks" — it was "does
 * everything reconcile", and that answer has to be derived correctly before it
 * can be said in one line. The two ways to get it wrong are both worth a test:
 * counting a check that could not run as a pass, which claims a reconciliation
 * nobody made, and counting it as a failure, which is a lie about the
 * organisation rather than a finding about it.
 */

const held = (code: string): AssuranceCheck => ({
  check: `erp.assert_${code}`,
  code,
  ok: true,
  summary: "ok",
  detail: null,
});

const violated = (code: string): AssuranceCheck => ({
  check: `erp.assert_${code}`,
  code,
  ok: false,
  summary: null,
  detail: `CLOVEERP_${code.toUpperCase()}: two rows disagree`,
});

/** A tenant-scoped check run by a session that is inside no organisation. */
const notRun = (code: string): AssuranceCheck => ({
  check: `erp.assert_${code}`,
  code,
  ok: null,
  summary: "not run: needs an organisation",
  detail: null,
});

describe("readAssurance", () => {
  test("everything holding is the plain verdict", () => {
    const r = readAssurance([held("a"), held("b"), held("c")]);
    expect(r.state).toBe("holds");
    expect(r.held).toBe(3);
    expect(r.skipped).toBe(0);
    expect(r.failed).toEqual([]);
    expect(r.total).toBe(3);
  });

  test("a check that could not run is neither a pass nor a failure", () => {
    const r = readAssurance([held("a"), notRun("b")]);
    // Not "holds": saying everything reconciles would claim a check nobody
    // made. Not "violated" either: nothing was found to be wrong.
    expect(r.state).toBe("partial");
    expect(r.held).toBe(1);
    expect(r.skipped).toBe(1);
    expect(r.failed).toEqual([]);
  });

  test("one failure decides the verdict whatever the rest did", () => {
    const r = readAssurance([held("a"), violated("b"), notRun("c"), held("d")]);
    expect(r.state).toBe("violated");
    expect(r.failed.map((f) => f.code)).toEqual(["b"]);
    expect(r.held).toBe(2);
    expect(r.skipped).toBe(1);
  });

  test("the failing ones keep the order the register ran them in", () => {
    const r = readAssurance([violated("b"), held("a"), violated("c")]);
    expect(r.failed.map((f) => f.code)).toEqual(["b", "c"]);
  });

  test("an empty run claims nothing", () => {
    const r = readAssurance([]);
    expect(r.total).toBe(0);
    expect(r.held).toBe(0);
    // The panel's own empty state is what a reader sees for this, and it says
    // that no checks coming back is itself unexpected.
    expect(r.failed).toEqual([]);
  });
});

describe("what a check is called and what it found", () => {
  test("the register's title, and the function when it has none", () => {
    expect(checkName({ ...held("a"), title: "Stock ties to the control account" })).toBe(
      "Stock ties to the control account",
    );
    expect(checkName(held("a"))).toBe("erp.assert_a");
  });

  test("a failure shows the refusal it raised", () => {
    expect(checkFinding(violated("ledger"))).toContain("CLOVEERP_LEDGER");
  });

  test("and a check with nothing to say is a dash rather than a blank", () => {
    expect(checkFinding({ check: "erp.assert_x", ok: true, summary: null, detail: null })).toBe(
      "—",
    );
  });
});
