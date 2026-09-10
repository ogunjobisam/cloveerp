import { useMutation } from "@tanstack/react-query";
import { useState } from "react";

import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ComboField, ErrorNote, MultiField, type Field } from "./action";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";

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
};

function Value({ value }: { value: unknown }) {
  if (value === null || value === undefined || value === "") return <span>—</span>;
  if (typeof value === "boolean") return <span>{value ? "Yes" : "No"}</span>;
  if (Array.isArray(value)) {
    if (value.length === 0) return <span className="text-muted-foreground">None</span>;
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
    return (
      <dl className="grid grid-cols-1 gap-1 sm:grid-cols-2">
        {Object.entries(value as Record<string, unknown>).map(([k, v]) => (
          <div key={k} className="min-w-0">
            <dt className="text-[11px] uppercase tracking-wide text-muted-foreground">
              {k.replace(/_/g, " ")}
            </dt>
            <dd className="break-words text-sm">
              <Value value={v} />
            </dd>
          </div>
        ))}
      </dl>
    );
  }
  return <span className="break-words">{String(value)}</span>;
}

function Inquiry({ spec }: { spec: InquirySpec }) {
  const { session } = useErpSession();
  const { ui } = useT();
  const [values, setValues] = useState<Record<string, string>>(() => {
    const out: Record<string, string> = {};
    for (const f of spec.fields) if (f.default) out[f.name] = f.default;
    return out;
  });
  const [lists, setLists] = useState<Record<string, string[]>>({});
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
      return callErp<unknown>(spec.fn, args);
    },
  });

  if (spec.permission && !hasPermission(session, spec.permission)) return null;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h3 className="text-sm font-semibold">{ui(spec.label)}</h3>
      {spec.description ? (
        <p className="mt-0.5 text-xs text-muted-foreground">{ui(spec.description)}</p>
      ) : null}

      <form
        className="mt-3 flex flex-wrap items-end gap-3"
        onSubmit={(e) => {
          e.preventDefault();
          ask.mutate();
        }}
      >
        {spec.fields.map((f) => {
          const Wrap = f.kind === "multi" ? "div" : "label";
          return (
          <Wrap key={f.name} className="flex min-w-[12rem] flex-1 flex-col gap-1 text-sm">
            <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {ui(f.label)}
            </span>
            {f.kind === "site" ? (
              <select
                value={values[f.name] ?? ""}
                onChange={(e) => setValues((p) => ({ ...p, [f.name]: e.target.value }))}
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
                value={values[f.name] ?? ""}
                onChange={(e) => setValues((p) => ({ ...p, [f.name]: e.target.value }))}
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
                onChange={(v) => setValues((p) => ({ ...p, [f.name]: v }))}
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
                type={f.kind === "date" ? "date" : f.kind === "number" ? "number" : "text"}
                placeholder={f.kind === "rows" ? "" : (f.placeholder ?? "")}
                value={values[f.name] ?? ""}
                onChange={(e) => setValues((p) => ({ ...p, [f.name]: e.target.value }))}
                className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
              />
            )}
            {f.hint ? <span className="text-xs text-muted-foreground">{ui(f.hint)}</span> : null}
          </Wrap>
          );
        })}
        <ActionButton type="submit" busy={ask.isPending}>
          {ask.isPending ? ui("Asking…") : ui("Ask")}
        </ActionButton>
      </form>

      {ask.error ? (
        <div className="mt-3">
          <ErrorNote error={ask.error} />
        </div>
      ) : null}

      {ask.data !== undefined && !ask.error ? (
        <div className="mt-3 rounded-md border border-border p-3">
          <Value value={ask.data} />
        </div>
      ) : null}
    </section>
  );
}

/** The same reference read the action forms use, without the dialog around it. */
function SelectInput({
  spec,
  value,
  onChange,
}: {
  spec: Extract<Field, { kind: "select" }>;
  value: string;
  onChange: (v: string) => void;
}) {
  const { ui } = useT();
  const [rows, setRows] = useState<Record<string, unknown>[] | null>(null);
  const load = useMutation({
    mutationFn: () =>
      callErp<Record<string, unknown>[]>(spec.options.fn, spec.options.args ?? {}).then((r) => {
        setRows(r);
        return r;
      }),
  });

  return (
    <select
      aria-label={ui(spec.label)}
      value={value}
      onFocus={() => {
        if (rows === null && !load.isPending) load.mutate();
      }}
      onChange={(e) => onChange(e.target.value)}
      className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
    >
      <option value="">{load.isPending ? ui("Loading…") : ui("Choose…")}</option>
      {(rows ?? []).map((row) => {
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
  );
}

/** The inquiries of one module, under its Reports tab. */
export function InquiryBoard({ inquiries }: { inquiries: InquirySpec[] }) {
  const { ui } = useT();
  if (inquiries.length === 0) return null;

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
        {ui("Ask a question")}
      </h2>
      {inquiries.map((i) => (
        <Inquiry key={`${i.fn}-${i.label}`} spec={i} />
      ))}
    </div>
  );
}
