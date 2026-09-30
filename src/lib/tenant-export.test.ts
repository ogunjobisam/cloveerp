import { describe, expect, test } from "bun:test";

import {
  EXPORT_FORMAT,
  newExportState,
  readManifest,
  readPage,
  runExport,
  sectionWords,
  type ExportProgress,
  type ExportSource,
} from "./tenant-export";

const MANIFEST = {
  exported_at: "2026-09-30T10:00:00Z",
  format: EXPORT_FORMAT,
  tenant: { id: "t1", code: "acme" },
  sections: ["entities", "audit", "events"],
};

type Row = { id: string | number; n: number };

/** A database of three sections, answered `size` rows a page. */
function source(data: Record<string, Row[]>, size: number) {
  const asked: Array<[string, string | null]> = [];
  const failAt = new Set<string>();
  const src: ExportSource = {
    manifest: async () => MANIFEST,
    page: async (section, after) => {
      const key = `${section}:${after ?? ""}`;
      asked.push([section, after]);
      if (failAt.has(key)) {
        failAt.delete(key);
        throw new Error(`page ${key} failed`);
      }
      const rows = data[section] ?? [];
      const from = after === null ? 0 : rows.findIndex((r) => String(r.id) === after) + 1;
      const page = rows.slice(from, from + size);
      const last = page[page.length - 1];
      const more = from + size < rows.length;
      return { section, rows: page, next: more && last ? String(last.id) : null };
    },
  };
  return { src, asked, failAt };
}

const DATA: Record<string, Row[]> = {
  entities: [
    { id: "e1", n: 1 },
    { id: "e2", n: 2 },
  ],
  audit: Array.from({ length: 7 }, (_, i) => ({ id: i + 1, n: i })),
  events: [],
};

function parse(parts: string[]): Record<string, unknown> {
  return JSON.parse(parts.join("")) as Record<string, unknown>;
}

describe("the export read a section at a time", () => {
  test("gives the same document the single call gave: the header, then every section in order", async () => {
    const { src } = source(DATA, 3);
    const file = parse(await runExport(src, newExportState()));

    expect(Object.keys(file)).toEqual([
      "exported_at",
      "format",
      "tenant",
      "entities",
      "audit",
      "events",
    ]);
    expect(file["format"]).toBe(EXPORT_FORMAT);
    expect(file["tenant"]).toEqual({ id: "t1", code: "acme" });
    expect(file["entities"]).toEqual(DATA["entities"]);
    expect(file["audit"]).toEqual(DATA["audit"]);
    expect(file["events"]).toEqual([]);
  });

  test("asks for a section a page at a time until it has no next page", async () => {
    const { src, asked } = source(DATA, 3);
    await runExport(src, newExportState());

    expect(asked).toEqual([
      ["entities", null],
      ["audit", null],
      ["audit", "3"],
      ["audit", "6"],
      ["events", null],
    ]);
  });

  test("carries on from the page that failed, and reads nothing twice", async () => {
    const { src, asked, failAt } = source(DATA, 3);
    failAt.add("audit:3");
    const state = newExportState();

    await expect(runExport(src, state)).rejects.toThrow("page audit:3 failed");
    expect(state.done).toBe(false);
    expect(state.rows).toBe(5);

    const file = parse(await runExport(src, state));
    expect(file["audit"]).toEqual(DATA["audit"]);
    expect(file["entities"]).toEqual(DATA["entities"]);
    // audit:3 asked twice, once failing; every other page once.
    expect(asked.filter(([s, a]) => s === "audit" && a === "3")).toHaveLength(2);
    expect(asked.filter(([s, a]) => s === "entities" && a === null)).toHaveLength(1);
  });

  test("a section whose first page fails opens once in the file when it is asked for again", async () => {
    const { src, failAt } = source(DATA, 3);
    failAt.add("audit:");
    const state = newExportState();

    await expect(runExport(src, state)).rejects.toThrow();
    const file = parse(await runExport(src, state));
    expect(file["audit"]).toEqual(DATA["audit"]);
  });

  test("an empty section is an empty array, and a finished export is not read again", async () => {
    const { src, asked } = source({ entities: [], audit: [], events: [] }, 3);
    const state = newExportState();
    const parts = await runExport(src, state);
    expect(parse(parts)["audit"]).toEqual([]);

    const before = asked.length;
    expect(await runExport(src, state)).toBe(parts);
    expect(asked.length).toBe(before);
  });

  test("says where it is as it goes, ending on every row read", async () => {
    const { src } = source(DATA, 3);
    const seen: ExportProgress[] = [];
    await runExport(src, newExportState(), (p) => seen.push(p));

    expect(seen[0]).toEqual({ section: "entities", position: 1, sections: 3, rows: 0 });
    expect(seen.at(-1)).toEqual({ section: "events", position: 3, sections: 3, rows: 9 });
  });

  test("refuses a cursor that does not move, rather than asking for the same page forever", async () => {
    const stuck: ExportSource = {
      manifest: async () => ({ ...MANIFEST, sections: ["audit"] }),
      page: async (section, after) => ({ section, rows: [{ id: 1 }], next: after ?? "1" }),
    };
    await expect(runExport(stuck, newExportState())).rejects.toThrow("did not move past 1");
  });
});

describe("what the database answers is read, not trusted", () => {
  test("a manifest in another format, or with no sections, or naming one twice, is refused", () => {
    expect(() => readManifest({ ...MANIFEST, format: "other" })).toThrow(
      "not erpware.tenant-export.v1",
    );
    expect(() => readManifest({ ...MANIFEST, sections: [] })).toThrow("names no sections");
    expect(() => readManifest({ ...MANIFEST, sections: ["a", "a"] })).toThrow("twice");
    expect(() => readManifest(null)).toThrow("not an object");
  });

  test("a page for another section, or without rows, or with a cursor that is not text, is refused", () => {
    expect(() => readPage({ section: "audit", rows: [], next: null }, "events")).toThrow(
      "answered with audit",
    );
    expect(() => readPage({ section: "audit", next: null }, "audit")).toThrow("has no rows");
    expect(() => readPage({ section: "audit", rows: [], next: 7 }, "audit")).toThrow("not text");
  });

  test("a section's key reads as words", () => {
    expect(sectionWords("role_permissions")).toBe("role permissions");
    expect(sectionWords("audit")).toBe("audit trail");
  });
});
