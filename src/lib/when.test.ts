import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { whenText } from "./when";

const ROOT = join(import.meta.dir, "..", "..");

/** Every screen file under src/routes and src/components. */
function screenFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) walk(path);
      else if (/\.tsx?$/.test(entry.name) && !entry.name.includes(".test.")) out.push(path);
    }
  };
  walk(join(ROOT, "src", "routes"));
  walk(join(ROOT, "src", "components"));
  return out;
}

describe("a time reads on the reader's clock (J-127)", () => {
  test("a timestamp is shown in the reader's zone, not cut from the UTC text", () => {
    const iso = "2026-09-14T23:30:00+00:00";
    const local = new Date(iso);
    const hh = String(local.getHours()).padStart(2, "0");
    const mm = String(local.getMinutes()).padStart(2, "0");
    expect(whenText(iso)).toEndWith(`, ${hh}:${mm}`);
    expect(whenText(iso)).toContain(String(local.getFullYear()));
  });

  test("nothing reads as a dash, and text that is not a time is given back", () => {
    expect(whenText(null)).toBe("—");
    expect(whenText(undefined)).toBe("—");
    expect(whenText("")).toBe("—");
    expect(whenText("not a time")).toBe("not a time");
  });

  test("no screen cuts a timestamp's text to the minute", () => {
    const files = screenFiles();
    expect(files.length).toBeGreaterThan(50);
    const cut = /\.slice\(0, 16\)\s*\.replace\("T"/;
    const offenders = files.filter((f) => cut.test(readFileSync(f, "utf8")));
    expect(offenders).toEqual([]);
  });
});
