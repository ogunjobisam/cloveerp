import { describe, expect, test } from "bun:test";

import { isPlatformOperator } from "./platform";

describe("who runs the product for customers", () => {
  test("platform operators and owners", () => {
    expect(isPlatformOperator({ is_staff: true, role: "operator" })).toBe(true);
    expect(isPlatformOperator({ is_staff: true, role: "owner" })).toBe(true);
  });

  test("not support staff, and not a customer", () => {
    expect(isPlatformOperator({ is_staff: true, role: "support" })).toBe(false);
    expect(isPlatformOperator({ is_staff: false, role: null })).toBe(false);
  });

  test("not anybody whose answer has not arrived, or says staff with no role", () => {
    expect(isPlatformOperator(undefined)).toBe(false);
    expect(isPlatformOperator({ is_staff: true, role: null })).toBe(false);
  });
});
