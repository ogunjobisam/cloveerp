import { describe, expect, test } from "bun:test";

import { allTiles } from "./modules";
import { emptySession, hasPermission, type ErpSession } from "./erp";

function holding(...permissions: string[]): ErpSession {
  return { ...emptySession, permissions };
}

describe("a permission the session holds", () => {
  test("one code is held or it is not", () => {
    expect(hasPermission(holding("inventory.read"), "inventory.read")).toBe(true);
    expect(hasPermission(holding("inventory.read"), "inventory.move")).toBe(false);
    expect(hasPermission(null, "inventory.read")).toBe(false);
  });

  test("a list is any of them", () => {
    expect(hasPermission(holding("inventory.scan"), ["inventory.scan", "inventory.move"])).toBe(
      true,
    );
    expect(hasPermission(holding("inventory.move"), ["inventory.scan", "inventory.move"])).toBe(
      true,
    );
    expect(hasPermission(holding("inventory.read"), ["inventory.scan", "inventory.move"])).toBe(
      false,
    );
    expect(hasPermission(holding("inventory.read"), [])).toBe(false);
  });

  test("the scanner is offered to a scanner operator and to the warehouse", () => {
    const scanner = allTiles().find((t) => t.path === "/device");
    expect(scanner?.permission).toBeDefined();
    const permission = scanner?.permission ?? [];
    expect(hasPermission(holding("inventory.scan", "inventory.read"), permission)).toBe(true);
    expect(hasPermission(holding("inventory.move"), permission)).toBe(true);
    expect(hasPermission(holding("inventory.read"), permission)).toBe(false);
  });
});
