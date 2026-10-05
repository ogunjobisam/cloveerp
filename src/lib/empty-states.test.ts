import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { MODULES as MODULE_LIST } from "./modules";

/**
 * An empty state says what to do, and the way it offers leads somewhere.
 *
 * A panel is empty for one of two reasons. Either nothing is wrong — no
 * recalls, no match exceptions, no overdue jobs — and the sentence alone is
 * the whole answer. Or something has not been set up yet, and the reader now
 * has to work out which of thirty-four screens sets it up. That second case is
 * the tax an ERP charges for its own breadth, and it is charged one panel at a
 * time until somebody counts them.
 *
 * So two properties, both checkable from the source without a browser:
 *
 *   1. Every empty state is a sentence, not a label. "No signals." tells you
 *      the count; "No signals. Nothing in this organisation is ageing in a way
 *      that suggests adoption has stalled." tells you what it means. The check
 *      is crude — a full stop and enough words to have said something — but it
 *      is enough to catch a new panel shipped with a two-word shrug.
 *
 *   2. Every destination an empty state offers is a screen that exists. A
 *      GoTo to a path with no route file is a dead end that renders as a
 *      button and behaves as a 404, and nothing else in the build would notice:
 *      TanStack's `to` accepts a string here, so the compiler will not.
 */

const ROOT = join(import.meta.dir, "..", "..");
const MODULES = readFileSync(join(ROOT, "src", "lib", "modules.tsx"), "utf8");

/** Every screen path the router serves, derived from the route files. */
function routePaths(): Set<string> {
  const out = new Set<string>();
  const walk = (dir: string, prefix: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) {
        walk(join(dir, entry.name), `${prefix}/${entry.name}`);
        continue;
      }
      if (!entry.name.endsWith(".tsx") || entry.name.startsWith("__")) continue;
      const base = entry.name.replace(/\.tsx$/, "");
      out.add(base === "index" ? prefix || "/" : `${prefix}/${base}`);
    }
  };
  walk(join(ROOT, "src", "routes"), "");
  return out;
}

/** Source files that can render an empty state. */
function sourceFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (entry.name.endsWith(".tsx") && !entry.name.includes(".test.")) out.push(path);
    }
  };
  walk(join(ROOT, "src", "routes"));
  walk(join(ROOT, "src", "components", "erp"));
  return out;
}

describe("an empty state leads somewhere", () => {
  const paths = routePaths();

  test("the route files produce the paths the registry uses", () => {
    // Guards the guard: if this ever came back empty, every assertion below
    // would pass by having nothing to compare against.
    expect(paths.size).toBeGreaterThan(30);
    expect(paths.has("/master-data")).toBe(true);
    expect(paths.has("/administration/packs")).toBe(true);
  });

  test("every module panel's emptyAction points at a screen that exists", () => {
    const targets = [...MODULES.matchAll(/emptyAction:\s*\{[^}]*to:\s*"([^"]+)"/g)].map(
      (m) => m[1]!,
    );
    expect(targets.length).toBeGreaterThan(0);
    for (const to of targets) expect(paths.has(to)).toBe(true);
  });

  test("every GoTo in a screen points at a screen that exists", () => {
    const targets: { file: string; to: string }[] = [];
    for (const file of sourceFiles()) {
      const src = readFileSync(file, "utf8");
      for (const m of src.matchAll(/<GoTo\s+to="([^"]+)"/g)) targets.push({ file, to: m[1]! });
    }
    expect(targets.length).toBeGreaterThan(0);
    // Named rather than counted: a bare `false` here would say a link is dead
    // without saying which one, on a check whose whole point is finding it.
    const dead = targets.filter((t) => !paths.has(t.to)).map((t) => `${t.to} in ${t.file}`);
    expect(dead).toEqual([]);
  });
});

describe("an empty state is a sentence", () => {
  /**
   * Short enough to be a shrug. Anything under this is a count rather than an
   * explanation — "No signals.", "No scenarios.", "No items yet." — which is
   * exactly the shape this is here to keep out.
   */
  const SHRUG = 40;

  test("no module panel is empty with a two-word shrug", () => {
    const empties = [...MODULES.matchAll(/^\s*empty:\s*\n?\s*"((?:[^"\\]|\\.)*)"/gm)].map(
      (m) => m[1]!,
    );
    expect(empties.length).toBeGreaterThan(20);
    const shrugs = empties.filter((e) => e.length < SHRUG);
    expect(shrugs).toEqual([]);
  });

  test("every empty state ends the sentence it started", () => {
    const empties = [...MODULES.matchAll(/^\s*empty:\s*\n?\s*"((?:[^"\\]|\\.)*)"/gm)].map(
      (m) => m[1]!,
    );
    const unfinished = empties.filter((e) => !/[.?!]$/.test(e));
    expect(unfinished).toEqual([]);
  });
});

/**
 * An empty state that sends you to a card above names a card the screen draws.
 *
 * Action cards were once all headed "Actions", and empty states said "Define
 * one under Actions above". The cards are now headed by what they act on, so
 * on Notifications that sentence pointed at a heading the screen no longer
 * had (J-163). "Actions" is still right where the page header carries the
 * button of that name, which HeaderActions draws when it is given no label.
 */
describe("an empty state names a card its screen draws", () => {
  test("every 'under … above' names an action card's heading on the same screen", () => {
    const sentences: { file: string; heading: string }[] = [];
    for (const file of sourceFiles()) {
      const src = readFileSync(file, "utf8");
      for (const m of src.matchAll(/under ([A-Z][A-Za-z ,'-]*?) above/g)) {
        sentences.push({ file, heading: m[1]! });
      }
    }
    expect(sentences.length).toBeGreaterThan(5);
    const nowhere = sentences
      .filter(({ file, heading }) => {
        const src = readFileSync(file, "utf8");
        if (heading === "Actions") return !src.includes("<HeaderActions>");
        return !src.includes(`title="${heading}"`) && !src.includes(`title={ui("${heading}")}`);
      })
      .map(({ file, heading }) => `${heading} in ${file}`);
    expect(nowhere).toEqual([]);
  });
});

describe("an inquiry that can answer nothing says what nothing means", () => {
  /**
   * J-95: Eliminations, for a group with nothing eliminated yet, and Budget
   * position, for a code no budget in use carries this year, each answered a
   * bare "None". Each door answers an empty list when there is nothing, so
   * each inquiry says what that means instead.
   */
  const finance = MODULE_LIST.find((m) => m.path === "/finance");

  test("Eliminations and Budget position each say why their answer is empty", () => {
    const says = (fn: string) => (finance?.inquiries ?? []).find((i) => i.fn === fn)?.empty;
    expect(says("erp_eliminations")).toBe("Nothing has been eliminated in this group yet.");
    expect(says("erp_budget_position")).toBe("No budget in use has that code this year.");
  });

  test("every inquiry's empty answer is a finished sentence", () => {
    const empties = MODULE_LIST.flatMap((m) => m.inquiries ?? []).flatMap((i) =>
      i.empty === undefined ? [] : [i.empty],
    );
    expect(empties.length).toBeGreaterThan(1);
    expect(empties.filter((e) => !/[.?!]$/.test(e))).toEqual([]);
  });
});
