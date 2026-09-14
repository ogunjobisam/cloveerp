import { describe, expect, test } from "bun:test";

import { tenantStorageKey } from "./tenant-storage";

/**
 * "Recently opened" on Common data listed another organisation's products
 * (14 September): the list was stored under one key for every organisation the
 * browser had seen. These are the rules the key now keeps.
 */
describe("tenantStorageKey", () => {
  test("names the organisation beside the list", () => {
    expect(tenantStorageKey("clove.recent.products", "6f1c0a52-1d8e-4c55-9a0b-3f1e2d4c5b6a")).toBe(
      "clove.recent.products:6f1c0a52-1d8e-4c55-9a0b-3f1e2d4c5b6a",
    );
  });

  test("gives two organisations two keys for the same list", () => {
    const demo = tenantStorageKey("clove.recent.products", "a-demo");
    const foods = tenantStorageKey("clove.recent.products", "clove-foods");
    expect(demo).not.toBeNull();
    expect(foods).not.toBeNull();
    expect(demo).not.toBe(foods);
  });

  test("gives two lists in one organisation two keys", () => {
    expect(tenantStorageKey("clove.recent.products", "t1")).not.toBe(
      tenantStorageKey("clove.recent.partners", "t1"),
    );
  });

  test("never falls back to the unkeyed list", () => {
    expect(tenantStorageKey("clove.recent.products", null)).toBeNull();
    expect(tenantStorageKey("clove.recent.products", undefined)).toBeNull();
    expect(tenantStorageKey("clove.recent.products", "")).toBeNull();
    expect(tenantStorageKey("clove.recent.products", "   ")).toBeNull();
  });

  test("refuses a key with no list to name", () => {
    expect(tenantStorageKey("", "t1")).toBeNull();
  });

  test("trims the organisation id rather than filing under a padded one", () => {
    expect(tenantStorageKey("clove-erp.scope", " t1 ")).toBe("clove-erp.scope:t1");
  });
});
