import { describe, expect, test } from "bun:test";

import { seatFigure } from "./platform-seats";

describe("a seat figure", () => {
  test("with no contract or plan, the count alone", () => {
    expect(seatFigure({ used: 3, limit: null, limit_from: null })).toEqual({
      value: "3",
      hint: "No contract or plan yet.",
      over: false,
    });
  });

  test("an unlimited plan says so", () => {
    expect(seatFigure({ used: 12, limit: null, limit_from: "plan" })).toEqual({
      value: "12",
      hint: "The plan sets no limit.",
      over: false,
    });
  });

  test("within what the contract sold", () => {
    expect(seatFigure({ used: 6, limit: 6, limit_from: "contract" })).toEqual({
      value: "6 of 6",
      hint: "As sold on the contract.",
      over: false,
    });
  });

  test("past what the contract sold, by how many", () => {
    expect(seatFigure({ used: 9, limit: 6, limit_from: "contract" })).toEqual({
      value: "9 of 6",
      hint: "3 more than the contract sold.",
      over: true,
    });
  });

  test("past what the plan allows", () => {
    expect(seatFigure({ used: 101, limit: 100, limit_from: "plan" })).toEqual({
      value: "101 of 100",
      hint: "1 more than the plan allows.",
      over: true,
    });
  });

  test("within the plan", () => {
    expect(seatFigure({ used: 7, limit: 100, limit_from: "plan" }).hint).toBe("The plan's limit.");
  });
});
