import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";

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
import { minorUnitsOf, toMinor, type Currency } from "../../lib/money";
import { useErpSession } from "./session-context";
import { TOUCH } from "./page";

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
 */
export type Field =
  | { kind: "text"; name: string; label: string; required?: boolean; hint?: string }
  | { kind: "number"; name: string; label: string; required?: boolean; hint?: string }
  | { kind: "date"; name: string; label: string; required?: boolean; hint?: string }
  | {
      /** Entered in major units, sent in minor. */
      kind: "money";
      name: string;
      label: string;
      currency: string;
      required?: boolean;
      hint?: string;
    }
  | {
      /** A fixed list — a database enum, or yes/no. Sent verbatim as text. */
      kind: "choice";
      name: string;
      label: string;
      required?: boolean;
      hint?: string;
      choices: { value: string; label: string }[];
      /** Send `true`/`false` rather than the string. */
      boolean?: boolean;
    }
  | {
      /** The sites this session can see, from the session itself. */
      kind: "site";
      name: string;
      label: string;
      required?: boolean;
      hint?: string;
    }
  | {
      kind: "select";
      name: string;
      label: string;
      required?: boolean;
      hint?: string;
      options: { fn: string; args?: Record<string, unknown>; value: string; label: string[] };
    };

function SelectField({
  field,
  value,
  onChange,
}: {
  field: Extract<Field, { kind: "select" }>;
  value: string;
  onChange: (v: string) => void;
}) {
  const { data, isPending, error } = useQuery({
    queryKey: [field.options.fn, field.options.args ?? {}],
    queryFn: () => callErp<Record<string, unknown>[]>(field.options.fn, field.options.args ?? {}),
  });

  return (
    <>
      <select
        required={field.required ?? false}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        disabled={isPending || Boolean(error)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm disabled:opacity-60`}
      >
        <option value="">{isPending ? "Loading…" : "Choose…"}</option>
        {(data ?? []).map((row) => {
          const v = String(row[field.options.value] ?? "");
          const label = field.options.label
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
      {/* An empty picker is a fact worth stating: it usually means the master
          data does not exist yet, not that the screen is broken. */}
      {!isPending && !error && (data ?? []).length === 0 ? (
        <span className="text-xs text-muted-foreground">
          Nothing to choose from yet — this list is empty for this tenant.
        </span>
      ) : null}
      {error ? (
        <span className="text-xs text-destructive">{friendlyError(error).title}</span>
      ) : null}
    </>
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
export function ActionDialog({
  trigger,
  title,
  description,
  permission,
  fn,
  fields,
  mapArgs,
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
  mapArgs?: (values: Record<string, string>) => Record<string, unknown>;
  invalidates: string[];
  submitLabel?: string;
  onDone?: (result: unknown) => void;
}) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  const [values, setValues] = useState<Record<string, string>>({});

  const { data: currencies } = useQuery({
    queryKey: ["erp_currencies", {}],
    queryFn: () => callErp<Currency[]>("erp_currencies"),
    // Product content: identical for every tenant and effectively immutable.
    staleTime: Infinity,
    enabled: fields.some((f) => f.kind === "money"),
  });

  const action = useMutation({
    mutationFn: () => callErp<unknown>(fn, buildArgs()),
    onSuccess: (result) => {
      invalidates.forEach((key) => queryClient.invalidateQueries({ queryKey: [key] }));
      setValues({});
      setOpen(false);
      onDone?.(result);
    },
  });

  function buildArgs(): Record<string, unknown> {
    if (mapArgs) return mapArgs(values);
    const args: Record<string, unknown> = {};
    for (const f of fields) {
      const raw = values[f.name] ?? "";
      if (raw === "") continue;
      if (f.kind === "number") args[f.name] = Number(raw);
      else if (f.kind === "money")
        args[f.name] = toMinor(raw, minorUnitsOf(currencies, f.currency));
      else if (f.kind === "choice" && f.boolean) args[f.name] = raw === "true";
      else args[f.name] = raw;
    }
    return args;
  }

  // Not offered rather than offered-and-disabled. The database still decides.
  if (permission && !hasPermission(session, permission)) return null;

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
          <DialogTitle>{title}</DialogTitle>
          {description ? <DialogDescription>{description}</DialogDescription> : null}
        </DialogHeader>

        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            action.mutate();
          }}
        >
          {fields.map((f) => (
            <label key={f.name} className="flex min-w-0 flex-col gap-1 text-sm">
              <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                {f.label}
                {f.kind === "money" ? ` (${f.currency})` : ""}
              </span>

              {f.kind === "select" ? (
                <SelectField
                  field={f}
                  value={values[f.name] ?? ""}
                  onChange={(v) => setValues((prev) => ({ ...prev, [f.name]: v }))}
                />
              ) : f.kind === "choice" || f.kind === "site" ? (
                <select
                  required={f.required ?? false}
                  value={values[f.name] ?? ""}
                  onChange={(e) => setValues((prev) => ({ ...prev, [f.name]: e.target.value }))}
                  className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                >
                  <option value="">Choose…</option>
                  {(f.kind === "site"
                    ? session.sites.map((s) => ({ value: s.id, label: `${s.code} — ${s.name}` }))
                    : f.choices
                  ).map((c) => (
                    <option key={c.value} value={c.value}>
                      {c.label}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  type={f.kind === "date" ? "date" : f.kind === "text" ? "text" : "number"}
                  inputMode={f.kind === "money" || f.kind === "number" ? "decimal" : undefined}
                  step={f.kind === "money" ? "any" : undefined}
                  required={f.required ?? false}
                  value={values[f.name] ?? ""}
                  onChange={(e) => setValues((prev) => ({ ...prev, [f.name]: e.target.value }))}
                  className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
                />
              )}

              {f.hint ? <span className="text-xs text-muted-foreground">{f.hint}</span> : null}
            </label>
          ))}

          <ErrorNote error={action.error} />

          <div className="mt-2 flex flex-wrap justify-end gap-2">
            <ActionButton variant="secondary" onClick={() => setOpen(false)}>
              Cancel
            </ActionButton>
            <ActionButton type="submit" busy={action.isPending}>
              {action.isPending ? "Working…" : submitLabel}
            </ActionButton>
          </div>
        </form>
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
