import { describe, expect, test } from "bun:test";

import {
  approvalStillWaiting,
  EXPLAINED_MOVE_READS_AGAIN,
  MOVE_READS_AGAIN,
  movesToDraw,
  type Transition,
} from "../components/erp/available-transitions";
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

/**
 * What a document's page says after an approve press, and which moves it draws
 * beside the state it shows (R-06, J-120, J-33).
 */
describe("an approval still waiting", () => {
  test("said while the document keeps its approve move and did not reach its state", () => {
    const waiting = [
      move("approve", { refused: "CLOVEERP_DOCUMENT_APPROVAL_PENDING" }),
      move("reject"),
    ];
    expect(approvalStillWaiting("pending_approval", waiting)).toBe(true);
  });

  test("not said once the moves read again no longer hold approve, whatever state it reached", () => {
    const movedOn = [move("send", { to_state: "sent" }), move("cancel", { to_state: "cancelled" })];
    for (const state of ["approved", "confirmed", "sent"]) {
      expect(approvalStillWaiting(state, movedOn)).toBe(false);
    }
    expect(approvalStillWaiting("approved", [])).toBe(false);
  });

  test("not said when the door answered the state approve leads to, or no state at all", () => {
    expect(approvalStillWaiting("approved", [move("approve")])).toBe(false);
    expect(approvalStillWaiting(undefined, [move("approve")])).toBe(false);
    expect(approvalStillWaiting(null, [move("approve")])).toBe(false);
  });
});

describe("the moves a document's page draws", () => {
  const withDocument = [move("send", { to_state: "sent" })];
  const live = [move("approve"), move("reject")];

  test("the live read's when it answered no earlier than the document", () => {
    expect(
      movesToDraw(
        { data: live, error: null, dataUpdatedAt: 200 },
        { transitions: withDocument, dataUpdatedAt: 200 },
      ),
    ).toBe(live);
    expect(
      movesToDraw(
        { data: live, error: null, dataUpdatedAt: 300 },
        { transitions: withDocument, dataUpdatedAt: 200 },
      ),
    ).toBe(live);
  });

  test("the document's own when the live read answered for the state before", () => {
    expect(
      movesToDraw(
        { data: live, error: null, dataUpdatedAt: 100 },
        { transitions: withDocument, dataUpdatedAt: 200 },
      ),
    ).toBe(withDocument);
  });

  test("the document's own when the live read failed, though it keeps its last answer", () => {
    expect(
      movesToDraw(
        { data: live, error: new Error("timeout"), dataUpdatedAt: 300 },
        { transitions: withDocument, dataUpdatedAt: 200 },
      ),
    ).toBe(withDocument);
  });

  test("the document's own before the live read has answered", () => {
    expect(
      movesToDraw(
        { data: undefined, error: null, dataUpdatedAt: 0 },
        { transitions: withDocument, dataUpdatedAt: 200 },
      ),
    ).toBe(withDocument);
  });
});

describe("what a move reads again", () => {
  test("a purchase order's own sections, so issuing it shows its confirmation and On its way", () => {
    for (const reads of [MOVE_READS_AGAIN, EXPLAINED_MOVE_READS_AGAIN]) {
      for (const key of [
        "erp_document",
        "erp_documents",
        "erp_available_transitions",
        "erp_purchase_order_sends",
        "erp_purchase_order_confirmation",
        "erp_awaiting_confirmations",
        "erp_order_shipping_notices",
      ]) {
        expect(reads).toContain(key);
      }
    }
    expect(MOVE_READS_AGAIN).toContain("erp_document_approval_chain");
    expect(MOVE_READS_AGAIN).toContain("erp_my_approvals");
  });
});
