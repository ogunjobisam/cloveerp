import { useMutation } from "@tanstack/react-query";
import { useRef, useState } from "react";

import { dependentFields, optionArgs, optionList } from "../../lib/dependent-options";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  asTable,
  cellKind,
  currencyOf,
  fieldHeading,
  isEmptyAnswer,
  shownEntries,
} from "../../lib/inquiry-table";
import { fill } from "../../lib/interview";
import { formatMinor } from "../../lib/money";
import { missingRequired } from "../../lib/required-fields";
import { ActionButton, ComboField, ErrorNote, MultiField, type Field } from "./action";
import { shortDate } from "./auto";
import { Table } from "./panel";
import { useErpSession } from "./session-context";
import { Prose, TOUCH } from "./page";

/**
 * A question with parameters.
 *
 * A good third of the database's read surface cannot be a panel, because it
 * takes arguments a person has to choose: what can I promise on this item at
 * this site, what did this batch touch, what happened in this cold store
 * between these two times, how much credit has this customer left. Those reads
 * were reachable only over the API, which meant they were reachable by nobody.
 *
 * The form is the same declarative `Field` set the write actions use — so the
 * pickers, the site list and the permission rule are shared rather than
 * reimplemented — and the answer is rendered from whatever shape the function
 * returns, because these return JSON documents rather than uniform rows.
 */
export type InquirySpec = {
  label: string;
  description?: string;
  permission?: string;
  fn: string;
  fields: Field[];
  /**
   * The door's arguments from the answers, when they are not the answers as
   * they are: a field asked only to narrow another field's picker (the kind of
   * document, before the document) is not an argument of the door.
   */
  mapArgs?: (values: Record<string, unknown>) => Record<string, unknown>;
  /**
   * What an empty answer means, said in place of "None" when the answer is an
   * empty list or nothing (J-95): a bare "None" leaves the reader to guess
   * whether they asked wrongly or there is simply nothing.
   */
  empty?: string;
};

/**
 * One field of an answer. An amount in minor units is money, in the record's
 * own currency where it says one: "Resolve a purchase price" answered AMOUNT
 * MINOR 1850 for a price of £18.50; minor units belong to the door, never to
 * the screen. A date is shown short.
 */
function AnswerField({
  name,
  value,
  currency,
}: {
  name: string;
  value: unknown;
  currency: string;
}) {
  const kind = cellKind(name, value);
  if (kind === "money") {
    return <span className="tabular-nums">{formatMinor(value as number, currency)}</span>;
  }
  if (kind === "date") return <span className="whitespace-nowrap">{shortDate(value)}</span>;
  return <Value value={value} />;
}

function Value({ value }: { value: unknown }) {
  if (value === null || value === undefined || value === "") return <span>—</span>;
  if (typeof value === "boolean") return <span>{value ? "Yes" : "No"}</span>;
  if (Array.isArray(value)) {
    if (value.length === 0) return <span className="text-muted-foreground">None</span>;
    // Rows that share their fields are a table, read down a column (J-92):
    // a projection drawn as a card per day read as a stack of forms.
    const table = asTable(value);
    if (table) {
      return (
        <Table columns={table.columns.map((c) => c.heading)}>
          {table.rows.map((row, i) => (
            <tr key={i} className="border-b border-border/60 last:border-0">
              {table.columns.map((c) => (
                <td key={c.key} className="py-1.5 pr-4 align-top">
                  <AnswerField name={c.key} value={row[c.key]} currency={currencyOf(row)} />
                </td>
              ))}
            </tr>
          ))}
        </Table>
      );
    }
    return (
      <ul className="flex flex-col gap-1">
        {value.map((v, i) => (
          <li key={i} className="rounded-md bg-muted/50 p-2">
            <Value value={v} />
          </li>
        ))}
      </ul>
    );
  }
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    const currency = currencyOf(record);
    // Every field but the identifiers: ITEM SUPPLIER ID, PARTY ID and SITE ID
    // printed as UUIDs said nothing to the reader (J-109, J-105).
    return (
      <dl className="grid grid-cols-1 gap-1 sm:grid-cols-2">
        {shownEntries(record).map(([k, v]) => (
          <div key={k} className="min-w-0">
            <dt className="text-[11px] uppercase tracking-wide text-muted-foreground">
              {fieldHeading(k)}
            </dt>
            <dd className="break-words text-sm">
              <AnswerField name={k} value={v} currency={currency} />
            </dd>
          </div>
        ))}
      </dl>
    );
  }
  return <span className="break-words">{String(value)}</span>;
}

/**
 * One question, folded to its name until somebody wants to ask it.
 *
 * Financials and Planning each ended their Reports tab with six open forms and
 * Stock with five: a screenful of empty fields under the reports people came
 * for. A native <details> keeps every one of them a press away, opens from the
 * keyboard without any code here, and leaves the form in the page so what was
 * typed and what was answered survive being folded away again.
 */
function Inquiry({ spec, startsOpen }: { spec: InquirySpec; startsOpen: boolean }) {
  const { session } = useErpSession();
  const { ui } = useT();
  const [open, setOpen] = useState(startsOpen);
  const [values, setValues] = useState<Record<string, string>>(() => {
    const out: Record<string, string> = {};
    for (const f of spec.fields) if (f.default) out[f.name] = f.default;
    return out;
  });
  const [lists, setLists] = useState<Record<string, string[]>>({});
  // Whether Ask has been pressed. Until it has, nothing is marked missing.
  const [attempted, setAttempted] = useState(false);
  const formRef = useRef<HTMLFormElement | null>(null);
  const ask = useMutation({
    mutationFn: () => {
      const args: Record<string, unknown> = {};
      for (const f of spec.fields) {
        if (f.kind === "multi") {
          const chosen = lists[f.name] ?? [];
          if (chosen.length > 0) args[f.name] = chosen;
          continue;
        }
        const raw = values[f.name] ?? "";
        if (raw === "") continue;
        args[f.name] = f.kind === "number" ? Number(raw) : raw;
      }
      return callErp<unknown>(spec.fn, spec.mapArgs ? spec.mapArgs(args) : args);
    },
  });

  // A choice another picker follows takes that picker's answer with it: the
  // documents of the type chosen before are not documents of this one.
  function choose(name: string, value: string) {
    const followers = dependentFields(spec.fields, name);
    setValues((p) => {
      const next: Record<string, string> = { ...p, [name]: value };
      for (const f of followers) next[f] = "";
      return next;
    });
  }

  if (spec.permission && !hasPermission(session, spec.permission)) return null;

  // A required answer left empty was left out of the call, and the door,
  // asked without it, answered "not installed" (J-96). So the form checks
  // first, says what is missing beside it, and asks nothing until it is given.
  const missing = attempted ? missingRequired(spec.fields, values, {}, lists) : [];
  function submit() {
    setAttempted(true);
    const gaps = missingRequired(spec.fields, values, {}, lists);
    if (gaps.length > 0) {
      formRef.current
        ?.querySelector<HTMLElement>(`[data-field="${gaps[0]}"]`)
        ?.querySelector<HTMLElement>("input, select, textarea, button")
        ?.focus();
      return;
    }
    ask.mutate();
  }

  return (
    <details
      open={open}
      onToggle={(e) => setOpen(e.currentTarget.open)}
      className="min-w-0 rounded-xl border border-border bg-card"
    >
      {/* 44px with its padding: the whole line is the control. */}
      <summary className="cursor-pointer rounded-xl px-4 py-3 text-sm font-semibold sm:px-5">
        <h3 className="inline">{ui(spec.label)}</h3>
      </summary>

      <div className="flex min-w-0 flex-col gap-3 px-4 pb-4 sm:px-5 sm:pb-5">
        {spec.description ? (
          <Prose className="text-xs text-muted-foreground">{ui(spec.description)}</Prose>
        ) : null}

        <form
          ref={formRef}
          className="flex flex-wrap items-end gap-3"
          // The form checks itself and says what is missing; the browser's own
          // check stops at a bubble on the first field.
          noValidate
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          {spec.fields.map((f) => {
            const Wrap = f.kind === "multi" ? "div" : "label";
            return (
              <Wrap
                key={f.name}
                data-field={f.name}
                aria-invalid={missing.includes(f.name) || undefined}
                className="flex min-w-[12rem] flex-1 flex-col gap-1 text-sm"
              >
                <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  {ui(f.label)}
                </span>
                {f.kind === "site" ? (
                  <select
                    aria-label={ui(f.label)}
                    required={f.required ?? false}
                    value={values[f.name] ?? ""}
                    onChange={(e) => choose(f.name, e.target.value)}
                    className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                  >
                    <option value="">{ui("Choose…")}</option>
                    {session.sites.map((s) => (
                      <option key={s.id} value={s.id}>
                        {s.code} — {s.name}
                      </option>
                    ))}
                  </select>
                ) : f.kind === "choice" ? (
                  <select
                    aria-label={ui(f.label)}
                    required={f.required ?? false}
                    value={values[f.name] ?? ""}
                    onChange={(e) => choose(f.name, e.target.value)}
                    className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                  >
                    <option value="">{ui("Choose…")}</option>
                    {f.choices.map((c) => (
                      <option key={c.value} value={c.value}>
                        {ui(c.label)}
                      </option>
                    ))}
                  </select>
                ) : f.kind === "select" ? (
                  <SelectInput
                    spec={f}
                    value={values[f.name] ?? ""}
                    onChange={(v) => choose(f.name, v)}
                    values={values}
                  />
                ) : f.kind === "combo" ? (
                  <ComboField
                    field={f}
                    value={values[f.name] ?? ""}
                    onChange={(v) => setValues((p) => ({ ...p, [f.name]: v }))}
                  />
                ) : f.kind === "multi" ? (
                  <MultiField
                    field={f}
                    value={lists[f.name] ?? []}
                    onChange={(v) => setLists((p) => ({ ...p, [f.name]: v }))}
                  />
                ) : (
                  <input
                    aria-label={ui(f.label)}
                    required={f.required ?? false}
                    type={f.kind === "date" ? "date" : f.kind === "number" ? "number" : "text"}
                    placeholder={f.kind === "rows" ? "" : (f.placeholder ?? "")}
                    value={values[f.name] ?? ""}
                    onChange={(e) => setValues((p) => ({ ...p, [f.name]: e.target.value }))}
                    className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                  />
                )}
                {f.hint ? (
                  <span className="text-xs text-muted-foreground">{ui(f.hint)}</span>
                ) : null}
                {missing.includes(f.name) ? (
                  <span className="text-xs font-medium text-destructive">
                    {fill(ui("{field} is needed."), { field: ui(f.label) })}
                  </span>
                ) : null}
              </Wrap>
            );
          })}
          <ActionButton type="submit" busy={ask.isPending}>
            {ask.isPending ? ui("Asking…") : ui("Ask")}
          </ActionButton>
        </form>

        {ask.error ? <ErrorNote error={ask.error} /> : null}

        {ask.data !== undefined && !ask.error ? (
          <div className="min-w-0 rounded-md border border-border p-3">
            {spec.empty && isEmptyAnswer(ask.data) ? (
              <Prose className="text-sm text-muted-foreground">{ui(spec.empty)}</Prose>
            ) : (
              <Value value={ask.data} />
            )}
          </div>
        ) : null}
      </div>
    </details>
  );
}

/**
 * The same reference read the action forms use, without the dialog around it.
 *
 * It reads when it is first opened rather than when the page draws, because a
 * board folds a dozen questions nobody may ask. A picker that follows another
 * choice on the form (`argsFrom`) waits for it, asks with it, and reads again
 * when it changes, as the action forms' pickers do (J-97).
 */
function SelectInput({
  spec,
  value,
  onChange,
  values,
}: {
  spec: Extract<Field, { kind: "select" }>;
  value: string;
  onChange: (v: string) => void;
  /** The form's answers, for a picker whose list follows one of them. */
  values: Record<string, string>;
}) {
  const { ui } = useT();
  // Null while a choice this picker follows has not been made.
  const args = optionArgs(spec.options, values);
  const asked = args === null ? null : JSON.stringify(args);
  const [loaded, setLoaded] = useState<{ asked: string; data: unknown } | null>(null);
  const load = useMutation({
    mutationFn: (ask: { args: Record<string, unknown>; asked: string }) =>
      callErp<unknown>(spec.options.fn, ask.args).then((data) => {
        setLoaded({ asked: ask.asked, data });
        return data;
      }),
  });

  // What was read for an earlier choice is not this choice's list.
  const current = loaded !== null && loaded.asked === asked ? loaded.data : null;
  const rows =
    current === null
      ? null
      : (optionList(spec.options, current, values).filter(
          (row): row is Record<string, unknown> => typeof row === "object" && row !== null,
        ) as Record<string, unknown>[]);

  // Only the rows worth offering, and why there are none, as the action forms
  // say it: a group's parent, not every company (J-94).
  const keep = spec.options.keep;
  const kept = (rows ?? []).filter((row) => !keep || keep(row));
  const empty = rows !== null && kept.length === 0 ? spec.options.empty : undefined;
  const waiting = args === null;

  return (
    <>
      <select
        aria-label={ui(spec.label)}
        required={spec.required ?? false}
        value={value}
        disabled={waiting}
        onFocus={() => {
          if (args !== null && asked !== null && current === null && !load.isPending)
            load.mutate({ args, asked });
        }}
        onChange={(e) => onChange(e.target.value)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm disabled:opacity-60`}
      >
        <option value="">{load.isPending ? ui("Loading…") : ui("Choose…")}</option>
        {kept.map((row) => {
          const v = String(row[spec.options.value] ?? "");
          const label = spec.options.label
            .map((k) => row[k])
            .filter((x) => x !== null && x !== undefined && x !== "")
            .join(" — ");
          return (
            <option key={v} value={v}>
              {label || v}
            </option>
          );
        })}
      </select>
      {waiting ? (
        <span className="text-xs text-muted-foreground">{ui("Make the choice above first.")}</span>
      ) : empty ? (
        <span className="text-xs text-muted-foreground">{ui(empty)}</span>
      ) : null}
    </>
  );
}

/** The inquiries of one module, under its Reports tab. */
export function InquiryBoard({ inquiries }: { inquiries: InquirySpec[] }) {
  const { ui } = useT();
  const { session } = useErpSession();
  if (inquiries.length === 0) return null;

  // A board with one question on it is that question, so it is drawn open.
  // Counted as the person sees it: the ones they may not ask are not drawn.
  const drawn = inquiries.filter((i) => !i.permission || hasPermission(session, i.permission));
  const alone = drawn.length === 1;

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {ui("Ask a question")}
      </h2>
      {inquiries.map((i) => (
        <Inquiry key={`${i.fn}-${i.label}`} spec={i} startsOpen={alone} />
      ))}
    </div>
  );
}
