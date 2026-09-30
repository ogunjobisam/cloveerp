import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState, type ReactNode } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { accountResolver, partyKeysFrom, type CrosswalkEntry } from "../../lib/import/crosswalk";
import { toSaved, type Mapping, type SavedMapping } from "../../lib/import/headers";
import { controlFigure, controlQuantity, partyResolver, readFile } from "../../lib/import/pipeline";
import type {
  ChartAccount,
  ChartAction,
  ChartChoice,
  Finding,
  Profile,
} from "../../lib/import/types";
import { parseMinor } from "../../lib/import/values";
import { formatMinor } from "../../lib/money";
import { ActionButton, ErrorNote } from "./action";
import { TOUCH } from "./page";
import { Pill, Table } from "./panel";
import { useErpSession } from "./session-context";

/**
 * A legacy export, read in the browser into the rows an existing door accepts.
 *
 * Nothing here writes anything but a staged batch: validate, preview, load and
 * roll back stay where they were, on the batch. The file is parsed against a
 * profile, its headings matched to the profile's columns (a person can change
 * any match, and the confirmed choice is kept for the organisation), and every
 * line the batch will not carry is listed with the reason.
 *
 * Legacy keys resolve through the crosswalk: a contacts file stages its names
 * beside its party batch, the chart loads its own, and the ledgers and trial
 * balance read both — from loaded batches only, so a rolled-back import leaves
 * nothing behind.
 *
 * For an opening balance the control total is typed from the printed report —
 * never taken from the file — and the lines held back are listed beside it:
 * printed less held back is the figure the batch is staged with, which is the
 * figure D31 compares the load against.
 */

const INPUT = `${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`;

const TONE = { error: "bad", warning: "warn", info: "muted" } as const;

const NO_ENTRIES: CrosswalkEntry[] = [];
const NO_ACCOUNTS: ChartAccount[] = [];

export function FileImport({
  profiles,
  currency,
}: {
  profiles: readonly Profile[];
  currency: string;
}) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [profileId, setProfileId] = useState(profiles[0]?.id ?? "");
  const [file, setFile] = useState<{ name: string; text: string } | null>(null);
  const [mapping, setMapping] = useState<Mapping | null>(null);
  const [chartChoices, setChartChoices] = useState<Record<string, ChartChoice>>({});
  const [defaultLocation, setDefaultLocation] = useState("");
  const [asAt, setAsAt] = useState("");
  const [printed, setPrinted] = useState("");
  const [printedQty, setPrintedQty] = useState("");
  const [staged, setStaged] = useState<string | null>(null);

  const profile = profiles.find((p) => p.id === profileId) ?? profiles[0];
  const opening = profile?.target.kind === "opening";
  const chart = profile?.target.kind === "master" && profile.target.objectType === "account";
  const readsAccounts = chart || profile?.id === "xero-trial-balance";

  const mappings = useQuery({
    queryKey: ["erp_import_mappings", {}],
    queryFn: () => callErp<Record<string, SavedMapping>>("erp_import_mappings"),
  });
  const partyEntries = useQuery({
    queryKey: ["erp_import_crosswalk", { p_source_system: "xero", p_object_type: "party" }],
    queryFn: () =>
      callErp<CrosswalkEntry[]>("erp_import_crosswalk", {
        p_source_system: "xero",
        p_object_type: "party",
      }),
    enabled: profile?.target.kind === "opening",
  });
  const accountEntries = useQuery({
    queryKey: ["erp_import_crosswalk", { p_source_system: "xero", p_object_type: "account" }],
    queryFn: () =>
      callErp<CrosswalkEntry[]>("erp_import_crosswalk", {
        p_source_system: "xero",
        p_object_type: "account",
      }),
    enabled: readsAccounts,
  });
  const accounts = useQuery({
    queryKey: ["erp_accounts", { p_postable_only: false }],
    queryFn: () => callErp<ChartAccount[]>("erp_accounts", { p_postable_only: false }),
    enabled: chart,
  });

  const saved = profile ? (mappings.data?.[profile.id] ?? null) : null;
  const parties = partyEntries.data ?? NO_ENTRIES;
  const accountMap = accountEntries.data ?? NO_ENTRIES;
  const chartAccounts = accounts.data ?? NO_ACCOUNTS;

  const read = useMemo(() => {
    if (!profile || !file) return null;
    return readFile(
      file.text,
      profile,
      {
        partyCode: partyResolver(partyKeysFrom(parties)),
        account: accountResolver(accountMap),
        chartLoaded: accountMap.length > 0,
        defaultLocation,
        accounts: chartAccounts,
        chartChoices,
      },
      { mapping, saved },
    );
  }, [
    profile,
    file,
    parties,
    accountMap,
    chartAccounts,
    chartChoices,
    defaultLocation,
    mapping,
    saved,
  ]);

  const action = useMutation({
    // The batch is the write that matters. Once it is staged, what follows is
    // bookkeeping beside it: a failure there is reported with the batch, never
    // left looking like a failed stage that invites a second, duplicate batch.
    mutationFn: async (args: Record<string, unknown>): Promise<string | null> => {
      if (!profile || !read) return null;
      const fn =
        profile.target.kind === "opening" ? "erp_stage_opening_balances" : "erp_stage_import";
      const batch = await callErp<string>(fn, args);
      const problems: string[] = [];
      const entries = Object.entries(read.result?.partyKeys ?? {}).map(
        ([legacy_key, clove_code]) => ({ legacy_key, clove_code }),
      );
      if (
        profile.target.kind === "master" &&
        profile.target.objectType === "party" &&
        entries.length > 0
      ) {
        try {
          await callErp("erp_stage_import_crosswalk", {
            p_batch_id: batch,
            p_source_system: "xero",
            p_object_type: "party",
            p_entries: entries,
          });
        } catch (e) {
          problems.push(
            `its contact names were not recorded (${e instanceof Error ? e.message : String(e)}), so the ledgers will not find them: roll the batch back and stage the file again`,
          );
        }
      }
      try {
        await callErp("erp_save_import_mapping", {
          p_profile_id: profile.id,
          p_mapping: toSaved(read.mapping, read.headings),
        });
      } catch {
        problems.push("the column headings were not remembered for next time");
      }
      return problems.length > 0 ? problems.join("; ") : null;
    },
    onSettled: () => {
      for (const key of [
        "erp_opening_batches",
        "erp_migration_domains",
        "erp_import_batches",
        "erp_import_mappings",
      ]) {
        void queryClient.invalidateQueries({ queryKey: [key] });
      }
    },
    onSuccess: (problem) => {
      setStaged(
        `${file?.name ?? "The file"} is staged. Validate, preview and load it from the batch below.` +
          (problem ? ` But ${problem}.` : ""),
      );
      setFile(null);
      setMapping(null);
      setChartChoices({});
    },
  });

  if (!profile) return null;

  const choose = (id: string) => {
    setProfileId(id);
    setFile(null);
    setMapping(null);
    setChartChoices({});
    setStaged(null);
  };

  const load = async (f: File | undefined) => {
    if (!f) return;
    const text = await f.text();
    setMapping(null);
    setChartChoices({});
    setStaged(null);
    setFile({ name: f.name, text });
  };

  const remap = (key: string, at: string) => {
    if (!read) return;
    setMapping({ ...read.mapping, [key]: at === "" ? null : Number(at) });
  };

  const chooseAccount = (key: string, choice: ChartChoice) =>
    setChartChoices((prev) => ({ ...prev, [key]: choice }));

  const result = read?.result ?? null;
  const findings: Finding[] = [...(read?.findings ?? []), ...(result?.findings ?? [])];
  const errors = findings.filter((f) => f.severity === "error").length;
  const printedMinor = parseMinor(printed);
  const control =
    result && printedMinor.ok ? controlFigure(printedMinor.minor, result.exclusions) : null;
  const controlQty =
    result &&
    profile.target.kind === "opening" &&
    profile.target.domain === "stock" &&
    printedQty.trim() !== ""
      ? controlQuantity(printedQty, result.exclusions)
      : null;
  const allowed = hasPermission(session, "master_data.import");

  const blockers: string[] = [];
  if (!result || result.rows.length === 0) blockers.push("There are no rows to stage.");
  if (opening && errors > 0)
    blockers.push("Opening balances are staged whole: fix the refused lines in the file first.");
  if (chart && errors > 0)
    blockers.push("A chart is staged whole: choose an account for every refused line first.");
  if (opening && asAt === "") blockers.push("Give the as-at date.");
  if (opening && control === null) blockers.push("Type the printed total from the report.");

  const stage = () => {
    if (!result) return;
    if (profile.target.kind === "master") {
      action.mutate({
        p_object_type: profile.target.objectType,
        p_rows: result.rows,
        p_code: null,
        p_source: `${profile.id}:${file?.name ?? ""}`,
      });
    } else {
      action.mutate({
        p_domain_code: profile.target.domain,
        p_as_at: asAt,
        p_rows: result.rows,
        p_control_total_minor: control,
        p_control_quantity: controlQty === null ? null : Number(controlQty),
        p_code: null,
      });
    }
  };

  const money = (minor: number) => formatMinor(minor, currency);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Import a file</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Choose what the file is, upload the CSV, check the columns, then stage it. Nothing is
          written until the batch is validated and loaded below.
        </p>
      </header>

      <div className="flex flex-col gap-5 px-4 py-4 sm:px-5">
        <div className="grid gap-4 sm:grid-cols-2">
          <Label text="What the file is">
            <select
              aria-label="What the file is"
              className={INPUT}
              value={profile.id}
              onChange={(e) => choose(e.target.value)}
            >
              {profiles.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.source}: {p.title}
                </option>
              ))}
            </select>
            <span className="text-xs text-muted-foreground">{profile.hint}</span>
          </Label>
          <Label text="CSV file">
            <input
              aria-label="CSV file"
              key={profile.id}
              type="file"
              accept=".csv,text/csv"
              className={`${INPUT} py-2`}
              onChange={(e) => void load(e.target.files?.[0])}
            />
            <span className="text-xs text-muted-foreground">
              An Excel report is saved as CSV first.
            </span>
          </Label>
        </div>

        {staged ? (
          <p role="status" className="text-sm">
            {staged}
          </p>
        ) : null}

        {read ? (
          <>
            <Block title="Columns">
              <div className="grid gap-2 sm:grid-cols-2">
                {profile.columns.map((c) => (
                  <Label key={c.key} text={`${c.label}${c.required ? " *" : ""}`}>
                    <select
                      aria-label={`Heading for ${c.label}`}
                      className={INPUT}
                      value={read.mapping[c.key] ?? ""}
                      onChange={(e) => remap(c.key, e.target.value)}
                    >
                      <option value="">— not in this file —</option>
                      {read.headings.map((h, i) => (
                        <option key={`${h}-${i}`} value={i}>
                          {h || `(column ${i + 1})`}
                        </option>
                      ))}
                    </select>
                  </Label>
                ))}
              </div>
              {read.missing.length > 0 ? (
                <p className="text-sm text-destructive">
                  Choose a heading for {read.missing.map((c) => c.label).join(", ")}.
                </p>
              ) : null}
              {read.unused.length > 0 ? (
                <p className="text-xs text-muted-foreground">Not read: {read.unused.join(", ")}.</p>
              ) : null}
            </Block>

            {chart && result && result.chart.length > 0 ? (
              <Block title="Map each Xero account">
                <p className="text-xs text-muted-foreground">
                  Map to an account that exists, mark one of the three control accounts, or create a
                  new account. An existing account is never changed.
                </p>
                <Table columns={["Xero account", "Action", "Clove account"]}>
                  {result.chart.map((l) => (
                    <tr key={l.key} className="border-b border-border/60">
                      <td className="py-1 pr-4">
                        {l.key === l.name ? l.name : `${l.key} ${l.name}`}
                        <span className="block text-xs text-muted-foreground">{l.type}</span>
                      </td>
                      <td className="py-1 pr-4">
                        <select
                          aria-label={`Action for ${l.name}`}
                          className={INPUT}
                          value={l.choice.action}
                          onChange={(e) =>
                            chooseAccount(l.key, {
                              action: e.target.value as ChartAction,
                              code: e.target.value === "create" ? l.key : "",
                            })
                          }
                        >
                          <option value="map">Map</option>
                          <option value="control">Control account</option>
                          <option value="create">Create</option>
                        </select>
                      </td>
                      <td className="py-1">
                        {l.choice.action === "create" ? (
                          <input
                            aria-label={`New code for ${l.name}`}
                            className={INPUT}
                            value={l.choice.code}
                            onChange={(e) =>
                              chooseAccount(l.key, { action: "create", code: e.target.value })
                            }
                          />
                        ) : (
                          <select
                            aria-label={`Clove account for ${l.name}`}
                            className={INPUT}
                            value={l.choice.code}
                            onChange={(e) =>
                              chooseAccount(l.key, {
                                action: l.choice.action,
                                code: e.target.value,
                              })
                            }
                          >
                            <option value="">— choose —</option>
                            {chartAccounts
                              .filter((a) =>
                                l.choice.action === "control"
                                  ? a.control_kind !== null &&
                                    ["receivable", "payable", "inventory"].includes(a.control_kind)
                                  : a.is_postable &&
                                    !["receivable", "payable", "inventory"].includes(
                                      a.control_kind ?? "",
                                    ),
                              )
                              .map((a) => (
                                <option key={a.code} value={a.code}>
                                  {a.code} {a.name}
                                </option>
                              ))}
                          </select>
                        )}
                      </td>
                    </tr>
                  ))}
                </Table>
              </Block>
            ) : null}

            {profile.id === "unleashed-stock" ? (
              <Label text="Location for lines with no bin">
                <input
                  aria-label="Location for lines with no bin"
                  className={INPUT}
                  value={defaultLocation}
                  placeholder="MAIN-01"
                  onChange={(e) => setDefaultLocation(e.target.value)}
                />
              </Label>
            ) : null}

            {result ? (
              <>
                <p className="text-sm">
                  {result.rows.length} row{result.rows.length === 1 ? "" : "s"} to stage
                  {result.exclusions.length > 0 ? `, ${result.exclusions.length} held back` : ""}
                  {errors > 0 ? `, ${errors} refused` : ""}.
                </p>

                {findings.length > 0 ? (
                  <Block title="What to look at">
                    <ul className="flex max-h-72 flex-col gap-1 overflow-y-auto text-sm">
                      {findings.slice(0, 300).map((f, i) => (
                        <li key={i} className="flex gap-2">
                          <Pill tone={TONE[f.severity]}>{f.severity}</Pill>
                          <span>
                            {f.line !== null ? `Line ${f.line}: ` : ""}
                            {f.message}
                          </span>
                        </li>
                      ))}
                    </ul>
                  </Block>
                ) : null}

                {result.exclusions.length > 0 ? (
                  <Block title="Held back from this batch">
                    <ul className="flex flex-col gap-1 text-sm">
                      {result.exclusions.map((e) => (
                        <li key={e.line}>
                          Line {e.line}: {e.label}
                          {e.amountMinor !== null ? ` — ${money(e.amountMinor)}` : ""}
                          {e.quantity !== null ? ` (${e.quantity} units)` : ""}. {e.reason}.
                        </li>
                      ))}
                    </ul>
                  </Block>
                ) : null}

                {result.deferred.length > 0 ? (
                  <Block title="Read, and waiting for a later change">
                    <ul className="list-disc pl-5 text-xs text-muted-foreground">
                      {result.deferred.map((d) => (
                        <li key={d}>{d}</li>
                      ))}
                    </ul>
                  </Block>
                ) : null}

                {result.rows.length > 0 ? (
                  <Block title="First rows as they will be staged">
                    <pre className="max-h-60 overflow-auto rounded-md bg-muted p-2 text-xs">
                      {result.rows
                        .slice(0, 20)
                        .map((r, i) => `line ${result.lines[i] ?? "?"}  ${JSON.stringify(r)}`)
                        .join("\n")}
                    </pre>
                  </Block>
                ) : null}

                {opening ? (
                  <Block title="Control total">
                    <div className="grid gap-4 sm:grid-cols-3">
                      <Label text="As at">
                        <input
                          aria-label="As at"
                          type="date"
                          className={INPUT}
                          value={asAt}
                          onChange={(e) => setAsAt(e.target.value)}
                        />
                      </Label>
                      <Label text="Printed total on the report">
                        <input
                          aria-label="Printed total on the report"
                          className={INPUT}
                          inputMode="decimal"
                          value={printed}
                          placeholder="3,714.49"
                          onChange={(e) => setPrinted(e.target.value)}
                        />
                      </Label>
                      {profile.target.kind === "opening" && profile.target.domain === "stock" ? (
                        <Label text="Printed total quantity">
                          <input
                            aria-label="Printed total quantity"
                            className={INPUT}
                            inputMode="decimal"
                            value={printedQty}
                            onChange={(e) => setPrintedQty(e.target.value)}
                          />
                        </Label>
                      ) : null}
                    </div>
                    {control !== null ? (
                      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                        <dt className="text-muted-foreground">Printed</dt>
                        <dd>{printedMinor.ok ? money(printedMinor.minor) : "—"}</dd>
                        <dt className="text-muted-foreground">Less held back</dt>
                        <dd>
                          {money(result.exclusions.reduce((s, e) => s + (e.amountMinor ?? 0), 0))}
                        </dd>
                        <dt className="font-medium">Control figure</dt>
                        <dd className="font-medium">{money(control)}</dd>
                        <dt className="text-muted-foreground">This file stages</dt>
                        <dd>{money(result.stagedTotalMinor)}</dd>
                        <dt className="text-muted-foreground">Difference</dt>
                        <dd>
                          {control === result.stagedTotalMinor ? (
                            <Pill tone="ok">agrees</Pill>
                          ) : (
                            <Pill tone="bad">{money(result.stagedTotalMinor - control)}</Pill>
                          )}
                        </dd>
                        {controlQty !== null ? (
                          <>
                            <dt className="text-muted-foreground">Control quantity</dt>
                            <dd>
                              {controlQty} (this file stages {result.stagedQuantity ?? "—"})
                            </dd>
                          </>
                        ) : null}
                      </dl>
                    ) : printed.trim() !== "" ? (
                      <p className="text-sm text-destructive">
                        The printed total is not an amount.
                      </p>
                    ) : null}
                  </Block>
                ) : null}
              </>
            ) : null}

            <div className="flex flex-col gap-2">
              <ActionButton
                busy={action.isPending}
                disabled={!allowed || blockers.length > 0 || !result}
                title={allowed ? undefined : "Requires the import permission"}
                onClick={stage}
              >
                Stage batch
              </ActionButton>
              {blockers.length > 0 && result ? (
                <p className="text-xs text-muted-foreground">{blockers.join(" ")}</p>
              ) : null}
              {action.error ? <ErrorNote error={action.error} /> : null}
            </div>
          </>
        ) : null}
      </div>
    </section>
  );
}

function Label({ text, children }: { text: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="font-medium">{text}</span>
      {children}
    </label>
  );
}

function Block({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {title}
      </h3>
      {children}
    </div>
  );
}
