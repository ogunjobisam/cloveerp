import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Fragment, useState } from "react";

import { ErrorNote } from "../erp/action";
import { EmptyState, Prose, TOUCH } from "../erp/page";
import { Pill } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * §2 on a screen.
 *
 * The whole point of the capability register is that switching one off is
 * sometimes refused, and the reason is knowable before you try. So this screen
 * never offers an action the database is going to reject: a capability held by
 * live data has its switch disabled and says what holds it, and one whose
 * prerequisite is off says which.
 *
 * The alternative — offer everything, let the refusal explain — reads as the
 * product being obstructive. It is the same information either way; the
 * difference is whether the person finds out before or after they act.
 */

type Related = { code: string; rationale: string; enabled: boolean };
type Held = { table: string; rows: number; rationale: string };
type Period = { enabled: boolean; reason: string | null; from: string; to: string | null };

export type Capability = {
  code: string;
  title: string;
  description: string;
  seq: number;
  enabled: boolean;
  requires: Related[];
  required_by: Related[];
  held_by: Held[];
  history: Period[];
};

export type Preset = {
  code: string;
  title: string;
  description: string;
  capabilities: string[];
};

/** What the door answers with. On a live organisation it is a change set. */
type SwitchResult = {
  route: "direct" | "change_set";
  change_set_id?: string;
  note?: string;
};

export function Capabilities({ mayConfigure }: { mayConfigure: boolean }) {
  const { ui } = useT();
  const qc = useQueryClient();
  const [outcome, setOutcome] = useState<SwitchResult | null>(null);

  const caps = useQuery({
    queryKey: ["erp_capabilities"],
    queryFn: () => callErp<Capability[]>("erp_capabilities", {}),
  });
  const presets = useQuery({
    queryKey: ["erp_presets"],
    queryFn: () => callErp<Preset[]>("erp_presets", {}),
  });

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ["erp_capabilities"] });
    void qc.invalidateQueries({ queryKey: ["erp_change_sets"] });
    void qc.invalidateQueries({ queryKey: ["erp_pack_acceptance"] });
  };

  const flip = useMutation({
    mutationFn: (v: { code: string; enabled: boolean; reason: string }) =>
      callErp<SwitchResult>("erp_set_capability", {
        p_code: v.code,
        p_enabled: v.enabled,
        p_reason: v.reason,
      }),
    onSuccess: (r) => {
      setOutcome(r);
      invalidate();
    },
  });

  const preset = useMutation({
    mutationFn: (code: string) =>
      callErp<SwitchResult>("erp_apply_preset", {
        p_code: code,
        p_reason: `Applied the ${code} preset`,
      }),
    onSuccess: (r) => {
      setOutcome(r);
      invalidate();
    },
  });

  const rows = caps.data ?? [];
  const on = rows.filter((c) => c.enabled).length;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <section className="rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">{ui("Presets")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A preset is a starting selection, not a tier. Anything can be switched individually
            afterwards, and applying one never switches anything off.
          </Prose>
        </header>
        <div className="grid grid-cols-1 gap-3 px-4 py-4 sm:px-5 md:grid-cols-3">
          {(presets.data ?? []).map((p) => (
            <div key={p.code} className="flex flex-col gap-2 rounded-lg border border-border p-3">
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="text-sm font-semibold">{p.title}</h3>
                <span className="text-xs text-muted-foreground">
                  {p.capabilities.length === 0
                    ? "nothing to switch on"
                    : `${p.capabilities.length} features`}
                </span>
              </div>
              <Prose className="text-xs text-muted-foreground">{p.description}</Prose>
              <button
                type="button"
                className={`${TOUCH} mt-auto w-full rounded-md border border-input px-3 text-sm font-medium disabled:opacity-50`}
                disabled={!mayConfigure || preset.isPending || p.capabilities.length === 0}
                onClick={() => preset.mutate(p.code)}
              >
                {preset.isPending ? ui("Working…") : `${ui("Apply")} ${p.title}`}
              </button>
            </div>
          ))}
        </div>
        {preset.error ? (
          <div className="px-4 pb-4 sm:px-5">
            <ErrorNote error={preset.error} />
          </div>
        ) : null}
      </section>

      {outcome ? <SwitchOutcome outcome={outcome} onDismiss={() => setOutcome(null)} /> : null}

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">{ui("Features")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {on} of {rows.length} switched on. Switched off is not merely hidden: the rules behind
            it do not run, so nothing keeps its data correct while it is off — which is why one with
            live data cannot be switched off at all.
          </Prose>
        </header>

        {caps.error ? (
          <div className="px-4 py-4 sm:px-5">
            <ErrorNote error={caps.error} />
          </div>
        ) : caps.isPending ? (
          <p className="px-4 py-6 text-sm text-muted-foreground sm:px-5">Loading…</p>
        ) : rows.length === 0 ? (
          <EmptyState message={ui("No features in the catalogue.")} />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((c) => (
              <CapabilityRow
                key={c.code}
                capability={c}
                mayConfigure={mayConfigure}
                pending={flip.isPending}
                onFlip={(enabled, reason) => flip.mutate({ code: c.code, enabled, reason })}
              />
            ))}
          </ul>
        )}
        {flip.error ? (
          <div className="px-4 pb-4 sm:px-5">
            <ErrorNote error={flip.error} />
          </div>
        ) : null}
      </section>
    </div>
  );
}

/**
 * What happened, in the two forms it can take.
 *
 * On an organisation that has not gone live the switch is immediate. On a live
 * one it prepares a change, because §2.1 says a capability is switched through
 * one — and a screen that said "done" over an unpromoted change would be lying
 * about whether the rules are running.
 */
function SwitchOutcome({ outcome, onDismiss }: { outcome: SwitchResult; onDismiss: () => void }) {
  const isChangeSet = outcome.route === "change_set";
  return (
    <div
      className={`rounded-xl border p-4 text-sm sm:p-5 ${
        isChangeSet
          ? "border-amber-500/40 bg-amber-500/5"
          : "border-emerald-500/40 bg-emerald-500/5"
      }`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="font-medium">
            {isChangeSet ? "A change is waiting to be promoted" : "Switched"}
          </p>
          <Prose className="mt-1 text-xs text-muted-foreground">
            {outcome.note ??
              "This organisation has not gone live, so the switch took effect immediately."}
          </Prose>
          {isChangeSet ? (
            <p className="mt-2 text-xs text-muted-foreground">
              Preview and promote it on{" "}
              <a className="underline" href="/administration/configuration">
                Configuration
              </a>
              . Nothing has changed until you do.
            </p>
          ) : null}
        </div>
        <button
          type="button"
          className="shrink-0 text-xs text-muted-foreground underline"
          onClick={onDismiss}
        >
          Dismiss
        </button>
      </div>
    </div>
  );
}

function CapabilityRow({
  capability: c,
  mayConfigure,
  pending,
  onFlip,
}: {
  capability: Capability;
  mayConfigure: boolean;
  pending: boolean;
  onFlip: (enabled: boolean, reason: string) => void;
}) {
  const { ui } = useT();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  const missing = c.requires.filter((d) => !d.enabled);
  const dependents = c.required_by.filter((d) => d.enabled);

  // Why the switch cannot move, in the order the database would refuse.
  const blocked = c.enabled
    ? c.held_by.length > 0
      ? `${c.held_by.map((h) => `${h.table} holds ${h.rows}`).join(", ")} — switching off would leave those rows unmaintained`
      : dependents.length > 0
        ? `${dependents.map((d) => d.code).join(", ")} still depend on it`
        : null
    : missing.length > 0
      ? `needs ${missing.map((d) => d.code).join(", ")} first`
      : null;

  return (
    <li className="px-4 py-3 sm:px-5">
      <div className="flex flex-wrap items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-medium">{c.title}</span>
            <Pill tone={c.enabled ? "ok" : "muted"}>{c.enabled ? ui("on") : ui("off")}</Pill>
            {blocked ? <Pill tone="warn">{ui("held")}</Pill> : null}
          </div>
          <Prose className="mt-0.5 text-xs text-muted-foreground">{c.description}</Prose>
          {blocked ? (
            <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">{blocked}</p>
          ) : null}
        </div>

        <div className="flex shrink-0 items-center gap-2">
          {c.requires.length > 0 || c.required_by.length > 0 || c.history.length > 0 ? (
            <button
              type="button"
              className="text-xs text-muted-foreground underline"
              onClick={() => setOpen((v) => !v)}
            >
              {open ? ui("Less") : ui("Why")}
            </button>
          ) : null}
          <button
            type="button"
            className={`${TOUCH} rounded-md border border-input px-3 text-sm font-medium disabled:opacity-40`}
            disabled={!mayConfigure || pending || blocked !== null}
            title={blocked ?? undefined}
            onClick={() =>
              onFlip(
                !c.enabled,
                reason || `${c.enabled ? "Switched off" : "Switched on"} from the features screen`,
              )
            }
          >
            {c.enabled ? ui("Switch off") : ui("Switch on")}
          </button>
        </div>
      </div>

      {open ? (
        <div className="mt-3 grid grid-cols-1 gap-3 rounded-lg bg-muted/40 p-3 text-xs sm:grid-cols-3">
          <Related title={ui("Needs")} items={c.requires} empty={ui("Nothing.")} />
          <Related
            title={ui("Needed by")}
            items={c.required_by}
            empty={ui("Nothing depends on it.")}
          />
          <div className="min-w-0">
            <p className="font-medium">{ui("History")}</p>
            {c.history.length === 0 ? (
              <p className="mt-1 text-muted-foreground">{ui("Never switched.")}</p>
            ) : (
              <ul className="mt-1 space-y-0.5 text-muted-foreground">
                {c.history.slice(0, 4).map((h) => (
                  <li key={`${h.from}-${String(h.enabled)}`}>
                    {h.enabled ? "on" : "off"} from {h.from}
                    {h.reason ? ` — ${h.reason}` : ""}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </div>
      ) : null}

      {open && mayConfigure ? (
        <label className="mt-2 block text-xs">
          <span className="text-muted-foreground">{ui("Reason (recorded with the switch)")}</span>
          <input
            className={`${TOUCH} mt-1 w-full rounded-md border border-input px-3 text-sm`}
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Why this is changing"
          />
        </label>
      ) : null}
    </li>
  );
}

function Related({ title, items, empty }: { title: string; items: Related[]; empty: string }) {
  return (
    <div className="min-w-0">
      <p className="font-medium">{title}</p>
      {items.length === 0 ? (
        <p className="mt-1 text-muted-foreground">{empty}</p>
      ) : (
        <ul className="mt-1 space-y-1 text-muted-foreground">
          {items.map((d) => (
            <Fragment key={d.code}>
              <li>
                <span className={d.enabled ? "text-foreground" : ""}>{d.code}</span>
                {d.enabled ? "" : " (off)"} — {d.rationale}
              </li>
            </Fragment>
          ))}
        </ul>
      )}
    </div>
  );
}
