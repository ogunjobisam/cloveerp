import { describe, expect, test } from "bun:test";

import {
  looksLikeAddress,
  readAddressList,
  readEnquiryNotify,
  rejectedAddresses,
} from "./enquiry-notify";

const ANSWER = {
  configured: ["sales@cloveerp.com"],
  recipients: ["sales@cloveerp.com"],
  falls_back_to_owners: false,
  reason: "the sales mailbox answers enquiries",
  updated_at: "2026-09-20T09:00:00Z",
};

describe("the door's answer", () => {
  test("carries both lists, the reason and when it last moved", () => {
    expect(readEnquiryNotify(ANSWER)).toEqual({
      configured: ["sales@cloveerp.com"],
      recipients: ["sales@cloveerp.com"],
      fallsBackToOwners: false,
      reason: "the sales mailbox answers enquiries",
      updatedAt: "2026-09-20T09:00:00Z",
    });
  });

  test("says when nothing is set and the owners are being told", () => {
    const answer = readEnquiryNotify({
      configured: [],
      recipients: ["owner@cloveerp.com"],
      falls_back_to_owners: true,
      reason: null,
      updated_at: null,
    });
    expect(answer?.fallsBackToOwners).toBe(true);
    expect(answer?.configured).toEqual([]);
    expect(answer?.recipients).toEqual(["owner@cloveerp.com"]);
    expect(answer?.reason).toBeNull();
  });

  test("reads the fallback off the lists when the database did not say", () => {
    expect(
      readEnquiryNotify({ configured: [], recipients: ["owner@cloveerp.com"] })?.fallsBackToOwners,
    ).toBe(true);
    expect(
      readEnquiryNotify({ configured: ["a@b.co"], recipients: ["a@b.co"] })?.fallsBackToOwners,
    ).toBe(false);
  });

  test("is null for anything that is not that shape, rather than an empty list", () => {
    for (const answer of [null, undefined, [], "", 0, true, {}, { configured: ["a@b.co"] }]) {
      expect(readEnquiryNotify(answer)).toBeNull();
    }
  });

  test("drops entries that are not addresses at all", () => {
    expect(
      readEnquiryNotify({ configured: [1, "", "a@b.co", null], recipients: ["a@b.co"] }),
    ).toEqual({
      configured: ["a@b.co"],
      recipients: ["a@b.co"],
      fallsBackToOwners: false,
      reason: null,
      updatedAt: null,
    });
  });

  test("an empty reason reads as no reason", () => {
    expect(readEnquiryNotify({ ...ANSWER, reason: "   " })?.reason).toBeNull();
  });
});

describe("what somebody typed", () => {
  test("is split on whatever separator it arrived with", () => {
    expect(readAddressList("sales@cloveerp.com, leads@cloveerp.com")).toEqual([
      "sales@cloveerp.com",
      "leads@cloveerp.com",
    ]);
    expect(readAddressList("sales@cloveerp.com; leads@cloveerp.com")).toEqual([
      "sales@cloveerp.com",
      "leads@cloveerp.com",
    ]);
    expect(readAddressList("sales@cloveerp.com\nleads@cloveerp.com")).toEqual([
      "sales@cloveerp.com",
      "leads@cloveerp.com",
    ]);
  });

  test("drops duplicates and blanks, and keeps the order typed", () => {
    expect(readAddressList("  b@b.co ,, a@a.co , b@b.co  ")).toEqual(["b@b.co", "a@a.co"]);
  });

  test("keeps case, because the local part is case-sensitive and not this form's business", () => {
    expect(readAddressList("Sales@Cloveerp.com")).toEqual(["Sales@Cloveerp.com"]);
  });

  test("empty is a list of none, which clears the setting rather than failing", () => {
    expect(readAddressList("")).toEqual([]);
    expect(readAddressList("   \n  ")).toEqual([]);
  });
});

describe("the shape check", () => {
  test("accepts what could be an address", () => {
    for (const a of ["sales@cloveerp.com", "a.b+c@sub.domain.co.uk", " padded@example.com "]) {
      expect(looksLikeAddress(a)).toBe(true);
    }
  });

  test("refuses what could not", () => {
    for (const a of ["", "sales", "sales at cloveerp.com", "sales@cloveerp", "a@@b.co", "a@b.c"]) {
      expect(looksLikeAddress(a)).toBe(false);
    }
  });

  test("names the ones to fix, so the message can be about them", () => {
    expect(rejectedAddresses("sales@cloveerp.com, nope, leads@cloveerp.com")).toEqual(["nope"]);
    expect(rejectedAddresses("sales@cloveerp.com")).toEqual([]);
  });
});
