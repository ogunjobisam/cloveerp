import { describe, expect, test } from "bun:test";
import {
  completeCount,
  nextScreen,
  nextStep,
  settingsScreenFor,
  stepState,
  tileFor,
  type SetupScreenProgress,
  type WalkthroughStep,
} from "./walkthrough";

function step(over: Partial<WalkthroughStep> & { code: string; seq: number }): WalkthroughStep {
  return {
    title: over.code,
    why: "",
    action_label: "Do it",
    action_fn: null,
    permission_code: "administration.configure",
    permitted: true,
    observable: true,
    satisfied: false,
    evidence: null,
    done_at: null,
    dismissed_at: null,
    complete: false,
    blocked: false,
    requires: [],
    ...over,
  };
}

describe("the next step", () => {
  test("is the first step that is neither complete nor waiting on another", () => {
    const steps = [
      step({ code: "a", seq: 1, complete: true, satisfied: true }),
      step({ code: "b", seq: 2, blocked: true }),
      step({ code: "c", seq: 3 }),
    ];
    expect(nextStep(steps)?.code).toBe("c");
  });

  test("does not depend on the order the rows arrived in", () => {
    const steps = [step({ code: "c", seq: 3 }), step({ code: "b", seq: 2 })];
    expect(nextStep(steps)?.code).toBe("b");
  });

  test("is nothing when every step is complete or waiting", () => {
    expect(
      nextStep([
        step({ code: "a", seq: 1, complete: true }),
        step({ code: "b", seq: 2, blocked: true }),
      ]),
    ).toBeNull();
  });
});

describe("a step's state", () => {
  test("a set-aside step reads as set aside, not as done", () => {
    const s = step({ code: "a", seq: 1, complete: true, dismissed_at: "2026-09-13T00:00:00Z" });
    expect(stepState(s, null)).toBe("aside");
  });

  test("evidence outranks a dismissal", () => {
    const s = step({
      code: "a",
      seq: 1,
      complete: true,
      satisfied: true,
      dismissed_at: "2026-09-13T00:00:00Z",
    });
    expect(stepState(s, null)).toBe("done");
  });

  test("the next step is the only one called next", () => {
    const a = step({ code: "a", seq: 1 });
    const b = step({ code: "b", seq: 2 });
    const next = nextStep([a, b]);
    expect(stepState(a, next)).toBe("next");
    expect(stepState(b, next)).toBe("todo");
  });

  test("a step waiting on another is waiting even when nothing else is done", () => {
    expect(stepState(step({ code: "a", seq: 1, blocked: true }), null)).toBe("waiting");
  });
});

describe("the setup order", () => {
  const p = (seq: number, next: SetupScreenProgress["next"]): SetupScreenProgress => ({
    screen_path: `/s${seq}`,
    seq,
    title: `S${seq}`,
    blurb: "",
    total: 3,
    complete: next ? 1 : 3,
    next,
  });

  test("the next screen is the first in the order with something left to do", () => {
    const next = { code: "x.y", title: "Do", action_label: "Do it" };
    expect(nextScreen([p(3, next), p(1, null), p(2, next)])?.seq).toBe(2);
  });

  test("and nothing when every screen is done", () => {
    expect(nextScreen([p(1, null), p(2, null)])).toBeNull();
  });

  test("complete counts what is complete", () => {
    expect(
      completeCount([step({ code: "a", seq: 1, complete: true }), step({ code: "b", seq: 2 })]),
    ).toBe(1);
  });
});

describe("which screen a path belongs to", () => {
  test("a Settings tile and a path beneath it both resolve to the tile", () => {
    expect(settingsScreenFor("/administration/organisation")).toBe("/administration/organisation");
    expect(settingsScreenFor("/administration/organisation/anything")).toBe(
      "/administration/organisation",
    );
  });

  test("the longest tile wins when one tile path prefixes another", () => {
    expect(tileFor("/finance/cost-centres")?.path).toBe("/finance/cost-centres");
  });

  test("a Work tile is a tile but not a Settings screen", () => {
    expect(tileFor("/master-data")?.settings).toBe(false);
    expect(settingsScreenFor("/master-data")).toBeNull();
  });

  test("the Settings home and an unknown path are nobody's tile", () => {
    expect(tileFor("/settings")).toBeNull();
    expect(tileFor("/no-such-screen")).toBeNull();
  });
});
