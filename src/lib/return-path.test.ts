import { describe, expect, test } from "bun:test";

import { safeReturnPath } from "./return-path";

describe("where sign-in sends somebody back to", () => {
  test("the page they asked for, with its query", () => {
    expect(safeReturnPath("/inventory")).toBe("/inventory");
    expect(safeReturnPath("/documents/abc?tab=lines")).toBe("/documents/abc?tab=lines");
  });

  test("never another site", () => {
    for (const bad of [
      "//evil.example",
      "/\\evil.example",
      "https://evil.example/",
      "evil.example",
      "javascript:alert(1)",
    ])
      expect(safeReturnPath(bad)).toBeNull();
  });

  test("never back to the sign-in screen itself", () => {
    expect(safeReturnPath("/signin")).toBeNull();
    expect(safeReturnPath("/signin?redirect=/inventory")).toBeNull();
  });

  test("nothing, when there is nothing or it hides a control character", () => {
    expect(safeReturnPath(undefined)).toBeNull();
    expect(safeReturnPath("")).toBeNull();
    expect(safeReturnPath("/in" + String.fromCharCode(10) + "ventory")).toBeNull();
  });
});
