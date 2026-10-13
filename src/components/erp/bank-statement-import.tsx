import { useQuery } from "@tanstack/react-query";
import { useId, useMemo, useState } from "react";

import {
  detectLayout,
  doorLines,
  fileSha256,
  findHeadingRow,
  isOfx,
  MAPPABLE,
  mapIsComplete,
  readCsvStatement,
  readOfxStatement,
  type ColumnMap,
  type ParsedStatement,
} from "../../lib/bank-statement";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { parseCsv } from "../../lib/import/csv";
import { parseMinor } from "../../lib/import/values";
import { formatMinor } from "../../lib/money";
import { ActionButton, ErrorNote, useErpAction } from "./action";
import { Table } from "./panel";
import { useErpSession } from "./session-context";

type OpenAccount = {
  bank_account_id: string;
  name: string;
  entity: string;
  account_code: string;
  currency: string;
};

const EMPTY_MAP: ColumnMap = {
  date: null,
  description: null,
  amount: null,
  paidIn: null,
  paidOut: null,
  balance: null,
  reference: null,
};

/** The saved-mapping keys the import_mapping door takes: snake case. */
const SAVED_KEY: Record<keyof Omit<ColumnMap, "amountOutIsPositive">, string> = {
  date: "date",
  description: "description",
  amount: "amount",
  paidIn: "paid_in",
  paidOut: "paid_out",
  balance: "balance",
  reference: "reference",
};

function profileFor(bankAccountId: string): string {
  return `bank-${bankAccountId}`;
}

/**
 * Import a bank statement (bank reconciliation, pull request 2).
 *
 * The file is read here, in the browser: a known bank's CSV by its headings,
 * OFX by its tags, any other CSV through a mapping the person makes. What
 * leaves is the lines, the balances and the file's SHA-256, and the database
 * checks all of it again (public.erp_import_bank_statement): a file or a line
 * imported before, and balances that do not run on or add up, are refused
 * there by name. A mapping is remembered for the bank account where the
 * person may save import mappings; otherwise it is asked again next time.
 */
export function BankStatementImport({ accounts }: { accounts: OpenAccount[] }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const ids = { account: useId(), file: useId(), opening: useId(), closing: useId() };
  const mayRemember = hasPermission(session, "master_data.import");

  const [accountId, setAccountId] = useState(accounts[0]?.bank_account_id ?? "");
  const [text, setText] = useState<string | null>(null);
  const [fileName, setFileName] = useState("");
  const [headings, setHeadings] = useState<string[] | null>(null);
  const [map, setMap] = useState<ColumnMap>(EMPTY_MAP);
  const [parsed, setParsed] = useState<ParsedStatement | null>(null);
  const [opening, setOpening] = useState("");
  const [closing, setClosing] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  const account = accounts.find((a) => a.bank_account_id === accountId) ?? null;
  const currency = account?.currency ?? "GBP";

  const saved = useQuery({
    queryKey: ["erp_import_mappings"],
    queryFn: () => callErp<Record<string, Record<string, string>>>("erp_import_mappings", {}),
    enabled: mayRemember,
  });

  const imp = useErpAction({
    fn: "erp_import_bank_statement",
    invalidates: ["erp_bank_statements"],
    outcome: (result) => {
      const r = result as { lines?: number; starts_on?: string; ends_on?: string } | null;
      return r?.lines
        ? `${r.lines} ${r.lines === 1 ? "line" : "lines"} imported, ${r.starts_on} to ${r.ends_on}.`
        : null;
    },
    onDone: () => reset(),
  });

  function reset() {
    setText(null);
    setFileName("");
    setHeadings(null);
    setMap(EMPTY_MAP);
    setParsed(null);
    setOpening("");
    setClosing("");
    setProblem(null);
  }

  function shown(statement: ParsedStatement) {
    setParsed(statement);
    setOpening(statement.openingMinor === null ? "" : (statement.openingMinor / 100).toFixed(2));
    setClosing(statement.closingMinor === null ? "" : (statement.closingMinor / 100).toFixed(2));
  }

  async function onFile(file: File | undefined) {
    reset();
    if (!file) return;
    const body = await file.text();
    setText(body);
    setFileName(file.name);
    if (isOfx(body)) {
      shown(readOfxStatement(body));
      return;
    }
    const records = parseCsv(body).records;
    const at = findHeadingRow(records);
    const row = records[at]?.fields ?? [];
    const found = detectLayout(row);
    if (found) {
      shown(readCsvStatement(body, found.map, found.layout));
      return;
    }
    // A layout nobody declared: the person maps it, starting from the mapping
    // remembered for this bank account.
    setHeadings(row);
    const remembered = saved.data?.[profileFor(accountId)];
    if (remembered) {
      const next: ColumnMap = { ...EMPTY_MAP };
      for (const [k, key] of Object.entries(SAVED_KEY) as [keyof typeof SAVED_KEY, string][]) {
        const heading = remembered[key];
        const i = heading === undefined ? -1 : row.indexOf(heading);
        next[k] = i >= 0 ? i : null;
      }
      setMap(next);
    }
  }

  function readMapped() {
    if (!text || !mapIsComplete(map)) return;
    shown(readCsvStatement(text, map, { id: "mapped", label: ui("Mapped by hand") }));
    if (mayRemember && headings) {
      const toSave: Record<string, string> = {};
      for (const [k, key] of Object.entries(SAVED_KEY) as [keyof typeof SAVED_KEY, string][]) {
        const i = map[k];
        if (typeof i === "number" && headings[i] !== undefined) toSave[key] = headings[i] ?? "";
      }
      void callErp("erp_save_import_mapping", {
        p_profile_id: profileFor(accountId),
        p_mapping: toSave,
      }).catch(() => undefined);
    }
  }

  const totals = useMemo(() => {
    const lines = parsed?.lines ?? [];
    return {
      in: lines.filter((l) => l.amountMinor > 0).reduce((s, l) => s + l.amountMinor, 0),
      out: lines.filter((l) => l.amountMinor < 0).reduce((s, l) => s + l.amountMinor, 0),
    };
  }, [parsed]);

  async function onImport() {
    if (!parsed || !text || !account) return;
    const close = parseMinor(closing);
    if (!close.ok) {
      setProblem(ui("Give the closing balance the bank prints on this statement."));
      return;
    }
    const open = opening.trim() === "" ? null : parseMinor(opening);
    if (open && !open.ok) {
      setProblem(ui("The opening balance is not an amount."));
      return;
    }
    setProblem(null);
    imp.mutate({
      p_bank_account_id: account.bank_account_id,
      p_format: parsed.format,
      p_source: parsed.source,
      p_file_sha256: await fileSha256(text),
      p_closing_minor: close.minor,
      p_lines: doorLines(parsed.lines),
      p_opening_minor: open && open.ok ? open.minor : null,
      p_starts_on: parsed.startsOn,
      p_ends_on: parsed.endsOn,
    });
  }

  if (!hasPermission(session, "finance.post")) return null;
  if (accounts.length === 0) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
      <h2 className="mb-1 text-sm font-semibold">{ui("Import a statement")}</h2>
      <p className="mb-3 text-xs text-muted-foreground">
        {ui(
          "A CSV from Barclays, Lloyds, NatWest, HSBC, Starling, Monzo or Tide is read as it comes; any other CSV is mapped once. OFX is read from any bank.",
        )}
      </p>

      <div className="flex flex-wrap items-end gap-3">
        <label className="flex min-w-0 flex-col gap-1 text-sm" htmlFor={ids.account}>
          <span className="text-xs text-muted-foreground">{ui("Bank account")}</span>
          <select
            id={ids.account}
            className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
            value={accountId}
            onChange={(e) => {
              setAccountId(e.target.value);
              reset();
            }}
          >
            {accounts.map((a) => (
              <option key={a.bank_account_id} value={a.bank_account_id}>
                {a.entity} · {a.account_code} · {a.name}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm" htmlFor={ids.file}>
          <span className="text-xs text-muted-foreground">{ui("Statement file")}</span>
          <input
            id={ids.file}
            type="file"
            accept=".csv,.ofx,.qbo,.txt"
            className="text-sm"
            onChange={(e) => void onFile(e.target.files?.[0])}
          />
        </label>
      </div>

      {headings && !parsed ? (
        <div className="mt-4 flex min-w-0 flex-col gap-3">
          <p className="text-sm">
            {ui("This file's layout is not one Clove knows. Say which column holds what.")}
          </p>
          <div className="grid min-w-0 gap-3 sm:grid-cols-2">
            {MAPPABLE.map((m) => (
              <label key={m.key} className="flex min-w-0 flex-col gap-1 text-sm">
                <span className="text-xs text-muted-foreground">{ui(m.label)}</span>
                <select
                  className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
                  value={map[m.key] === null || map[m.key] === undefined ? "" : String(map[m.key])}
                  onChange={(e) =>
                    setMap({
                      ...map,
                      [m.key]: e.target.value === "" ? null : Number(e.target.value),
                    })
                  }
                >
                  <option value="">{ui("Not in this file")}</option>
                  {headings.map((h, i) => (
                    <option key={`${h}-${i}`} value={i}>
                      {h || `(${i + 1})`}
                    </option>
                  ))}
                </select>
              </label>
            ))}
          </div>
          <div>
            <ActionButton variant="secondary" disabled={!mapIsComplete(map)} onClick={readMapped}>
              {ui("Read the file with this mapping")}
            </ActionButton>
          </div>
        </div>
      ) : null}

      {parsed ? (
        <div className="mt-4 flex min-w-0 flex-col gap-3">
          <p className="text-sm">
            <span className="font-medium">{fileName}</span> · {parsed.sourceLabel} ·{" "}
            {parsed.lines.length} {ui("lines")} · {parsed.startsOn} – {parsed.endsOn}
          </p>
          <p className="text-xs text-muted-foreground">
            {ui("In")} {formatMinor(totals.in, currency)} · {ui("Out")}{" "}
            {formatMinor(-totals.out, currency)}
            {parsed.accountLast4 ? ` · ${ui("Account ending")} ${parsed.accountLast4}` : ""}
          </p>
          {parsed.findings.length > 0 ? (
            <ul className="list-disc pl-5 text-xs text-amber-700 dark:text-amber-400">
              {parsed.findings.slice(0, 8).map((f, i) => (
                <li key={i}>
                  {f.line === null ? "" : `${ui("Line")} ${f.line}: `}
                  {f.message}
                </li>
              ))}
            </ul>
          ) : null}
          <div className="flex flex-wrap items-end gap-3">
            <label className="flex flex-col gap-1 text-sm" htmlFor={ids.opening}>
              <span className="text-xs text-muted-foreground">{ui("Opening balance")}</span>
              <input
                id={ids.opening}
                className="w-40 rounded-md border border-input bg-background px-2 py-1.5 text-sm tabular-nums"
                value={opening}
                placeholder={ui("From the last statement")}
                onChange={(e) => setOpening(e.target.value)}
              />
            </label>
            <label className="flex flex-col gap-1 text-sm" htmlFor={ids.closing}>
              <span className="text-xs text-muted-foreground">{ui("Closing balance")}</span>
              <input
                id={ids.closing}
                className="w-40 rounded-md border border-input bg-background px-2 py-1.5 text-sm tabular-nums"
                value={closing}
                onChange={(e) => setClosing(e.target.value)}
              />
            </label>
            <ActionButton
              disabled={imp.isPending || parsed.lines.length === 0}
              onClick={() => void onImport()}
            >
              {imp.isPending ? ui("Importing…") : ui("Import the statement")}
            </ActionButton>
            <ActionButton variant="secondary" onClick={reset}>
              {ui("Start again")}
            </ActionButton>
          </div>
          {problem ? <p className="text-sm text-red-700 dark:text-red-400">{problem}</p> : null}
          <ErrorNote error={imp.error} />
          <Table columns={[ui("Date"), ui("Description"), ui("Reference"), ui("Amount")]}>
            {parsed.lines.slice(0, 12).map((l) => (
              <tr key={`${l.line}-${l.bookedOn}`} className="border-b border-border/60">
                <td className="py-1.5 pr-4 tabular-nums">{l.bookedOn}</td>
                <td className="py-1.5 pr-4">{l.description}</td>
                <td className="py-1.5 pr-4">{l.reference ?? ""}</td>
                <td className="py-1.5 pr-4 text-right tabular-nums">
                  {formatMinor(l.amountMinor, currency)}
                </td>
              </tr>
            ))}
          </Table>
          {parsed.lines.length > 12 ? (
            <p className="text-xs text-muted-foreground">
              {ui("and")} {parsed.lines.length - 12} {ui("more")}
            </p>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
