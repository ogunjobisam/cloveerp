import { expect, test } from "bun:test";

import { actingAs, personaChoices, type DemonstrationPersonas } from "./persona";

const priya = {
  principal_id: "p-1",
  code: "finance",
  display_name: "Priya Shah",
  roles: ["Finance"],
};

const base: DemonstrationPersonas = {
  is_demonstration: true,
  signed_in: { principal_id: "me", display_name: "Sam Visitor" },
  acting_as: null,
  personas: [priya],
};

test("outside a demonstration, or with nobody to act as, there is nothing to choose", () => {
  expect(personaChoices(undefined, "Yourself")).toEqual([]);
  expect(personaChoices(null, "Yourself")).toEqual([]);
  expect(
    personaChoices(
      { is_demonstration: false, signed_in: null, acting_as: null, personas: [] },
      "Yourself",
    ),
  ).toEqual([]);
  expect(personaChoices({ ...base, personas: [] }, "Yourself")).toEqual([]);
});

test("yourself comes first, then each person with their roles, and yourself is in force", () => {
  expect(personaChoices(base, "Yourself")).toEqual([
    { persona_id: null, name: "Yourself (Sam Visitor)", roles: [], current: true },
    { persona_id: "p-1", name: "Priya Shah", roles: ["Finance"], current: false },
  ]);
});

test("acting as a person marks that person, not yourself", () => {
  const acting: DemonstrationPersonas = {
    ...base,
    acting_as: {
      principal_id: "p-1",
      display_name: "Priya Shah",
      chosen_at: "2026-10-04T09:00:00Z",
    },
  };
  const lines = personaChoices(acting, "Yourself");
  expect(lines.map((l) => l.current)).toEqual([false, true]);
  expect(actingAs(acting)?.display_name).toBe("Priya Shah");
});

test("nobody is being acted as unless the database says so", () => {
  expect(actingAs(undefined)).toBeNull();
  expect(actingAs(base)).toBeNull();
  expect(
    actingAs({
      ...base,
      acting_as: { principal_id: "me", display_name: "Sam Visitor", chosen_at: "x" },
    }),
  ).toBeNull();
});
