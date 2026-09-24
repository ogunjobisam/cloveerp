import { describe, expect, test } from "bun:test";

import { undoMovementArgs } from "./modules";

describe("undoing a works order's movement (20260924600000)", () => {
  test("sends the movement as a number and the reason trimmed", () => {
    expect(
      undoMovementArgs({
        p_works_order_id: "wo-1",
        p_movement_id: "39191",
        p_reason: "  wrong count ",
      }),
    ).toEqual({ p_movement_id: 39191, p_reason: "wrong count" });
  });

  test("the works order, chosen only to list its movements, is not sent", () => {
    expect(
      Object.keys(
        undoMovementArgs({ p_works_order_id: "wo-1", p_movement_id: "7", p_reason: "x" }),
      ),
    ).toEqual(["p_movement_id", "p_reason"]);
  });
});
