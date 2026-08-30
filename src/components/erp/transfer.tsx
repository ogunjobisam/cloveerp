import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ErrorNote, PermissionNote } from "./action";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * Configuration in and out, as a file.
 *
 * The point of a spreadsheet round trip is that the file you download is the
 * file you can upload: the same columns, in the same order, so an export is
 * also a template. An upload is checked first and applied second, and the
 * check is the same code path as the apply with the writing turned off —
 * because a preview that runs different code is a preview of something else.
 */

type Row = Record<string, unknown>;

type Outcome = {
  row_no: number;
  code: string;
  status: string;
  message: string | null;
};

type ImportResult = {
  object_type: string;
  dry_run: boolean;
  rows: number;
  accepted: number;
  rejected: number;
  results: Outcome[];
};

/** RFC 4180 enough: quotes doubled, fields with comma/quote/newline quoted. */
function toCsv(columns: string[], rows: Row[]): string {
  const cell = (v: unknown) => {
    const s = v === null || v === undefined ? "" : String(v);
    return /[",\n\r]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
  };
  return [columns.join(","), ...rows.map((r) => columns.map((c) => cell(r[c])).join(","))].join(
    "\r\n",
  );
}

/** The same grammar read back, including quoted fields that contain newlines. */
export function parseCsv(text: string): Row[] {
  const cells: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;

  const endField = () => {
    row.push(field);
    field = "";
  };
  const endRow = () => {
    endField();
    if (row.some((c) => c.trim() !== "")) cells.push(row);
    row = [];
  };

  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else quoted = false;
      } else field += ch;
      continue;
    }
    if (ch === '"') quoted = true;
    else if (ch === ",") endField();
    else if (ch === "\n") endRow();
    else if (ch === "\r") continue;
    else field += ch;
  }
  endRow();

  if (cells.length === 0) return [];
  const header = (cells[0] ?? []).map((h) => h.trim());
  return cells.slice(1).map((line) => {
    const out: Row = {};
    header.forEach((h, i) => {
      if (h) out[h] = (line[i] ?? "").trim();
    });
    return out;
  });
}

function download(name: string, body: string) {
  const url = URL.createObjectURL(new Blob([body], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

export function ConfigTransfer({
  objectType,
  title,
  description,
  invalidates = [],
}: {
  objectType: string;
  title: string;
  description?: string;
  invalidates?: string[];
}) {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const fileRef = useRef<HTMLInputElement>(null);

  const [rows, setRows] = useState<Row[]>([]);
  const [fileName, setFileName] = useState<string | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);

  const columnsOf = async () => {
    const defs = await callErp<{ object_type: string; columns: string[] }[]>(
      "erp_configuration_columns",
      { p_object_type: objectType },
    );
    return defs[0]?.columns ?? [];
  };

  const exportMutation = useMutation({
    mutationFn: async () => {
      const [columns, data] = await Promise.all([
        columnsOf(),
        callErp<Row[]>("erp_export_configuration", { p_object_type: objectType }),
      ]);
      download(`${objectType}.csv`, toCsv(columns, data));
      return data.length;
    },
  });

  const templateMutation = useMutation({
    mutationFn: async () => {
      const columns = await columnsOf();
      download(`${objectType}-template.csv`, toCsv(columns, []));
      return columns.length;
    },
  });

  const runMutation = useMutation({
    mutationFn: (dryRun: boolean) =>
      callErp<ImportResult>("erp_import_configuration", {
        p_object_type: objectType,
        p_rows: rows,
        p_dry_run: dryRun,
      }),
    onSuccess: (r) => {
      setResult(r);
      if (!r.dry_run) {
        invalidates.forEach((fn) => queryClient.invalidateQueries({ queryKey: [fn] }));
      }
    },
  });

  if (!hasPermission(session, "master_data.import")) {
    return <PermissionNote code="master_data.import" />;
  }

  const onFile = async (file: File) => {
    setFileName(file.name);
    setResult(null);
    setRows(parseCsv(await file.text()));
  };

  return (
    <section className="rounded-xl border border-border bg-card p-4 sm:p-5">
      <h3 className="text-sm font-semibold">{title}</h3>
      {description ? <p className="mt-1 text-xs text-muted-foreground">{description}</p> : null}

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <ActionButton
          variant="secondary"
          busy={exportMutation.isPending}
          onClick={() => exportMutation.mutate()}
        >
          {ui("Download current")}
        </ActionButton>
        <ActionButton
          variant="secondary"
          busy={templateMutation.isPending}
          onClick={() => templateMutation.mutate()}
        >
          {ui("Download empty template")}
        </ActionButton>
        <ActionButton variant="secondary" onClick={() => fileRef.current?.click()}>
          {ui("Choose a CSV file")}
        </ActionButton>
        <input
          ref={fileRef}
          type="file"
          accept=".csv,text/csv"
          className="sr-only"
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void onFile(f);
            e.target.value = "";
          }}
        />
      </div>

      {fileName ? (
        <p className="mt-3 text-xs text-muted-foreground">
          {fileName} — {rows.length} {ui("row(s) read")}
        </p>
      ) : null}

      {rows.length > 0 ? (
        <div className="mt-3 flex flex-wrap gap-2">
          <ActionButton busy={runMutation.isPending} onClick={() => runMutation.mutate(true)}>
            {ui("Check without loading")}
          </ActionButton>
          <ActionButton
            variant="secondary"
            busy={runMutation.isPending}
            disabled={!result || result.rejected > 0}
            title={
              !result
                ? "Check the file first."
                : result.rejected > 0
                  ? "Some rows were rejected. Fix the file rather than loading the good half."
                  : undefined
            }
            onClick={() => runMutation.mutate(false)}
          >
            {ui("Load")}
          </ActionButton>
        </div>
      ) : null}

      <div className="mt-3 space-y-3">
        <ErrorNote error={exportMutation.error} />
        <ErrorNote error={templateMutation.error} />
        <ErrorNote error={runMutation.error} />
      </div>

      {result ? (
        <div className="mt-4">
          <p className="text-xs text-muted-foreground">
            {result.dry_run ? ui("Checked") : ui("Loaded")} — {result.accepted} {ui("accepted")},{" "}
            {result.rejected} {ui("rejected")}
          </p>
          <div className="mt-2">
            <Table columns={[ui("Row"), ui("Record"), ui("Outcome"), ui("Why")]}>
              {result.results.map((o) => (
                <tr key={o.row_no} className="border-b border-border/60 last:border-0">
                  <td className="py-2 pr-4 tabular-nums">{o.row_no}</td>
                  <td className="py-2 pr-4 font-mono text-xs">{o.code}</td>
                  <td className="py-2 pr-4">
                    <Pill tone={o.status === "rejected" ? "warn" : "ok"}>{o.status}</Pill>
                  </td>
                  <td className="py-2 pr-4 text-xs text-muted-foreground">{o.message ?? "—"}</td>
                </tr>
              ))}
            </Table>
          </div>
        </div>
      ) : null}
    </section>
  );
}
