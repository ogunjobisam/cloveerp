import { describe, expect, test } from "bun:test";

import {
  maySeedDemo,
  onboardingView,
  pastedToken,
  readSelfServiceChange,
  selfServiceIsOpen,
  usableReason,
} from "./self-service";

const TOKEN = "0123456789abcdef".repeat(4);

describe("the switch's answer", () => {
  test("is open only for a literal true", () => {
    expect(selfServiceIsOpen(true)).toBe(true);
  });

  test("is closed for anything else, including what a stub or an old schema sends", () => {
    for (const answer of [false, null, undefined, [], {}, "true", 1, [true], { open: true }]) {
      expect(selfServiceIsOpen(answer)).toBe(false);
    }
  });
});

describe("whether demo data is offered", () => {
  test("to platform operators and owners, whatever the switch says", () => {
    for (const open of [undefined, true, false, null]) {
      expect(maySeedDemo({ staff: true, open })).toBe(true);
    }
  });

  test("to anybody else only while self-service sign-up is open", () => {
    expect(maySeedDemo({ staff: false, open: true })).toBe(true);
    for (const open of [undefined, false, null, "true", { open: true }]) {
      expect(maySeedDemo({ staff: false, open })).toBe(false);
    }
  });
});

describe("a change to the switch", () => {
  test("reads the door's answer", () => {
    expect(
      readSelfServiceChange({
        open: true,
        reason: "Trial week for the partner programme",
        updated_at: "2026-09-14T02:00:00Z",
      }),
    ).toEqual({
      open: true,
      reason: "Trial week for the partner programme",
      updated_at: "2026-09-14T02:00:00Z",
    });
  });

  test("keeps the state when the reason or the time is missing", () => {
    expect(readSelfServiceChange({ open: false })).toEqual({
      open: false,
      reason: null,
      updated_at: null,
    });
    expect(readSelfServiceChange({ open: false, reason: "  ", updated_at: "" })).toEqual({
      open: false,
      reason: null,
      updated_at: null,
    });
  });

  test("is nothing when the answer is not that shape", () => {
    for (const answer of [null, undefined, true, [], [{ open: true }], { open: "true" }, "x"]) {
      expect(readSelfServiceChange(answer)).toBeNull();
    }
  });

  test("needs a reason with something in it", () => {
    expect(usableReason("Closing after the trial")).toBe(true);
    expect(usableReason("")).toBe(false);
    expect(usableReason("   \n\t")).toBe(false);
  });
});

describe("the screen for somebody signed in without an organisation", () => {
  test("an invitation held is the only thing shown, whoever is asking and whatever the switch", () => {
    for (const staff of [undefined, true, false]) {
      for (const open of [undefined, true, false]) {
        expect(onboardingView({ invitation: TOKEN, staff, open })).toBe("join");
      }
    }
  });

  test("an empty invitation is no invitation", () => {
    expect(onboardingView({ invitation: "  ", staff: false, open: false })).toBe("invitation-only");
  });

  test("waits until it is known whether the account is platform staff", () => {
    expect(onboardingView({ invitation: null, staff: undefined, open: false })).toBe("checking");
    expect(onboardingView({ invitation: null, staff: undefined, open: true })).toBe("checking");
  });

  test("platform staff can create, whatever the switch says", () => {
    for (const open of [undefined, true, false]) {
      expect(onboardingView({ invitation: null, staff: true, open })).toBe("create");
    }
  });

  test("somebody else waits for the switch", () => {
    expect(onboardingView({ invitation: null, staff: false, open: undefined })).toBe("checking");
  });

  test("somebody else can create only while self-service sign-up is open", () => {
    expect(onboardingView({ invitation: null, staff: false, open: true })).toBe("create");
    expect(onboardingView({ invitation: null, staff: false, open: false })).toBe("invitation-only");
  });
});

describe("a pasted invitation", () => {
  test("a bare token is itself", () => {
    expect(pastedToken(`  ${TOKEN}\n`)).toBe(TOKEN);
  });

  test("a copied join link gives up its token", () => {
    expect(pastedToken(`https://cloveerp.com/join#invitation=${TOKEN}`)).toBe(TOKEN);
    expect(
      pastedToken(`https://cloveerp.com/join#invitation=${TOKEN}&signin=https%3A%2F%2Fx`),
    ).toBe(TOKEN);
  });

  test("anything else is passed on as typed, for the database to refuse", () => {
    expect(pastedToken("not a token")).toBe("not a token");
    expect(pastedToken("https://cloveerp.com/join#invitation=short")).toBe(
      "https://cloveerp.com/join#invitation=short",
    );
  });
});
