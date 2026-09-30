import { expect, test } from "bun:test";

import { rolesLabel, type SessionRole } from "./roles-label";

const role = (code: string, name: string, support = false): SessionRole => ({
  code,
  name,
  support,
});
const byName = (r: SessionRole) => r.name;

test("no roles is no line", () => {
  expect(rolesLabel(undefined, byName, "as support")).toBe("");
  expect(rolesLabel([], byName, "as support")).toBe("");
});

test("one role is its name", () => {
  expect(rolesLabel([role("administrator", "Administrator")], byName, "as support")).toBe(
    "Administrator",
  );
});

test("two roles are both named, more are counted", () => {
  const two = [role("administrator", "Administrator"), role("sales", "Sales")];
  expect(rolesLabel(two, byName, "as support")).toBe("Administrator · Sales");
  const five = [...two, role("finance", "Finance"), role("quality", "Quality"), role("x", "X")];
  expect(rolesLabel(five, byName, "as support")).toBe("Administrator · Sales +3");
});

test("a visit through a support window says so", () => {
  expect(rolesLabel([role("administrator", "Administrator", true)], byName, "as support")).toBe(
    "Administrator · as support",
  );
});

test("a member who also holds a support grant is not a visitor", () => {
  const mixed = [role("administrator", "Administrator", true), role("sales", "Sales")];
  expect(rolesLabel(mixed, byName, "as support")).toBe("Administrator · Sales");
});

test("the names come from the resolver, so a renamed role reads renamed", () => {
  expect(rolesLabel([role("administrator", "Administrator")], () => "Admin", "as support")).toBe(
    "Admin",
  );
});
