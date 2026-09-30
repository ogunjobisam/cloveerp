/**
 * The organisation's export, read a section at a time.
 *
 * `erp_export_tenant` built everything an organisation holds, every audit entry
 * with its before and after state, as one value in one statement. On 30
 * September four of those ran at once and the live database stopped. So the
 * file is now asked for a page at a time: `erp_export_tenant_manifest` says
 * what the file starts with and which sections follow, and
 * `erp_export_tenant_section` answers one page of one section. No request holds
 * more than a page, and the file is assembled here.
 *
 * The file is the same `erpware.tenant-export.v1` document: the header, then
 * one array per section, in the manifest's order. It is kept as a list of
 * string parts rather than one string, so the browser can hand the parts to a
 * Blob without building the whole file twice.
 *
 * Pages are read at slightly different moments, so an organisation that keeps
 * working during a long export gets a file that is not one instant's copy. The
 * screen says so.
 */

export const EXPORT_FORMAT = "erpware.tenant-export.v1";

export type ExportManifest = {
  exportedAt: string;
  format: string;
  tenant: unknown;
  sections: string[];
};

export type ExportPage = {
  section: string;
  rows: unknown[];
  next: string | null;
};

/** How the export reaches the database. The screen passes callErp; tests pass fakes. */
export type ExportSource = {
  manifest: () => Promise<unknown>;
  page: (section: string, after: string | null) => Promise<unknown>;
};

export type ExportProgress = {
  section: string;
  /** 1-based position of the section being read. */
  position: number;
  sections: number;
  /** Rows read so far, across every section. */
  rows: number;
};

/**
 * Where an export has got to. Kept by the caller, so that a failed page can be
 * asked for again without reading what was already read.
 */
export type ExportState = {
  manifest: ExportManifest | null;
  /** Index into manifest.sections of the section being read. */
  index: number;
  /** The cursor for the next page of that section, or null for its first page. */
  after: string | null;
  /** Whether that section's opening is already in parts. */
  sectionOpen: boolean;
  /** Rows of the section being read that are already in parts. */
  sectionRows: number;
  rows: number;
  parts: string[];
  done: boolean;
};

export function newExportState(): ExportState {
  return {
    manifest: null,
    index: 0,
    after: null,
    sectionOpen: false,
    sectionRows: 0,
    rows: 0,
    parts: [],
    done: false,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function readManifest(raw: unknown): ExportManifest {
  if (!isRecord(raw)) throw new Error("The export's manifest is not an object.");
  const exportedAt = raw["exported_at"];
  const format = raw["format"];
  const sections = raw["sections"];
  if (typeof exportedAt !== "string") throw new Error("The export's manifest has no exported_at.");
  if (format !== EXPORT_FORMAT) {
    throw new Error(`The export's manifest is in format ${String(format)}, not ${EXPORT_FORMAT}.`);
  }
  if (!Array.isArray(sections) || sections.length === 0) {
    throw new Error("The export's manifest names no sections.");
  }
  const names = sections.map((s) => {
    if (typeof s !== "string" || s === "")
      throw new Error("The export's manifest names a section that is not a name.");
    return s;
  });
  if (new Set(names).size !== names.length)
    throw new Error("The export's manifest names a section twice.");
  return { exportedAt, format, tenant: raw["tenant"] ?? null, sections: names };
}

export function readPage(raw: unknown, section: string): ExportPage {
  if (!isRecord(raw)) throw new Error(`The page of ${section} is not an object.`);
  const rows = raw["rows"];
  const next = raw["next"];
  if (raw["section"] !== section) {
    throw new Error(`Asked for ${section} and was answered with ${String(raw["section"])}.`);
  }
  if (!Array.isArray(rows)) throw new Error(`The page of ${section} has no rows.`);
  if (next !== null && typeof next !== "string") {
    throw new Error(`The page of ${section} gives a cursor that is not text.`);
  }
  return { section, rows, next };
}

/** The file's opening: `{`, the header's three keys, and nothing after them yet. */
function header(m: ExportManifest): string {
  return (
    "{\n" +
    `  "exported_at": ${JSON.stringify(m.exportedAt)},\n` +
    `  "format": ${JSON.stringify(m.format)},\n` +
    `  "tenant": ${JSON.stringify(m.tenant)}`
  );
}

/**
 * Carries on from wherever `state` stands until the file is complete, and
 * returns its parts. Throws on the first page that fails, leaving `state` at
 * that page, so calling this again with the same state asks for that page
 * again and nothing already read is read twice.
 *
 * A section that answers the same cursor twice would never end, so a cursor
 * that does not move is refused rather than followed.
 */
export async function runExport(
  source: ExportSource,
  state: ExportState,
  onProgress: (p: ExportProgress) => void = () => {},
): Promise<string[]> {
  if (state.done) return state.parts;

  if (!state.manifest) {
    const manifest = readManifest(await source.manifest());
    state.manifest = manifest;
    state.parts.push(header(manifest));
  }
  const manifest = state.manifest;

  while (state.index < manifest.sections.length) {
    const section = manifest.sections[state.index];
    if (section === undefined) break;
    if (!state.sectionOpen) {
      state.parts.push(`,\n  ${JSON.stringify(section)}: [`);
      state.sectionOpen = true;
    }
    onProgress({
      section,
      position: state.index + 1,
      sections: manifest.sections.length,
      rows: state.rows,
    });

    const page = readPage(await source.page(section, state.after), section);
    for (const row of page.rows) {
      state.parts.push((state.sectionRows === 0 ? "\n    " : ",\n    ") + JSON.stringify(row));
      state.sectionRows += 1;
      state.rows += 1;
    }

    if (page.next === null) {
      state.parts.push(state.sectionRows === 0 ? "]" : "\n  ]");
      state.index += 1;
      state.after = null;
      state.sectionOpen = false;
      state.sectionRows = 0;
    } else {
      if (page.next === state.after) {
        throw new Error(`The export of ${section} did not move past ${page.next}.`);
      }
      state.after = page.next;
    }
  }

  state.parts.push("\n}\n");
  state.done = true;
  onProgress({
    section: manifest.sections[manifest.sections.length - 1] ?? "",
    position: manifest.sections.length,
    sections: manifest.sections.length,
    rows: state.rows,
  });
  return state.parts;
}

/** A section's key, in words: `role_permissions` is "role permissions". */
export function sectionWords(section: string): string {
  return section === "audit" ? "audit trail" : section.replaceAll("_", " ");
}
