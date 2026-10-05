import { expect, test } from "bun:test";

import {
  ACT_AS_HEADER,
  ACT_AS_KEY,
  actingAs,
  isDatabaseRequest,
  personaChoices,
  readTabPersona,
  withActAs,
  writeTabPersona,
  type DemonstrationPersonas,
  type TabStore,
} from "./persona";

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
    acting_as: { principal_id: "p-1", display_name: "Priya Shah" },
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
      acting_as: { principal_id: "me", display_name: "Sam Visitor" },
    }),
  ).toBeNull();
});

function memoryStore(): TabStore & { items: Map<string, string> } {
  const items = new Map<string, string>();
  return {
    items,
    getItem: (k) => items.get(k) ?? null,
    setItem: (k, v) => void items.set(k, v),
    removeItem: (k) => void items.delete(k),
  };
}

const PRIYA = "0b6c8c6e-6a3b-4a83-9d55-1f4c9a2b7e10";

test("the tab keeps whom it acts as, forgets it with null, and reads nothing that is not an id", () => {
  const store = memoryStore();
  expect(readTabPersona(store)).toBeNull();
  writeTabPersona(store, PRIYA);
  expect(store.items.get(ACT_AS_KEY)).toBe(PRIYA);
  expect(readTabPersona(store)).toBe(PRIYA);
  writeTabPersona(store, null);
  expect(readTabPersona(store)).toBeNull();
  store.items.set(ACT_AS_KEY, "Priya Shah");
  expect(readTabPersona(store)).toBeNull();
  writeTabPersona(store, "not an id");
  expect(store.items.has(ACT_AS_KEY)).toBe(false);
  expect(readTabPersona(null)).toBeNull();
});

test("storage that refuses leaves the tab acting as the person who signed in", () => {
  const refusing: TabStore = {
    getItem: () => {
      throw new Error("blocked");
    },
    setItem: () => {
      throw new Error("blocked");
    },
    removeItem: () => {
      throw new Error("blocked");
    },
  };
  expect(readTabPersona(refusing)).toBeNull();
  expect(() => writeTabPersona(refusing, PRIYA)).not.toThrow();
});

test("the header goes to the database's REST interface only, never to an Edge Function", () => {
  const project = "https://example.supabase.co";
  expect(isDatabaseRequest(`${project}/rest/v1/rpc/erp_session`, project)).toBe(true);
  expect(isDatabaseRequest(`${project}/rest/v1/rpc/erp_session`, `${project}/`)).toBe(true);
  expect(isDatabaseRequest(`${project}/functions/v1/invite`, project)).toBe(false);
  expect(isDatabaseRequest(`${project}/auth/v1/token`, project)).toBe(false);
  expect(isDatabaseRequest(`https://elsewhere.test/rest/v1/rpc/x`, project)).toBe(false);
});

test("the header names whom the tab acts as and keeps every other header", () => {
  const headers = withActAs({ Authorization: "Bearer t", apikey: "k" }, PRIYA);
  expect(headers.get(ACT_AS_HEADER)).toBe(PRIYA);
  expect(headers.get("authorization")).toBe("Bearer t");
  expect(headers.get("apikey")).toBe("k");
  expect(withActAs(new Headers([["x-client-info", "a"]]), PRIYA).get("x-client-info")).toBe("a");
});
