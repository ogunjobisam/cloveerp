import { describe, expect, test } from "bun:test";

import type { Transition } from "../components/erp/available-transitions";
import {
  AWAITING_DECISION,
  DECISION_MOVES,
  awaitsDecision,
  decisionHeld,
  decisionMoves,
} from "./decision-moves";

/**
 * Approve and Reject on a list row are drawn from the database's own answer,
 * and only where its door would take them (PR11 M6). These are the rules the
 * transfers and adjustments screens draw by.
 */

const move = (code: string, extra: Partial<Transition> = {}): Transition => ({
  code,
  name: code === "approve" ? "Approve" : code === "reject" ? "Reject" : code,
  to_state: code === "reject" ? "draft" : "approved",
  permitted: true,
  guard_passes: true,
  is_automatic: false,
  refused: null,
  ...extra,
});

describe("which rows ask", () => {
  test("only a row waiting for approval asks for its moves", () => {
    expect(AWAITING_DECISION).toBe("pending_approval");
    expect(awaitsDecision("pending_approval")).toBe(true);
    for (const state of ["draft", "approved", "in_transit", "received", "closed", "posted", null]) {
      expect(awaitsDecision(state)).toBe(false);
    }
    expect(awaitsDecision(undefined)).toBe(false);
  });
});

describe("what a waiting row draws", () => {
  test("approve and reject, the way forward first, whatever order the database lists them in", () => {
    const drawn = decisionMoves("transfer_order", [move("reject"), move("approve")]);
    expect(drawn.map((t) => t.code)).toEqual(["approve", "reject"]);
    expect(DECISION_MOVES).toEqual(["approve", "reject"]);
  });

  test("no other move of the state, even one the person could complete", () => {
    const drawn = decisionMoves("transfer_order", [
      move("approve"),
      move("cancel", { to_state: "cancelled" }),
      move("submit"),
    ]);
    expect(drawn.map((t) => t.code)).toEqual(["approve"]);
  });

  test("nothing the door would refuse, nothing unpermitted, guarded or automatic", () => {
    for (const refused of [
      move("approve", { refused: "CLOVEERP_DOCUMENT_SELF_APPROVAL" }),
      move("approve", { refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
      move("approve", { permitted: false }),
      move("approve", { guard_passes: false }),
      move("approve", { is_automatic: true }),
    ]) {
      expect(decisionMoves("transfer_order", [refused])).toEqual([]);
    }
  });

  test("never a move a door makes: approving within the threshold is derived", () => {
    const drawn = decisionMoves("transfer_order", [move("approve_within_threshold")]);
    expect(drawn).toEqual([]);
  });

  test("the same rules for any type, so an adjustment gains them with its lifecycle", () => {
    const drawn = decisionMoves("stock_adjustment", [move("approve"), move("reject")]);
    expect(drawn.map((t) => t.code)).toEqual(["approve", "reject"]);
  });
});

describe("what a waiting row says when it draws nothing", () => {
  test("why, once, in the document page's words", () => {
    expect(
      decisionHeld("transfer_order", [
        move("approve", { refused: "CLOVEERP_DOCUMENT_SELF_APPROVAL" }),
        move("reject", { refused: "CLOVEERP_DOCUMENT_SELF_APPROVAL" }),
      ]),
    ).toEqual(["You asked for this approval, so somebody else gives it."]);
    expect(
      decisionHeld("transfer_order", [
        move("approve", { refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
      ]),
    ).toEqual(["Waiting on somebody else's approval."]);
  });

  test("nothing for a move the person may not make, a permission refusal, or one drawn", () => {
    expect(
      decisionHeld("transfer_order", [
        move("approve", { permitted: false, refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
        move("reject", { refused: "CLOVEERP_PERMISSION_DENIED" }),
      ]),
    ).toEqual([]);
    expect(decisionHeld("transfer_order", [move("approve")])).toEqual([]);
  });

  test("nothing about the state's other moves", () => {
    expect(
      decisionHeld("transfer_order", [
        move("cancel", { refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
      ]),
    ).toEqual([]);
  });
});
