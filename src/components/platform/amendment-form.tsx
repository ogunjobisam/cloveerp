import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useState, type ReactNode } from "react";

import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { formatMinorWhole } from "../../lib/money";
import {
  amendmentChanges,
  describeUplift,
  EMPTY_AMENDMENT,
  RENEWAL_LABELS,
  UPLIFT_LABELS,
  type AmendmentForm,
  type RenewalKind,
  type UpliftKind,
} from "../../lib/contract-terms";
import { Fail, INPUT } from "./kit";
import type { PlatformPlans } from "./plans";

/**
 * Drafting an amendment, as a form.
 *
 * The changes were typed as JSON into a box, with the keys listed in its label.
 * Every key erp.amend_contract accepts is a field here instead, each arriving
 * blank and saying what the contract holds now; a blank field is left as it
 * is. A plan, a band or a support tier is chosen from what the platform has, so
 * the door's "unknown plan" refusal is one nobody can reach by typing.
 * src/lib/contract-terms.ts builds what is sent, and is tested.
 */

const BUTTON = `${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-xs font-medium`;

/** What the contract holds now, as erp_platform_contract returns it. */
export type AmendableContract = {
  plan_code: string;
  plan_name: string | null;
  currency: string;
  annual_value_minor: number;
  current_term_start: string;
  current_term_end: string;
  renewal_kind: string;
  notice_days: number;
  uplift_rule: Record<string, unknown>;
  support_severity_code: string | null;
  entitlements: {
    entitlement_code: string;
    title: string | null;
    limit_value: number | null;
    in_force: boolean;
  }[];
  capabilities: { capability_code: string; in_force: boolean }[];
};

type Severity = { code: string; name: string };

/**
 * Console text is not tenant terminology: nothing here goes through ui(), so
 * the prop is `caption` rather than `label`, which supabase/ci/screen_strings.sh
 * reads as a string a tenant can rename.
 */
function Field({
  caption,
  hint,
  children,
}: {
  caption: string;
  hint?: ReactNode;
  children: (id: string) => ReactNode;
}) {
  const id = useId();
  return (
    <div className="flex flex-col gap-1">
      <label htmlFor={id} className="text-xs font-medium">
        {caption}
      </label>
      {children(id)}
      {hint ? <p className="text-xs text-muted-foreground">{hint}</p> : null}
    </div>
  );
}

export function DraftAmendment({
  contractId,
  contract: c,
  invalidates,
}: {
  contractId: string;
  contract: AmendableContract;
  invalidates: string[];
}) {
  const queryClient = useQueryClient();
  const plans = useQuery({
    queryKey: ["erp_platform_plans"],
    queryFn: () => callErp<PlatformPlans>("erp_platform_plans"),
  });
  const severities = useQuery({
    queryKey: ["erp_support_severities"],
    queryFn: () => callErp<Severity[]>("erp_support_severities"),
    retry: false,
  });

  const [title, setTitle] = useState("");
  const [from, setFrom] = useState("");
  const [why, setWhy] = useState("");
  const [form, setForm] = useState<AmendmentForm>(EMPTY_AMENDMENT);
  const [tried, setTried] = useState(false);

  const set = <K extends keyof AmendmentForm>(key: K, value: AmendmentForm[K]) =>
    setForm((prev) => ({ ...prev, [key]: value }));

  const draft = useMutation({
    mutationFn: (changes: Record<string, unknown>) =>
      callErp("erp_platform_amend_contract", {
        p_contract_id: contractId,
        p_title: title.trim(),
        p_effective_from: from,
        p_changes: changes,
        p_rationale: why.trim() || null,
      }),
    onSuccess: () => {
      for (const k of invalidates) void queryClient.invalidateQueries({ queryKey: [k] });
      setTitle("");
      setFrom("");
      setWhy("");
      setForm(EMPTY_AMENDMENT);
      setTried(false);
    },
  });

  const built = amendmentChanges(form);
  const missing =
    title.trim() === ""
      ? "Give the amendment a title."
      : from === ""
        ? "Say when it takes effect."
        : null;
  const problem = missing ?? (built.ok ? null : built.problem);

  const planList = plans.data?.plans ?? [];
  const kinds = plans.data?.entitlement_kinds ?? [];
  const featureCodes = [
    ...new Set([
      ...planList.flatMap((p) => p.capabilities),
      ...c.capabilities.map((f) => f.capability_code),
    ]),
  ].sort();
  const inForceFeatures = c.capabilities.filter((f) => f.in_force).map((f) => f.capability_code);
  const featureList = `amendment-features-${contractId}`;

  return (
    <form
      className="flex flex-col gap-4 rounded-lg border border-border/60 p-3"
      onSubmit={(e) => {
        e.preventDefault();
        setTried(true);
        if (problem === null && built.ok) draft.mutate(built.changes);
      }}
    >
      <div className="grid gap-3 sm:grid-cols-2">
        <Field caption="Title">
          {(id) => (
            <input
              id={id}
              className={INPUT}
              value={title}
              placeholder="More users for the second site"
              onChange={(e) => setTitle(e.target.value)}
            />
          )}
        </Field>
        <Field caption="Takes effect from">
          {(id) => (
            <input
              id={id}
              type="date"
              className={INPUT}
              value={from}
              onChange={(e) => setFrom(e.target.value)}
            />
          )}
        </Field>
      </div>

      <div>
        <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          What changes
        </h3>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Fill in only what changes. Anything left blank stays as the contract has it.
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <Field caption="Plan" hint={`Now ${c.plan_name ?? c.plan_code}.`}>
          {(id) => (
            <select
              id={id}
              className={INPUT}
              value={form.planCode}
              onChange={(e) => set("planCode", e.target.value)}
            >
              <option value="">Unchanged</option>
              {planList
                .filter((p) => p.code !== c.plan_code)
                .map((p) => (
                  <option key={p.code} value={p.code}>
                    {p.name}
                  </option>
                ))}
            </select>
          )}
        </Field>
        <Field
          caption={`Annual value, ${c.currency}`}
          hint={`Now ${formatMinorWhole(c.annual_value_minor, c.currency)}.`}
        >
          {(id) => (
            <input
              id={id}
              type="number"
              min={0}
              step="any"
              inputMode="decimal"
              className={INPUT}
              value={form.annualValue}
              onChange={(e) => set("annualValue", e.target.value)}
            />
          )}
        </Field>
        <Field
          caption="Current term ends"
          hint={`Now ${new Date(c.current_term_end).toLocaleDateString()}.`}
        >
          {(id) => (
            <input
              id={id}
              type="date"
              min={c.current_term_start}
              className={INPUT}
              value={form.termEnd}
              onChange={(e) => set("termEnd", e.target.value)}
            />
          )}
        </Field>
        <Field
          caption="Renewal"
          hint={`Now: ${RENEWAL_LABELS[c.renewal_kind as RenewalKind] ?? c.renewal_kind}.`}
        >
          {(id) => (
            <select
              id={id}
              className={INPUT}
              value={form.renewalKind}
              onChange={(e) => set("renewalKind", e.target.value as AmendmentForm["renewalKind"])}
            >
              <option value="">Unchanged</option>
              {(Object.keys(RENEWAL_LABELS) as RenewalKind[])
                .filter((k) => k !== c.renewal_kind)
                .map((k) => (
                  <option key={k} value={k}>
                    {RENEWAL_LABELS[k]}
                  </option>
                ))}
            </select>
          )}
        </Field>
        <Field caption="Notice period, days" hint={`Now ${c.notice_days} days.`}>
          {(id) => (
            <input
              id={id}
              type="number"
              min={0}
              step={1}
              className={INPUT}
              value={form.noticeDays}
              onChange={(e) => set("noticeDays", e.target.value)}
            />
          )}
        </Field>
        <Field
          caption="Support tier"
          hint={c.support_severity_code ? `Now ${c.support_severity_code}.` : "None named now."}
        >
          {(id) =>
            severities.data && severities.data.length > 0 ? (
              <select
                id={id}
                className={INPUT}
                value={form.supportSeverity}
                onChange={(e) => set("supportSeverity", e.target.value)}
              >
                <option value="">Unchanged</option>
                {severities.data
                  .filter((s) => s.code !== c.support_severity_code)
                  .map((s) => (
                    <option key={s.code} value={s.code}>
                      {s.name}
                    </option>
                  ))}
              </select>
            ) : (
              <input
                id={id}
                className={INPUT}
                value={form.supportSeverity}
                placeholder="Unchanged"
                onChange={(e) => set("supportSeverity", e.target.value)}
              />
            )
          }
        </Field>
      </div>

      <div className="grid gap-3 sm:grid-cols-2">
        <Field caption="Uplift at renewal" hint={`Now: ${describeUplift(c.uplift_rule)}.`}>
          {(id) => (
            <select
              id={id}
              className={INPUT}
              value={form.upliftKind}
              onChange={(e) => set("upliftKind", e.target.value as AmendmentForm["upliftKind"])}
            >
              <option value="">Unchanged</option>
              {(Object.keys(UPLIFT_LABELS) as UpliftKind[]).map((k) => (
                <option key={k} value={k}>
                  {UPLIFT_LABELS[k]}
                </option>
              ))}
            </select>
          )}
        </Field>
        {form.upliftKind === "fixed_pct" ? (
          <Field caption="Uplift, per cent">
            {(id) => (
              <input
                id={id}
                type="number"
                step="0.1"
                className={INPUT}
                value={form.upliftPct}
                onChange={(e) => set("upliftPct", e.target.value)}
              />
            )}
          </Field>
        ) : null}
        {form.upliftKind === "index" || form.upliftKind === "capped" ? (
          <Field caption="Index">
            {(id) => (
              <input
                id={id}
                className={INPUT}
                placeholder="CPI"
                value={form.upliftIndex}
                onChange={(e) => set("upliftIndex", e.target.value)}
              />
            )}
          </Field>
        ) : null}
        {form.upliftKind === "capped" ? (
          <Field caption="Capped at, per cent">
            {(id) => (
              <input
                id={id}
                type="number"
                step="0.1"
                className={INPUT}
                value={form.upliftCap}
                onChange={(e) => set("upliftCap", e.target.value)}
              />
            )}
          </Field>
        ) : null}
      </div>

      <fieldset className="flex flex-col gap-2">
        <legend className="text-xs font-medium">Bands</legend>
        <p className="text-xs text-muted-foreground">
          A new limit for a band, from the date the amendment takes effect. Leave the limit blank
          for unlimited.
        </p>
        {form.entitlements.map((row, i) => {
          const now = c.entitlements.find((e) => e.in_force && e.entitlement_code === row.code);
          return (
            <div key={i} className="flex flex-wrap items-end gap-2">
              <label className="flex min-w-[10rem] flex-1 flex-col gap-1 text-xs">
                Band
                <select
                  className={INPUT}
                  value={row.code}
                  onChange={(e) =>
                    set(
                      "entitlements",
                      form.entitlements.map((r, n) =>
                        n === i ? { ...r, code: e.target.value } : r,
                      ),
                    )
                  }
                >
                  <option value="">Choose…</option>
                  {kinds.map((k) => (
                    <option key={k.code} value={k.code}>
                      {k.title} ({k.unit})
                    </option>
                  ))}
                </select>
              </label>
              <label className="flex w-36 flex-col gap-1 text-xs">
                New limit
                <input
                  type="number"
                  min={0}
                  className={INPUT}
                  placeholder={
                    now
                      ? now.limit_value == null
                        ? "Unlimited now"
                        : `Now ${now.limit_value}`
                      : "Unlimited"
                  }
                  value={row.limit}
                  onChange={(e) =>
                    set(
                      "entitlements",
                      form.entitlements.map((r, n) =>
                        n === i ? { ...r, limit: e.target.value } : r,
                      ),
                    )
                  }
                />
              </label>
              <button
                type="button"
                className={SECONDARY}
                onClick={() =>
                  set(
                    "entitlements",
                    form.entitlements.filter((_, n) => n !== i),
                  )
                }
              >
                Remove
              </button>
            </div>
          );
        })}
        <button
          type="button"
          className={`${SECONDARY} self-start`}
          onClick={() => set("entitlements", [...form.entitlements, { code: "", limit: "" }])}
        >
          Add a band
        </button>
      </fieldset>

      <fieldset className="flex flex-col gap-2">
        <legend className="text-xs font-medium">Features</legend>
        <p className="text-xs text-muted-foreground">
          {inForceFeatures.length > 0
            ? `In force now beyond the plan: ${inForceFeatures.join(", ")}.`
            : "No feature beyond the plan is in force now."}
        </p>
        <datalist id={featureList}>
          {featureCodes.map((code) => (
            <option key={code} value={code} />
          ))}
        </datalist>
        {form.capabilities.map((row, i) => (
          <div key={i} className="flex flex-wrap items-end gap-2">
            <label className="flex min-w-[10rem] flex-1 flex-col gap-1 text-xs">
              Feature
              <input
                list={featureList}
                className={`${INPUT} font-mono`}
                value={row.code}
                placeholder="Choose or type a feature code"
                onChange={(e) =>
                  set(
                    "capabilities",
                    form.capabilities.map((r, n) => (n === i ? { ...r, code: e.target.value } : r)),
                  )
                }
              />
            </label>
            <label className="flex w-36 flex-col gap-1 text-xs">
              Change
              <select
                className={INPUT}
                value={row.action}
                onChange={(e) =>
                  set(
                    "capabilities",
                    form.capabilities.map((r, n) =>
                      n === i
                        ? { ...r, action: e.target.value === "remove" ? "remove" : "add" }
                        : r,
                    ),
                  )
                }
              >
                <option value="add">Add it</option>
                <option value="remove">Withdraw it</option>
              </select>
            </label>
            <button
              type="button"
              className={SECONDARY}
              onClick={() =>
                set(
                  "capabilities",
                  form.capabilities.filter((_, n) => n !== i),
                )
              }
            >
              Remove
            </button>
          </div>
        ))}
        <button
          type="button"
          className={`${SECONDARY} self-start`}
          onClick={() => set("capabilities", [...form.capabilities, { code: "", action: "add" }])}
        >
          Add a feature change
        </button>
      </fieldset>

      <Field caption="Why (optional)">
        {(id) => (
          <input
            id={id}
            className={INPUT}
            value={why}
            placeholder="Growth at the second site"
            onChange={(e) => setWhy(e.target.value)}
          />
        )}
      </Field>

      {plans.error ? <Fail error={plans.error} /> : null}
      {tried && problem ? (
        <p role="alert" className="text-sm text-destructive">
          {problem}
        </p>
      ) : null}
      {draft.error ? <Fail error={draft.error} /> : null}
      {draft.isSuccess ? (
        <p role="status" className="text-xs text-muted-foreground">
          Drafted. It changes nothing until both sides have signed it, above.
        </p>
      ) : null}
      <button type="submit" className={`${BUTTON} self-start`} disabled={draft.isPending}>
        {draft.isPending ? "Working…" : "Draft the amendment"}
      </button>
    </form>
  );
}
