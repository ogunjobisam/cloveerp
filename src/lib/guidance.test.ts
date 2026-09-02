import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * Specification v1.2 Part 22, the half of it a build can check from the source.
 *
 * The help content lives in erp_ref.help_topic and the database asserts that
 * every topic's nav key and doors resolve. What the database cannot see is the
 * frontend's tile registry, so this is the other direction: every screen the
 * launchpad offers, and Home, has a topic in the migration that seeds them.
 * A tile added without a topic fails here before it ships with a help button
 * that says "there is no guidance for this screen yet".
 */

const ROOT = join(import.meta.dir, "..", "..");
const MIGRATIONS = join(ROOT, "supabase", "migrations");

const guidanceFiles = readdirSync(MIGRATIONS).filter(
  (f) =>
    f.endsWith(".sql") && readFileSync(join(MIGRATIONS, f), "utf8").includes("erp_ref.help_topic"),
);
const seeds = guidanceFiles.map((f) => readFileSync(join(MIGRATIONS, f), "utf8")).join("\n");

/** Screen paths seeded into erp_ref.help_topic, across every migration that writes it. */
function helpTopicPaths(): Set<string> {
  const out = new Set<string>();
  const insert =
    /insert into erp_ref\.help_topic\s*\([^)]*\)\s*values([\s\S]*?)(?:on conflict|;\s*$)/gm;
  for (const block of seeds.matchAll(insert)) {
    for (const row of block[1]!.matchAll(/\(\s*'(\/[^']*)'/g)) out.add(row[1]!);
  }
  return out;
}

/** Tile paths from the module registry, read as text so the test stays pure. */
function tilePaths(): string[] {
  const src = readFileSync(join(ROOT, "src", "lib", "modules.tsx"), "utf8");
  return [...src.matchAll(/^\s*path:\s*"(\/[^"]*)"/gm)].map((m) => m[1]!);
}

/** First-run steps' screen paths from the same seeds. */
function firstRunPaths(): string[] {
  const insert =
    /insert into erp_ref\.first_run_step\s*\([^)]*\)\s*values([\s\S]*?)(?:on conflict|;\s*$)/gm;
  const out: string[] = [];
  for (const block of seeds.matchAll(insert)) {
    for (const row of block[1]!.matchAll(/'(\/[^']*)'/g)) out.push(row[1]!);
  }
  return out;
}

describe("§22.1 contextual help: every screen the launchpad offers has a topic", () => {
  const topics = helpTopicPaths();

  test("the seed was found", () => {
    expect(topics.size).toBeGreaterThan(30);
  });

  test("Home has a topic", () => {
    expect(topics.has("/")).toBe(true);
  });

  test("the Settings area's home has a topic", () => {
    expect(topics.has("/settings")).toBe(true);
  });

  test("the profile screen, reached from the account menu, has a topic", () => {
    expect(topics.has("/profile")).toBe(true);
  });

  for (const path of tilePaths()) {
    test(`${path}`, () => {
      expect(topics.has(path)).toBe(true);
    });
  }
});

describe("§22.2 first-run guidance: every step lands on a screen that has help", () => {
  const topics = helpTopicPaths();
  const steps = firstRunPaths();

  test("steps were found", () => {
    expect(steps.length).toBeGreaterThan(20);
  });

  for (const path of new Set(steps)) {
    test(`${path}`, () => {
      expect(topics.has(path)).toBe(true);
    });
  }
});

describe("the help button is in the shell, and Home offers the first steps", () => {
  test("the shell renders ContextHelp", () => {
    const shell = readFileSync(join(ROOT, "src", "components", "erp", "shell.tsx"), "utf8");
    expect(shell).toContain("<ContextHelp />");
  });

  test("Home renders FirstRun", () => {
    const home = readFileSync(join(ROOT, "src", "routes", "index.tsx"), "utf8");
    expect(home).toContain("<FirstRun />");
  });
});
