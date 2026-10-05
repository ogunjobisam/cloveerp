import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { emptySession, type ErpSession } from "./erp";
import { INSTALLABLE_MODULES, moduleOfPath, moduleOffered, tileOffered } from "./installed-modules";
import { allTiles, MODULES } from "./modules";

/**
 * A module the organisation has not installed is not offered (J-05, J-89).
 * The session names the modules in force; a session that does not say hides
 * nothing, so a site ahead of its database behaves as before.
 */

function session(modules?: string[]): ErpSession {
  const all = allTiles()
    .flatMap((t) => (t.permission === undefined ? [] : [t.permission].flat()))
    .filter((p, i, a) => a.indexOf(p) === i);
  return { ...emptySession, permissions: all, ...(modules ? { modules } : {}) };
}

const tile = (path: string) => {
  const found = allTiles().find((t) => t.path === path);
  if (!found) throw new Error(`no tile at ${path}`);
  return found;
};

describe("the screens that need their module installed", () => {
  test("exactly Planning, Manufacturing and Quality are tagged, each with its own key", () => {
    const tagged = MODULES.filter((m) => m.module).map((m) => [m.path, m.module, m.key]);
    expect(tagged.sort()).toEqual([
      ["/planning", "planning", "planning"],
      ["/production", "production", "production"],
      ["/quality", "quality", "quality"],
    ]);
    expect([...INSTALLABLE_MODULES].sort()).toEqual(["planning", "production", "quality"]);
  });

  test("their tiles carry the tag, and no other tile does", () => {
    const tagged = allTiles()
      .filter((t) => t.module)
      .map((t) => t.path)
      .sort();
    expect(tagged).toEqual(["/planning", "/production", "/quality"]);
  });

  test("a path belongs to the module of the longest tile it sits under", () => {
    expect(moduleOfPath("/production")).toBe("production");
    expect(moduleOfPath("/production/anything")).toBe("production");
    expect(moduleOfPath("/quality")).toBe("quality");
    expect(moduleOfPath("/planning")).toBe("planning");
    expect(moduleOfPath("/inventory/forecast")).toBeUndefined();
    expect(moduleOfPath("/")).toBeUndefined();
    expect(moduleOfPath("/productions")).toBeUndefined();
  });

  test("every first step on those screens is placed in its module", () => {
    const dir = join(import.meta.dir, "..", "..", "supabase", "migrations");
    const seeds = readdirSync(dir)
      .filter((f) => f.endsWith(".sql"))
      .map((f) => readFileSync(join(dir, f), "utf8"))
      .filter((s) => s.includes("erp_ref.first_run_step"))
      .join("\n");
    const insert =
      /insert into erp_ref\.first_run_step\s*\([^)]*\)\s*values([\s\S]*?)(?:on conflict|;\s*$)/gm;
    const paths = new Set<string>();
    for (const block of seeds.matchAll(insert)) {
      for (const row of block[1]!.matchAll(/'(\/[^']*)'/g)) paths.add(row[1]!);
    }
    const inModules = [...paths].filter((p) => /^\/(planning|production|quality)(\/|$)/.test(p));
    expect(inModules.length).toBeGreaterThan(0);
    for (const p of inModules) {
      expect(moduleOfPath(p)).toBe(p.split("/")[1] as "planning" | "production" | "quality");
    }
  });
});

describe("what is offered", () => {
  const notInstalled = session(["finance", "inventory", "procurement", "sales"]);

  test("a tagged tile is hidden when its module is not in force", () => {
    expect(tileOffered(tile("/production"), notInstalled, false)).toBe(false);
    expect(tileOffered(tile("/quality"), notInstalled, false)).toBe(false);
    expect(tileOffered(tile("/planning"), notInstalled, false)).toBe(false);
  });

  test("it is shown once its module is, and when the session does not say", () => {
    expect(tileOffered(tile("/quality"), session(["quality"]), false)).toBe(true);
    expect(tileOffered(tile("/production"), session(), false)).toBe(true);
  });

  test("an untagged tile is left to the permission rule", () => {
    expect(tileOffered(tile("/sales"), notInstalled, false)).toBe(true);
    expect(tileOffered(tile("/sales"), { ...emptySession, modules: [] }, false)).toBe(false);
  });

  test("the platform-only rule still applies", () => {
    expect(tileOffered(tile("/commercial/quotes"), session(), false)).toBe(false);
    expect(tileOffered(tile("/commercial/quotes"), session(), true)).toBe(true);
  });

  test("anything not tied to an installable module is always offered", () => {
    expect(moduleOffered(notInstalled, "quality")).toBe(false);
    expect(moduleOffered(notInstalled, "production")).toBe(false);
    expect(moduleOffered(notInstalled, "inventory")).toBe(true);
    expect(moduleOffered(notInstalled, "logistics")).toBe(true);
    expect(moduleOffered(notInstalled, null)).toBe(true);
    expect(moduleOffered(notInstalled, undefined)).toBe(true);
    expect(moduleOffered(session(), "quality")).toBe(true);
  });
});
