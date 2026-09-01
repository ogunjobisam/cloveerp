import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";

import { ErrorNote } from "../erp/action";
import { EmptyState, Prose, TOUCH } from "../erp/page";
import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * §11 on a screen, in the order §11 states it.
 *
 *   1  select a preset          — the features screen
 *   2  generate a change set    — Plan, then Build
 *   3  conflicts surface first  — shown before Build is offered
 *   4  decisions, and promotion refuses while any remain
 *   5  preview the diff, promote
 *   6  the organisation records what it holds
 *
 * Nothing here promotes. Preparing a change and landing it are two acts with
 * two permissions and, on a live organisation, two people — and a screen that
 * collapsed them into one button would be working around the mechanism this
 * product is built on rather than through it.
 *
 * The button says "Prepare the change", not "Build the change set", because
 * Terminology §4 puts change set on the never-on-a-screen list — and
 * erp.assert_vocabulary_aligned() refused the migration seeding this screen's
 * wording until it did.
 */

type Applied = {
  version: string;
  status: string;
  items: number;
  applied_at: string | null;
};

export type Pack = {
  code: string;
  name: string;
  description: string;
  kind: "base" | "profile";
  version: string;
  requires_capability: string | null;
  provenance: string;
  items: number;
  decisions: number;
  applied: Applied[] | null;
};

type Conflict = { severity: "blocking" | "advisory"; conflict: string; reference: string };
type Decision = {
  object_kind: string;
  object_key: string;
  prompt: string;
  answered: boolean;
  answer: Record<string, unknown> | null;
};
type PlanItem = {
  object_kind: string;
  object_key: string;
  effect: string;
  is_decision: boolean;
};
type Plan = { pack: string; conflicts: Conflict[]; decisions: Decision[]; items: PlanItem[] };

export function Packs({ mayConfigure }: { mayConfigure: boolean }) {
  const { ui } = useT();
  const [open, setOpen] = useState<string | null>(null);
  const packs = useQuery({
    queryKey: ["erp_content_packs"],
    queryFn: () => callErp<Pack[]>("erp_content_packs", {}),
  });

  const rows = packs.data ?? [];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">{ui("Content packs")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A pack does not write rows. It prepares a change containing everything its selection
            implies and nothing this organisation already holds — so applying one twice is safe, and
            re-applying after switching a feature on brings only what that feature unlocked.
          </Prose>
        </header>

        {packs.error ? (
          <div className="px-4 py-4 sm:px-5">
            <ErrorNote error={packs.error} />
          </div>
        ) : packs.isPending ? (
          <p className="px-4 py-6 text-sm text-muted-foreground sm:px-5">Loading…</p>
        ) : rows.length === 0 ? (
          <EmptyState message={ui("No packs are published.")} />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((p) => (
              <PackRow
                key={p.code}
                pack={p}
                mayConfigure={mayConfigure}
                open={open === p.code}
                onToggle={() => setOpen(open === p.code ? null : p.code)}
              />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

function PackRow({
  pack: p,
  mayConfigure,
  open,
  onToggle,
}: {
  pack: Pack;
  mayConfigure: boolean;
  open: boolean;
  onToggle: () => void;
}) {
  const { ui } = useT();
  const applied = (p.applied ?? []).filter((a) => a.status === "applied");
  const latest = applied[0];

  return (
    <li className="px-4 py-3 sm:px-5">
      <div className="flex flex-wrap items-start gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-medium">{p.name}</span>
            <Pill tone={p.kind === "base" ? "ok" : "muted"}>{p.kind}</Pill>
            <span className="font-mono text-xs text-muted-foreground">{p.version}</span>
            {latest ? (
              <Pill tone="ok">applied {latest.version}</Pill>
            ) : (
              <Pill tone="muted">{ui("not applied")}</Pill>
            )}
          </div>
          <Prose className="mt-0.5 text-xs text-muted-foreground">{p.description}</Prose>
          <p className="mt-1 text-xs text-muted-foreground">
            {p.items} items
            {p.decisions > 0 ? `, ${p.decisions} of them decisions you have to make` : ""}
            {p.requires_capability ? ` · needs the ${p.requires_capability} feature` : ""}
          </p>
        </div>
        <button
          type="button"
          className={`${TOUCH} shrink-0 rounded-md border border-input px-3 text-sm font-medium`}
          onClick={onToggle}
        >
          {open ? ui("Close") : ui("Plan")}
        </button>
      </div>
      {open ? <PackPlan pack={p} mayConfigure={mayConfigure} /> : null}
    </li>
  );
}

/**
 * §11 steps 3, 4 and 7 in one read, then step 2 as a button.
 *
 * The plan is fetched before anything is offered, so a blocking conflict hides
 * Build rather than letting somebody press it and read a refusal.
 */
function PackPlan({ pack, mayConfigure }: { pack: Pack; mayConfigure: boolean }) {
  const { ui } = useT();
  const qc = useQueryClient();
  const [built, setBuilt] = useState<{ change_set_code: string; items: number } | null>(null);

  const plan = useQuery({
    queryKey: ["erp_pack_plan", { p_pack_code: pack.code }],
    queryFn: () => callErp<Plan>("erp_pack_plan", { p_pack_code: pack.code }),
  });

  const answer = useMutation({
    mutationFn: (v: { kind: string; key: string; value: string }) =>
      callErp("erp_answer_pack_decision", {
        p_pack_code: pack.code,
        p_object_kind: v.kind,
        p_object_key: v.key,
        p_answer: { upper_bound_minor: Number(v.value) },
      }),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["erp_pack_plan", { p_pack_code: pack.code }] });
    },
  });

  const build = useMutation({
    mutationFn: () =>
      callErp<{ change_set_code: string; items: number }>("erp_apply_content_pack", {
        p_pack_code: pack.code,
      }),
    onSuccess: (r) => {
      setBuilt(r);
      void qc.invalidateQueries({ queryKey: ["erp_content_packs"] });
      void qc.invalidateQueries({ queryKey: ["erp_change_sets"] });
    },
  });

  if (plan.error) return <ErrorNote error={plan.error} />;
  if (plan.isPending) {
    return <p className="mt-3 text-sm text-muted-foreground">Working out what this would do…</p>;
  }

  const d = plan.data;
  const blocking = d.conflicts.filter((c) => c.severity === "blocking");
  const advisory = d.conflicts.filter((c) => c.severity === "advisory");
  const openDecisions = d.decisions.filter((x) => !x.answered);

  return (
    <div className="mt-3 flex flex-col gap-3 rounded-lg bg-muted/40 p-3">
      {blocking.length > 0 ? (
        <div className="rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm">
          <p className="font-medium text-destructive">
            {ui("This pack cannot be applied as it stands")}
          </p>
          <ul className="mt-1 list-disc pl-5 text-xs text-muted-foreground">
            {blocking.map((c) => (
              <li key={c.conflict}>{c.conflict}</li>
            ))}
          </ul>
        </div>
      ) : null}

      {advisory.length > 0 ? (
        <div className="rounded-md border border-border p-3 text-xs text-muted-foreground">
          <p className="font-medium text-foreground">{ui("Held back")}</p>
          <ul className="mt-1 list-disc pl-5">
            {advisory.map((c) => (
              <li key={c.conflict}>{c.conflict}</li>
            ))}
          </ul>
          <p className="mt-1">
            Not an error — switch the feature on and apply the pack again to bring these in.
          </p>
        </div>
      ) : null}

      {d.decisions.length > 0 ? (
        <div className="rounded-md border border-border bg-card p-3">
          <p className="text-sm font-medium">
            Decisions{" "}
            {openDecisions.length > 0 ? `— ${openDecisions.length} still open` : "— all answered"}
          </p>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            The pack will not guess these. Promotion is refused while any remain, because a value
            invented on your behalf looks configured and is not.
          </Prose>
          <ul className="mt-2 space-y-2">
            {d.decisions.map((x) => (
              <DecisionRow
                key={`${x.object_kind}|${x.object_key}`}
                decision={x}
                mayConfigure={mayConfigure}
                pending={answer.isPending}
                onAnswer={(value) =>
                  answer.mutate({ kind: x.object_kind, key: x.object_key, value })
                }
              />
            ))}
          </ul>
          {answer.error ? <ErrorNote error={answer.error} /> : null}
        </div>
      ) : null}

      <div className="min-w-0">
        <p className="text-sm font-medium">
          {d.items.length === 0
            ? "Nothing to add — this organisation already holds everything this pack provides"
            : `${d.items.length} item${d.items.length === 1 ? "" : "s"} would be added or updated`}
        </p>
        {d.items.length > 0 ? (
          <div className="mt-2 max-h-64 overflow-auto">
            <Table columns={[ui("Kind"), ui("Object"), ui("Effect")]}>
              {d.items.slice(0, 200).map((it) => (
                <tr key={`${it.object_kind}|${it.object_key}`} className="border-t border-border">
                  <td className="px-3 py-1.5 text-xs">{it.object_kind}</td>
                  <td className="px-3 py-1.5 font-mono text-xs">{it.object_key}</td>
                  <td className="px-3 py-1.5 text-xs">
                    <Pill tone={it.effect === "creates" ? "ok" : "muted"}>{it.effect}</Pill>
                  </td>
                </tr>
              ))}
            </Table>
            {d.items.length > 200 ? (
              <p className="px-3 py-1 text-xs text-muted-foreground">
                Showing the first 200. The change set carries all {d.items.length}.
              </p>
            ) : null}
          </div>
        ) : null}
      </div>

      {built ? (
        <div className="rounded-md border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
          <p className="font-medium">
            Change {built.change_set_code} prepared, with {built.items} items
          </p>
          <p className="mt-1 text-xs text-muted-foreground">
            Nothing has changed yet. Approve and promote it on{" "}
            <a className="underline" href="/administration/configuration">
              Configuration
            </a>
            , where the diff and the rollback point live.
          </p>
        </div>
      ) : null}

      {build.error ? <ErrorNote error={build.error} /> : null}

      <button
        type="button"
        className={`${TOUCH} w-fit rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground disabled:opacity-50`}
        disabled={!mayConfigure || blocking.length > 0 || d.items.length === 0 || build.isPending}
        onClick={() => build.mutate()}
      >
        {build.isPending ? ui("Building…") : ui("Prepare the change")}
      </button>
    </div>
  );
}

function DecisionRow({
  decision,
  mayConfigure,
  pending,
  onAnswer,
}: {
  decision: Decision;
  mayConfigure: boolean;
  pending: boolean;
  onAnswer: (value: string) => void;
}) {
  const { ui } = useT();
  const [value, setValue] = useState("");
  const current = decision.answer?.["upper_bound_minor"];

  return (
    <li className="rounded-md border border-border p-2">
      <p className="text-xs">{decision.prompt}</p>
      <p className="mt-0.5 font-mono text-[11px] text-muted-foreground">{decision.object_key}</p>
      <div className="mt-1 flex flex-wrap items-center gap-2">
        {decision.answered ? (
          <Pill tone="ok">answered: {String(current ?? "")}</Pill>
        ) : (
          <Pill tone="warn">{ui("open")}</Pill>
        )}
        <input
          className={`${TOUCH} w-40 rounded-md border border-input px-2 text-sm`}
          inputMode="numeric"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="e.g. 500000"
          disabled={!mayConfigure}
        />
        <button
          type="button"
          className={`${TOUCH} rounded-md border border-input px-3 text-sm font-medium disabled:opacity-50`}
          disabled={!mayConfigure || pending || value.trim() === ""}
          onClick={() => onAnswer(value.trim())}
        >
          {decision.answered ? ui("Change") : ui("Answer")}
        </button>
      </div>
    </li>
  );
}
