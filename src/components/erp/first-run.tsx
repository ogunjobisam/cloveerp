import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { CheckCircle2, Circle, Compass } from "lucide-react";

import { friendlyError } from "@/lib/errors";

import { callErp } from "../../lib/erp";
import { useErpAction } from "./action";
import { Prose } from "./page";

/**
 * Role-based first-run guidance (specification v1.2 §22.2).
 *
 * The steps come from erp_ref.first_run_step, each tied to a permission, and
 * erp_first_run_guide() returns only the steps the caller's permissions make
 * theirs: an administrator sees nine guides, a warehouse operative sees one.
 * Progress is per person, so two administrators do not tick each other's
 * steps, and the panel disappears once every step is done.
 */

type Step = {
  guide_code: string;
  seq: number;
  screen_path: string;
  permission_code: string;
  title: string;
  why: string;
  done_at: string | null;
};

const GUIDE_LABELS: Record<string, string> = {
  administrator: "Setting the organisation up",
  finance: "Finance",
  warehouse: "Warehouse",
  sales: "Sales",
  procurement: "Procurement",
  planning: "Planning",
  production: "Production",
  quality: "Quality",
  reporting: "Reporting",
};

function StepRow({ step }: { step: Step }) {
  const mark = useErpAction({
    fn: "erp_mark_first_run_step",
    invalidates: ["erp_first_run_guide"],
  });
  const done = step.done_at !== null;
  const Icon = done ? CheckCircle2 : Circle;

  return (
    <li className="flex items-start gap-3 py-2">
      <button
        type="button"
        onClick={() =>
          mark.mutate({ p_guide_code: step.guide_code, p_seq: step.seq, p_done: !done })
        }
        disabled={mark.isPending}
        aria-pressed={done}
        aria-label={`${done ? "Mark not done" : "Mark done"}: ${step.title}`}
        className={`mt-0.5 shrink-0 rounded-full ${done ? "text-ok" : "text-muted-foreground hover:text-foreground"}`}
      >
        <Icon className="size-5" />
      </button>
      <div className="min-w-0 flex-1">
        <Link
          to={step.screen_path}
          className={`text-sm font-medium underline-offset-2 hover:underline ${done ? "text-muted-foreground line-through" : ""}`}
        >
          {step.seq}. {step.title}
        </Link>
        <p className="mt-0.5 text-xs text-muted-foreground">{step.why}</p>
        {mark.error ? (
          <p role="alert" className="mt-1 text-xs text-destructive">
            {friendlyError(mark.error).title}
          </p>
        ) : null}
      </div>
    </li>
  );
}

export function FirstRun() {
  const guide = useQuery({
    queryKey: ["erp_first_run_guide", {}],
    queryFn: () => callErp<Step[]>("erp_first_run_guide", {}),
  });

  if (guide.isPending) return null;
  if (guide.error) {
    return (
      <section role="alert" className="rounded-2xl border border-border bg-card p-4 sm:p-5">
        <p className="text-sm font-medium text-destructive">First-run guidance did not load.</p>
        <p className="mt-1 text-xs text-muted-foreground">{friendlyError(guide.error).title}</p>
      </section>
    );
  }

  const steps = guide.data ?? [];
  if (steps.length === 0) return null;
  const done = steps.filter((s) => s.done_at !== null).length;
  if (done === steps.length) return null;

  const guides = [...new Set(steps.map((s) => s.guide_code))];

  return (
    <section className="min-w-0 rounded-2xl border border-border bg-card p-4 shadow-[var(--shadow-card)] sm:p-5">
      <div className="flex items-start gap-3">
        <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent">
          <Compass className="size-4.5" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-sm font-semibold">
            Your first steps ({done} of {steps.length} done)
          </h2>
          <Prose className="mt-1 text-xs text-muted-foreground">
            Only the steps your permissions make yours, in the order they are best taken. Ticks are
            your own; nobody else&apos;s progress shows here.
          </Prose>
        </div>
      </div>
      <div className="mt-4 grid gap-4 md:grid-cols-2">
        {guides.map((code) => (
          <div key={code} className="min-w-0 rounded-xl border border-border/70 px-4 py-2">
            <h3 className="pt-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              {GUIDE_LABELS[code] ?? code}
            </h3>
            <ul className="divide-y divide-border/50">
              {steps
                .filter((s) => s.guide_code === code)
                .map((s) => (
                  <StepRow key={`${s.guide_code}-${s.seq}`} step={s} />
                ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  );
}
