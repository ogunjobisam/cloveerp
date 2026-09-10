import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useMemo, useState, type ReactNode } from "react";
import { toast } from "sonner";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";

import { callErp, hasPermission } from "../../lib/erp";
import { friendlyError } from "../../lib/errors";
import { useT } from "../../lib/i18n";
import { minorUnitsOf, toMinor, type Currency } from "../../lib/money";
import { useCurrencies } from "./currencies";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";
import { useUnsavedGuard } from "./unsaved";

/**
 * The write surface.
 *
 * Until this file the app called 138 database functions through eleven call
 * sites, seven of which wrote — all of them onboarding or permissions admin.
 * Every one hand-rolled the same button classes and the same
 * `useMutation` + `setError` shape.
 *
 * Two rules hold everywhere here, and they are not the same rule:
 *
 *   - An action the caller may not perform is **not rendered**. Not disabled —
 *     absent, the way `Shell`'s navigation omits a section rather than greying
 *     it out. A disabled control still says "this exists and you cannot have
 *     it", which is a different and less useful sentence.
 *   - The database decides anyway. `hasPermission` reads a list the session
 *     handed us; `erp.authorise()` reads the grant. If they ever disagree the
 *     database wins, and the screen's job is to report that clearly rather
 *     than to have prevented it.
 */

/** One definition of what a button looks like, instead of seven copies. */
export function ActionButton({
  children,
  onClick,
  type = "button",
  variant = "primary",
  busy = false,
  disabled = false,
  title,
}: {
  children: ReactNode;
  onClick?: () => void;
  type?: "button" | "submit";
  variant?: "primary" | "secondary";
  busy?: boolean;
  disabled?: boolean;
  // `| undefined` explicitly: the root tsconfig sets exactOptionalPropertyTypes,
  // so an optional prop does not implicitly accept an undefined value.
  title?: string | undefined;
}) {
  const look =
    variant === "primary"
      ? "bg-primary text-primary-foreground font-semibold disabled:opacity-60"
      : "border border-input font-medium disabled:opacity-50";

  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled || busy}
      title={title}
      className={`${TOUCH} ${look} inline-flex shrink-0 items-center justify-center rounded-md px-4 text-sm`}
    >
      {children}
    </button>
  );
}

/**
 * The next action, when it lives on another screen.
 *
 * Half the empty states in this product are empty because of something that has
 * not been done somewhere else: no print route because no printer is
 * registered, no product-supplier because there are no suppliers, no posting
 * rule because the finance module was never installed. Telling somebody that
 * and leaving them to find the screen is most of the work of an ERP, and it is
 * exactly the work Sage X3 makes people do.
 *
 * So an empty state can carry a link rather than a button. It looks like the
 * secondary button because it does the same job — it is the thing to press —
 * and it is a `Link` rather than an `ActionButton` with a navigate() inside
 * because a link can be opened in a new tab, and middle-click is how people
 * actually work through a setup list.
 */
export function GoTo({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link
      to={to}
      className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-sm font-medium hover:border-accent/50 hover:text-accent`}
    >
      {children}
    </Link>
  );
}

/**
 * A failure, in words.
 *
 * The database's own text is precise and unreadable — `duplicate key value
 * violates unique constraint "change_set_tenant_id_code_key"` tells the person
 * who pressed Install nothing. `friendlyError` turns it into a sentence and
 * what to do next; the verbatim text stays, folded away, for support.
 */
export function ErrorNote({ error }: { error: unknown }) {
  if (!error) return null;
  const f = friendlyError(error);

  return (
    <div role="alert" className="rounded-md border border-destructive/40 bg-destructive/5 p-3">
      <p className="break-words text-sm font-medium text-destructive">{f.title}</p>
      {f.body ? <p className="mt-1 break-words text-xs text-muted-foreground">{f.body}</p> : null}
      {f.hint ? <p className="mt-2 break-words text-xs text-foreground">{f.hint}</p> : null}
      {f.technical ? (
        <details className="mt-2">
          <summary className="cursor-pointer text-xs text-muted-foreground underline-offset-2 hover:underline">
            Technical detail
          </summary>
          <p className="mt-1 break-words font-mono text-[11px] text-muted-foreground">
            {f.technical}
          </p>
        </details>
      ) : null}
    </div>
  );
}

/**
 * Why a screen is not offering what you came for.
 *
 * Rendered in place of a form rather than instead of the page, so the reason
 * arrives where the thing would have been.
 */
export function PermissionNote({ code }: { code: string }) {
  return (
    <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
      This account does not hold <code className="font-mono text-xs">{code}</code>, so that is not
      offered here. Absence of a grant is a refusal, not a default.
    </p>
  );
}

/**
 * A field on an action form.
 *
 * A `select` may name a reference read for its options — `erp_parties`,
 * `erp_items`, `erp_document_types`. That indirection is the reason those
 * functions exist: it keys the query as `[fn, args]`, the same shape
 * `DataPanel` uses, so the page's single Refresh reaches pickers too.
 *
 * Four rules hold for every field declared anywhere in this product, because
 * the forms were the single worst thing about using it:
 *
 *   - Nothing that names an existing record is typed. It is chosen.
 *   - A code being *created* may be typed, but the box shows the house style
 *     and offers the codes already in use (`combo`).
 *   - Anything still typed says what it expects, in a hint, with an example.
 *   - No JSON. A list of values is `multi`; a list of records is `rows`.
 */

/** What every field carries, whatever it asks for. */
type FieldBase = {
  name: string;
  label: string;
  required?: boolean;
  hint?: string;
  /** Shown in the empty box. An example, not an instruction. */
  placeholder?: string;
  /** What the box arrives holding. */
  default?: string;
};

/** Where a picker gets its list. */
export type OptionSource = {
  fn: string;
  args?: Record<string, unknown>;
  value: string;
  label: string[];
};

export type Field =
  | ({ kind: "text" } & FieldBase)
  | ({ kind: "number" } & FieldBase)
  | ({ kind: "date" } & FieldBase)
  /** Entered in major units, sent in minor. */
  | ({ kind: "money"; currency: string } & FieldBase)
  /** A fixed list — a database enum, or yes/no. Sent verbatim as text. */
  | ({
      kind: "choice";
      choices: { value: string; label: string }[];
      /** Send `true`/`false` rather than the string. */
      boolean?: boolean;
    } & FieldBase)
  /** The sites this session can see, from the session itself. */
  | ({ kind: "site" } & FieldBase)
  | ({ kind: "select"; options: OptionSource } & FieldBase)
  /** Pick an existing value or type a new one. For codes, which are both. */
  | ({ kind: "combo"; options: OptionSource } & FieldBase)
  /** Several of a thing. Sent as an array. Either a list read or a fixed set. */
  | ({
      kind: "multi";
      options?: OptionSource;
      choices?: { value: string; label: string }[];
    } & FieldBase)
  /** A list of records, added a row at a time. Sent as an array of objects. */
  | ({
      kind: "rows";
      columns: {
        name: string;
        label: string;
        kind: "text" | "number" | "date";
        placeholder?: string;
      }[];
      /** Values that should be sent as numbers rather than text. */
      addLabel?: string;
    } & FieldBase);

/** The label a picker shows for one row of its source. */
function optionLabel(row: Record<string, unknown>, keys: string[]): string {
  return keys
    .map((k) => row[k])
    .filter((x) => x !== null && x !== undefined && x !== "")
    .join(" — ");
}

function useOptions(source: OptionSource | undefined) {
  const { data, isPending, error } = useQuery({
    queryKey: [source?.fn ?? "none", source?.args ?? {}],
    queryFn: () =>
      source
        ? callErp<Record<string, unknown>[]>(source.fn, source.args ?? {})
        : Promise.resolve([] as Record<string, unknown>[]),
    enabled: Boolean(source),
  });

  const rows = source
    ? (Array.isArray(data) ? data : []).map((row) => ({
        value: String(row[source.value] ?? ""),
        label: optionLabel(row, source.label) || String(row[source.value] ?? ""),
      }))
    : [];

  return { rows, isPending: Boolean(source) && isPending, error };
}

/** Said once, because four controls need to say it. */
function PickerNote({
  isPending,
  error,
  empty,
}: {
  isPending: boolean;
  error: unknown;
  empty: boolean;
}) {
  if (error) return <span className="text-xs text-destructive">{friendlyError(error).title}</span>;
  // An empty picker is a fact worth stating: it usually means the master data
  // does not exist yet, not that the screen is broken.
  if (!isPending && empty)
    return (
      <span className="text-xs text-muted-foreground">
        Nothing to choose from yet — this list is empty for this organisation.
      </span>
    );
  return null;
}

export function SelectField({
  field,
  value,
  onChange,
}: {
  field: Extract<Field, { kind: "select" }>;
  value: string;
  onChange: (v: string) => void;
}) {
  const { rows, isPending, error } = useOptions(field.options);
  const [filter, setFilter] = useState("");

  // A hundred products in a dropdown is a list you scroll, not one you use.
  const filterable = rows.length > 12;
  const shown = filter
    ? rows.filter((r) => r.label.toLowerCase().includes(filter.toLowerCase()))
    : rows;

  return (
    <>
      {filterable ? (
        <input
          type="search"
          aria-label={`Search ${field.label} options`}
          value={filter}
          placeholder={`Search ${rows.length} options…`}
          onChange={(e) => setFilter(e.target.value)}
          className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
        />
      ) : null}
      <select
        aria-label={field.label}
        required={field.required ?? false}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={isPending || Boolean(error)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm disabled:opacity-60`}
      >
        <option value="">{isPending ? "Loading…" : "Choose…"}</option>
        {shown.map((r) => (
          <option key={r.value} value={r.value}>
            {r.label}
          </option>
        ))}
      </select>
      <PickerNote isPending={isPending} error={error} empty={rows.length === 0} />
    </>
  );
}

/**
 * A code, which may already exist or may be about to.
 *
 * The reason this is not a select: half these fields name something being
 * created. The reason it is not a plain box: the other half name something
 * that exists, and nobody remembers codes.
 */
export function ComboField({
  field,
  value,
  onChange,
}: {
  field: Extract<Field, { kind: "combo" }>;
  value: string;
  onChange: (v: string) => void;
}) {
  const { rows, isPending, error } = useOptions(field.options);
  const listId = `combo-${field.name}`;

  return (
    <>
      <input
        type="text"
        list={listId}
        aria-label={field.label}
        required={field.required ?? false}
        value={value}
        placeholder={field.placeholder ?? (isPending ? "Loading…" : "Choose one or type a new one")}
        onChange={(e) => onChange(e.target.value)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
      />
      <datalist id={listId}>
        {rows.map((r) => (
          <option key={r.value} value={r.value}>
            {r.label}
          </option>
        ))}
      </datalist>
      {error ? (
        <span className="text-xs text-destructive">{friendlyError(error).title}</span>
      ) : null}
    </>
  );
}

/** Several of a thing, ticked rather than pasted as JSON. */
export function MultiField({
  field,
  value,
  onChange,
}: {
  field: Extract<Field, { kind: "multi" }>;
  value: string[];
  onChange: (v: string[]) => void;
}) {
  const fetched = useOptions(field.options);
  const rows = field.choices ?? fetched.rows;
  const { isPending, error } = fetched;

  return (
    <>
      <div className="max-h-44 overflow-y-auto rounded-md border border-input bg-background p-2">
        {isPending ? <span className="text-xs text-muted-foreground">Loading…</span> : null}
        {rows.map((r) => (
          <label key={r.value} className="flex items-start gap-2 py-1 text-sm">
            <input
              type="checkbox"
              className="mt-1"
              checked={value.includes(r.value)}
              onChange={(e) =>
                onChange(
                  e.target.checked
                    ? [...value, r.value]
                    : value.filter((existing) => existing !== r.value),
                )
              }
            />
            <span className="min-w-0 break-words">{r.label}</span>
          </label>
        ))}
      </div>
      <PickerNote isPending={isPending} error={error} empty={rows.length === 0} />
    </>
  );
}

/** A list of records, one row at a time. The alternative was typing JSON. */
function RowsField({
  field,
  value,
  onChange,
}: {
  field: Extract<Field, { kind: "rows" }>;
  value: Record<string, string>[];
  onChange: (v: Record<string, string>[]) => void;
}) {
  return (
    <div className="flex flex-col gap-2">
      {value.map((row, index) => (
        <div key={index} className="flex flex-wrap items-end gap-2">
          {field.columns.map((c) => (
            <label key={c.name} className="flex min-w-[7rem] flex-1 flex-col gap-1">
              <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
                {c.label}
              </span>
              <input
                type={c.kind === "number" ? "number" : c.kind === "date" ? "date" : "text"}
                value={row[c.name] ?? ""}
                placeholder={c.placeholder ?? ""}
                onChange={(e) =>
                  onChange(
                    value.map((r, i) => (i === index ? { ...r, [c.name]: e.target.value } : r)),
                  )
                }
                className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
              />
            </label>
          ))}
          <ActionButton
            variant="secondary"
            onClick={() => onChange(value.filter((_, i) => i !== index))}
          >
            Remove
          </ActionButton>
        </div>
      ))}
      <div>
        <ActionButton variant="secondary" onClick={() => onChange([...value, {}])}>
          {field.addLabel ?? "Add a line"}
        </ActionButton>
      </div>
    </div>
  );
}

/**
 * An action behind a dialog.
 *
 * Renders nothing at all when the session does not hold `permission`. The
 * permission passed in should be the one the database checks — for documents
 * that is `create_permission` from `erp_document_types`, which is why that
 * read returns it.
 */
/** What a form arrives holding: whatever each field declared as its default. */
function initialValues(fields: Field[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of fields) if (f.default) out[f.name] = f.default;
  return out;
}

/**
 * Why a run raised nothing, per routine.
 *
 * "Nothing was raised" is true and useless. Each of these routines scans one
 * definite thing — stock standing in goods-in, pick faces under their top-up
 * level, bills approved and due — and when it finds none of it, the sentence
 * should name what it looked for, so the reader knows which step to go and
 * feed rather than assuming the button is broken.
 */
export const EMPTY_BY_FN: Record<string, string> = {
  erp_raise_putaway_tasks: "nothing is standing in goods-in at that site.",
  erp_raise_replenishment_tasks: "no pick face at that site is below its top-up level.",
  erp_raise_count_tasks: "nothing at that site is due to be counted.",
  erp_generate_count_tasks: "nothing at that site is due to be counted.",
  erp_plan_shipment: "none of those deliveries are ready to leave.",
  erp_run_planning: "the plan suggested no new orders.",
  erp_firm_planned_order: "there was no planned order left to firm.",
  erp_propose_payment_run: "no supplier bill is approved and due on that date.",
  erp_generate_invoice_schedules: "no order is due to be billed.",
  erp_generate_invoice_schedule: "no order is due to be billed.",
  erp_raise_inspection: "nothing received is waiting to be inspected.",
  erp_suggest_redistribution: "no site is short of stock another site can spare.",
};

/**
 * What just happened, in a sentence.
 *
 * Several of these routines answer with a count of the rows they raised, and a
 * count of nought is the commonest confusion in the product: the form closes,
 * nothing appears in the next step, and it looks broken when in fact there was
 * nothing standing there to move. So say so.
 */
export function outcomeOf(label: string, result: unknown, emptyNote?: string): string {
  const count =
    typeof result === "number"
      ? result
      : Array.isArray(result)
        ? result.length
        : typeof result === "object" &&
            result !== null &&
            typeof (result as Record<string, unknown>)["created"] === "number"
          ? ((result as Record<string, unknown>)["created"] as number)
          : null;

  if (count === 0)
    return emptyNote
      ? `${label}: nothing was raised — ${emptyNote} Change the site or the dates and try again.`
      : `${label}: nothing was raised — there was no work waiting to be moved on. Check the step, the site and the dates you chose.`;
  if (count !== null && count > 0)
    return `${label}: ${count} ${count === 1 ? "record" : "records"} created.`;
  return `${label} — done.`;
}

export function ActionDialog({
  trigger,
  title,
  description,
  permission,
  fn,
  fields,
  mapArgs,
  prefill,
  context,
  emptyNote,

  invalidates,
  submitLabel = "Save",
  onDone,
}: {
  trigger: ReactNode;
  title: string;
  description?: string;
  permission?: string | null;
  fn: string;
  fields: Field[];
  /** For arguments the form cannot express directly. Ticked lists and row
      editors arrive in the second argument, keyed by field name. */
  mapArgs?: (
    values: Record<string, string>,
    picked?: { lists: Record<string, string[]>; rows: Record<string, Record<string, string>[]> },
  ) => Record<string, unknown>;
  /**
   * Arguments the surrounding screen has already answered.
   *
   * A record chosen in a list is not a question worth asking again inside the
   * dialog, so a field of the same name is not rendered and the value is sent
   * regardless of what the form built.
   */
  prefill?: Record<string, unknown>;
  /**
   * What this form is acting on, in words.
   *
   * A prefilled record is not asked for again, which leaves a form with no
   * sign of which record it will change. This line puts it back.
   */
  context?: string;
  /**
   * What this routine looks for, when it finds none of it.
   *
   * Declared alongside the action where the answer is particular; otherwise
   * EMPTY_BY_FN carries the sentence for the function being called.
   */
  emptyNote?: string;

  invalidates: string[];
  submitLabel?: string;
  onDone?: (result: unknown) => void;
}) {
  const { session } = useErpSession();
  const { ui } = useT();
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [values, setValues] = useState<Record<string, string>>(() => initialValues(fields));
  const [lists, setLists] = useState<Record<string, string[]>>({});
  const [rows, setRows] = useState<Record<string, Record<string, string>[]>>({});

  // An open form with something typed into it is work in progress, and
  // leaving the screen must ask before it is thrown away.
  const untouched = useMemo(() => JSON.stringify(initialValues(fields)), [fields]);
  useUnsavedGuard(
    open &&
      (JSON.stringify(values) !== untouched ||
        Object.values(lists).some((l) => l.length > 0) ||
        Object.values(rows).some((r) => r.length > 0)),
  );

  // Only fetched when something on this form takes a price.
  const takesMoney = fields.some((f) => f.kind === "money");
  const { currencies, error: currencyError } = useCurrencies(takesMoney);

  const action = useMutation({
    mutationFn: () => callErp<unknown>(fn, buildArgs()),
    onSuccess: (result) => {
      invalidates.forEach((key) => queryClient.invalidateQueries({ queryKey: [key] }));
      setValues(initialValues(fields));
      setLists({});
      setRows({});
      setOpen(false);
      toast(
        outcomeOf(ui(title), result, emptyNote ?? EMPTY_BY_FN[fn]),
        context ? { description: context } : undefined,
      );

      onDone?.(result);
    },
  });

  function buildArgs(): Record<string, unknown> {
    if (mapArgs) return { ...mapArgs(values, { lists, rows }), ...(prefill ?? {}) };
    const args: Record<string, unknown> = {};

    for (const f of fields) {
      if (f.kind === "multi") {
        const chosen = lists[f.name] ?? [];
        if (chosen.length > 0) args[f.name] = chosen;
        continue;
      }
      if (f.kind === "rows") {
        const declared = f.columns;
        const filled = (rows[f.name] ?? [])
          .map((row) => {
            const out: Record<string, unknown> = {};
            for (const c of declared) {
              const raw = row[c.name] ?? "";
              if (raw === "") continue;
              out[c.name] = c.kind === "number" ? Number(raw) : raw;
            }
            return out;
          })
          .filter((row) => Object.keys(row).length > 0);
        if (filled.length > 0) args[f.name] = filled;
        continue;
      }
      const raw = values[f.name] ?? "";
      if (raw === "") continue;
      if (f.kind === "number") args[f.name] = Number(raw);
      else if (f.kind === "money")
        args[f.name] = toMinor(raw, minorUnitsOf(currencies, f.currency));
      else if (f.kind === "choice" && f.boolean) args[f.name] = raw === "true";
      else args[f.name] = raw;
    }
    return { ...args, ...(prefill ?? {}) };
  }

  // Not offered rather than offered-and-disabled. The database still decides.
  if (permission && !hasPermission(session, permission)) return null;

  /**
   * A question or two is a confirmation; a form is a piece of work.
   *
   * Anything asking for more than two things opens as its own screen — a full
   * work area with room for pickers and line editors — rather than a box
   * floating over the list behind it. Short confirmations stay as the box,
   * because taking over the screen to ask one thing is worse, not better.
   */
  const shown = fields.filter((f) => !(prefill && f.name in prefill));
  const asPage = shown.length > 2;

  const body = (
    <form
      className="flex flex-col gap-3"
      onSubmit={(e) => {
        e.preventDefault();
        action.mutate();
      }}
    >
      {context ? (
        <div className="rounded-md border border-border bg-muted/50 px-3 py-2 text-xs">
          <span className="font-medium uppercase tracking-wide text-muted-foreground">
            {ui("Acting on")}
          </span>
          <span className="mt-0.5 block font-mono text-sm">{context}</span>
        </div>
      ) : null}

      {fields
        .filter((f) => !(prefill && f.name in prefill))
        .map((f) => {
          // A group of checkboxes or a row editor holds labels of its own, and
          // a label inside a label is neither valid nor navigable.
          const Wrap = f.kind === "multi" || f.kind === "rows" ? "div" : "label";
          return (
            <Wrap key={f.name} className="flex min-w-0 flex-col gap-1 text-sm">
              <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {ui(f.label)}
                {f.kind === "money" ? ` (${f.currency})` : ""}
              </span>

              {f.kind === "select" ? (
                <SelectField
                  field={f}
                  value={values[f.name] ?? ""}
                  onChange={(v) => setValues((prev) => ({ ...prev, [f.name]: v }))}
                />
              ) : f.kind === "combo" ? (
                <ComboField
                  field={f}
                  value={values[f.name] ?? ""}
                  onChange={(v) => setValues((prev) => ({ ...prev, [f.name]: v }))}
                />
              ) : f.kind === "multi" ? (
                <MultiField
                  field={f}
                  value={lists[f.name] ?? []}
                  onChange={(v) => setLists((prev) => ({ ...prev, [f.name]: v }))}
                />
              ) : f.kind === "rows" ? (
                <RowsField
                  field={f}
                  value={rows[f.name] ?? []}
                  onChange={(v) => setRows((prev) => ({ ...prev, [f.name]: v }))}
                />
              ) : f.kind === "choice" || f.kind === "site" ? (
                <select
                  aria-label={ui(f.label)}
                  required={f.required ?? false}
                  value={values[f.name] ?? ""}
                  onChange={(e) => setValues((prev) => ({ ...prev, [f.name]: e.target.value }))}
                  className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                >
                  <option value="">Choose…</option>
                  {(f.kind === "site"
                    ? session.sites.map((s) => ({
                        value: s.id,
                        label: `${s.code} — ${s.name}`,
                      }))
                    : f.choices
                  ).map((c) => (
                    <option key={c.value} value={c.value}>
                      {/* Through ui() like the field's own label. InquiryBoard
                          has always done this for its choices; this one did
                          not, so a form could offer a renameable "Kind of
                          site" above a fixed "Warehouse". A site kind built
                          from the session carries a code and a name and has no
                          row, which ui() handles by returning what it was
                          given. */}
                      {ui(c.label)}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  aria-label={ui(f.label)}
                  type={f.kind === "date" ? "date" : f.kind === "text" ? "text" : "number"}
                  inputMode={f.kind === "money" || f.kind === "number" ? "decimal" : undefined}
                  step={f.kind === "money" ? "any" : undefined}
                  required={f.required ?? false}
                  placeholder={f.placeholder ?? ""}
                  value={values[f.name] ?? ""}
                  onChange={(e) => setValues((prev) => ({ ...prev, [f.name]: e.target.value }))}
                  className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                />
              )}

              {f.hint ? <span className="text-xs text-muted-foreground">{ui(f.hint)}</span> : null}
            </Wrap>
          );
        })}

      <ErrorNote error={action.error} />
      {/* minorUnitsOf falls back to two places when it does not know the
              currency, which is right when the currency is unknown and wrong
              when the *table* is missing: for a nil-decimal currency it would
              multiply the typed amount by a hundred on its way to the ledger.
              So a failed lookup blocks pricing instead of guessing. */}
      {currencyError ? (
        <p className="text-xs text-destructive">
          {ui(
            "The currency list could not be loaded, so an amount cannot be converted safely. Nothing has been submitted.",
          )}
        </p>
      ) : null}

      <div className="mt-2 flex flex-wrap justify-end gap-2">
        <ActionButton
          variant="secondary"
          onClick={() => {
            setOpen(false);
            action.reset();
          }}
        >
          {ui("Cancel")}
        </ActionButton>
        <ActionButton
          type="submit"
          busy={action.isPending}
          disabled={takesMoney && Boolean(currencyError)}
        >
          {action.isPending ? ui("Working…") : ui(submitLabel)}
        </ActionButton>
      </div>
    </form>
  );

  if (asPage)
    return (
      <>
        <span
          className="contents"
          onClick={() => {
            setOpen(true);
          }}
        >
          {trigger}
        </span>
        {open ? (
          <div
            role="dialog"
            aria-modal="true"
            aria-label={ui(title)}
            className="fixed inset-0 z-50 overflow-y-auto bg-background"
          >
            <div className="sticky top-0 z-10 border-b border-border bg-background/95 backdrop-blur">
              <div className="mx-auto flex w-full max-w-3xl items-center gap-3 px-4 py-3 sm:px-6">
                <ActionButton
                  variant="secondary"
                  onClick={() => {
                    setOpen(false);
                    action.reset();
                  }}
                >
                  {ui("Back")}
                </ActionButton>
                <div className="min-w-0">
                  <h2 className="truncate text-sm font-semibold">{ui(title)}</h2>
                  {description ? (
                    <p className="truncate text-xs text-muted-foreground">{ui(description)}</p>
                  ) : null}
                </div>
              </div>
            </div>
            <div className="mx-auto w-full max-w-3xl px-4 py-6 sm:px-6">{body}</div>
          </div>
        ) : null}
      </>
    );

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) action.reset();
      }}
    >
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <DialogContent className="max-h-[85vh] w-[92vw] max-w-lg overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{ui(title)}</DialogTitle>
          {description ? <DialogDescription>{ui(description)}</DialogDescription> : null}
        </DialogHeader>
        {body}
      </DialogContent>
    </Dialog>
  );
}

/**
 * An action with no form behind it — a transition, an approval, a promotion.
 *
 * Same permission rule and the same error fidelity; it simply has nothing to
 * ask before it acts.
 */
export function useErpAction({
  fn,
  invalidates,
  onDone,
}: {
  fn: string;
  invalidates: string[];
  onDone?: (result: unknown) => void;
}) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (args: Record<string, unknown> = {}) => callErp<unknown>(fn, args),
    onSuccess: (result) => {
      invalidates.forEach((key) => queryClient.invalidateQueries({ queryKey: [key] }));
      onDone?.(result);
    },
  });
}
