import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * What supabase/ci/screen_strings.sh reads.
 *
 * The check holds every screen string to the row a tenant renames it by, and
 * it can only hold what it reads. It read ui("…") with a grep, a line at a
 * time, so a call prettier wraps — the string on the line below ui( — was
 * never read, and 41 strings on thirteen screens reached the screen with no
 * row (J-172). These run its harvest, which needs no database.
 */

const ROOT = join(import.meta.dir, "..", "..");
const SCRIPT = join(ROOT, "supabase", "ci", "screen_strings.sh");

function harvest(src: string): string[] {
  const run = Bun.spawnSync(["bash", SCRIPT, "--harvest", src], { cwd: ROOT });
  if (run.exitCode !== 0) throw new Error(run.stderr.toString());
  return run.stdout.toString().split("\n").filter(Boolean);
}

describe("the screen strings check reads a ui() call however it is laid out", () => {
  test("on one line, wrapped by prettier, and joined over lines", () => {
    const dir = mkdtempSync(join(tmpdir(), "screen-strings-"));
    try {
      writeFileSync(
        join(dir, "words.tsx"),
        [
          "export function Words({ ui, n }: { ui: (t: string) => string; n: number }) {",
          "  return (",
          "    <p>",
          '      {ui("Said on one line.")}',
          "      {ui(",
          '        "Said on the line below the call, as prettier wraps a long one.",',
          "      )}",
          "      {ui(",
          '        "Said in two pieces " +',
          "          'joined over lines, with the supplier\\'s \"own\" words.',",
          "      )}",
          "      {ui(`A template ${n} is not a string anybody can rename.`)}",
          "    </p>",
          "  );",
          "}",
          "",
        ].join("\n"),
      );
      const read = harvest(dir);
      expect(read).toContain("Said on one line.");
      expect(read).toContain("Said on the line below the call, as prettier wraps a long one.");
      expect(read).toContain(
        'Said in two pieces joined over lines, with the supplier\'s \\"own\\" words.',
      );
      expect(read.some((s) => s.includes("template"))).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("every wrapped ui() literal in the app is read", () => {
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) walk(path);
        else if (/\.tsx?$/.test(name) && !/\.test\.tsx?$/.test(name)) files.push(path);
      }
    };
    walk(join(ROOT, "src"));
    const wrapped = files.flatMap((f) =>
      [...readFileSync(f, "utf8").matchAll(/\bui\(\s*\n\s*"((?:[^"\\\n]|\\.)*)",?\s*\)/g)].map(
        (m) => m[1]!,
      ),
    );
    expect(wrapped.length).toBeGreaterThan(0);
    const read = new Set(harvest(join(ROOT, "src")));
    expect(wrapped.filter((t) => !read.has(t))).toEqual([]);
  });
});
