import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useState } from "react";
import { ArrowRight, Check, ChevronDown, Circle, Compass, Eye } from "lucide-react";

import { friendlyError } from "@/lib/errors";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { useErpAction } from "./action";
import { Prose, TOUCH } from "./page";

/**
 * Role-based first-run guidance (specification v1.5 §22.2).
 *
 * The steps come from erp_ref.first_run_step, each tied to a permission, and
 * erp_first_run_guide() returns only the steps the caller's permissions make
 * theirs. Progress is per person, so two administrators do not tick each
 * other's steps, and the panel disappears once every step is complete.
 *
 * Two things this screen used to get wrong, both fixed in the database first:
 *
 *   - It rendered all thirty steps across nine guides at once. Now it shows
 *     the next incomplete step, and folds the rest behind a count. A checklist
 *     that cannot be scanned is not a checklist.
 *   - The only action was a hyperlink on the title, and the only completion
 *     was a self-reported tick. Now each step names the action it opens
 *     (`action_label`), and twenty-eight of the thirty carry `satisfied` and
 *     `evidence` — read from the organisation's own tables, not from what
 *     somebody remembered to tick.
 *
 * `complete` is the database's word, not a sum computed here: evidence, or a
 * tick, or a dismissal. The tick stays available on an observed step because
 * the platform may be looking at the wrong thing, and the person is allowed to
 * say so.
 */

type Step = {
  guide_code: string;
  guide_name: string;
  guide_seq: number;
  seq: number;
  screen_path: string;
  permission_code: string;
  title: string;
  why: string;
  action_label: string;
  observable: boolean;
  satisfied: boolean;
  evidence: string | null;
  done_at: string | null;
  dismissed_at: string | null;
  complete: boolean;
};

const INVALIDATES = ["erp_first_run_guide"];

/** The step's own controls: go and do it, or say something about it. */
function StepActions({ step, primary }: { step: Step; primary: boolean }) {
  const { ui } = useT();
  const mark = useErpAction({ fn: "erp_mark_first_run_step", invalidates: INVALIDATES });
  const dismiss = useErpAction({ fn: "erp_dismiss_first_run_step", invalidates: INVALIDATES });
  const busy = mark.isPending || dismiss.isPending;
  const error = mark.error ?? dismiss.error;
  const args = { p_guide_code: step.guide_code, p_seq: step.seq };

  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-center gap-2">
        <Link
          to={step.screen_path}
          className={`${TOUCH} inline-flex shrink-0 items-center gap-1.5 rounded-md px-4 text-sm ${
            primary
              ? "bg-primary font-semibold text-primary-foreground"
              : "border border-input font-medium"
          }`}
        >
          {ui(step.action_label)}
          <ArrowRight className="size-4" aria-hidden="true" />
        </Link>

        {/* Not offered on a step the platform can already see is done — there
            is nothing for a tick to add to evidence. Offered on one it says is
            not done, because the evidence may be looking at the wrong thing. */}
        {!step.satisfied ? (
          <button
            type="button"
            onClick={() => mark.mutate({ ...args, p_done: step.done_at === null })}
            disabled={busy}
            aria-pressed={step.done_at !== null}
            className={`${TOUCH} inline-flex shrink-0 items-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium disabled:opacity-50`}
          >
            <Check className="size-4" aria-hidden="true" />
            {step.done_at !== null ? ui("Done") : ui("Mark done")}
          </button>
        ) : null}

        <button
          type="button"
          onClick={() => dismiss.mutate({ ...args, p_dismissed: step.dismissed_at === null })}
          disabled={busy}
          aria-pressed={step.dismissed_at !== null}
          className={`${TOUCH} inline-flex shrink-0 items-center rounded-md px-3 text-sm text-muted-foreground underline-offset-2 hover:underline disabled:opacity-50`}
        >
          {step.dismissed_at !== null ? ui("Bring this back") : ui("Not for us")}
        </button>
      </div>

      {error ? (
        <p role="alert" className="mt-2 text-xs text-destructive">
          {friendlyError(error).title}
        </p>
      ) : null}
    </div>
  );
}

/**
 * What the platform can see, in its own words.
 *
 * An observed step says what was counted whether or not it passed, because
 * "no module has been installed yet" is the more useful half of the sentence
 * when the step is not done.
 */
function Evidence({ step }: { step: Step }) {
  const { ui } = useT();
  if (step.dismissed_at !== null)
    return <span className="text-muted-foreground">{ui("Set aside as not applying here.")}</span>;
  if (!step.observable) {
    return (
      <span className="text-muted-foreground">
        {ui("Nothing records that somebody read a screen, so this one is yours to tick.")}
      </span>
    );
  }
  return (
    <span className={step.satisfied ? "text-ok" : "text-muted-foreground"}>
      <Eye className="mr-1 inline size-3.5 align-[-2px]" aria-hidden="true" />
      {step.evidence ?? ""}
    </span>
  );
}

/** One row in the folded list. */
function StepRow({ step }: { step: Step }) {
  const { ui } = useT();
  const [open, setOpen] = useState(false);
  const Icon = step.complete ? Check : Circle;

  return (
    <li className="border-t border-border/50 first:border-t-0">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="flex w-full items-start gap-3 py-3 text-left"
      >
        <Icon
          className={`mt-0.5 size-4.5 shrink-0 ${step.complete ? "text-ok" : "text-muted-foreground"}`}
          aria-hidden="true"
        />
        <span className="min-w-0 flex-1">
          <span
            className={`block text-sm font-medium ${step.complete ? "text-muted-foreground line-through" : ""}`}
          >
            {step.title}
          </span>
          <span className="mt-0.5 block text-xs">
            <Evidence step={step} />
          </span>
        </span>
        <ChevronDown
          className={`mt-0.5 size-4 shrink-0 text-muted-foreground transition-transform ${open ? "rotate-180" : ""}`}
          aria-hidden="true"
        />
      </button>
      {open ? (
        <div className="pb-3 pl-7.5">
          <Prose className="mb-3 text-xs text-muted-foreground">{ui(step.why)}</Prose>
          <StepActions step={step} primary={false} />
        </div>
      ) : null}
    </li>
  );
}

export function FirstRun() {
  const { ui } = useT();
  const [showAll, setShowAll] = useState(false);
  const guide = useQuery({
    queryKey: ["erp_first_run_guide", {}],
    queryFn: () => callErp<Step[]>("erp_first_run_guide", {}),
  });

  if (guide.isPending) return null;
  if (guide.error) {
    return (
      <section role="alert" className="rounded-2xl border border-border bg-card p-4 sm:p-5">
        <p className="text-sm font-medium text-destructive">
          {ui("First-run guidance did not load.")}
        </p>
        <p className="mt-1 text-xs text-muted-foreground">{friendlyError(guide.error).title}</p>
      </section>
    );
  }

  const steps = guide.data ?? [];
  if (steps.length === 0) return null;
  const done = steps.filter((s) => s.complete).length;
  if (done === steps.length) return null;

  // Guide order is the database's, and so is the order within a guide, so the
  // first incomplete step is the next one to take.
  const next = steps.find((s) => !s.complete)!;
  const rest = steps.filter((s) => s !== next);
  const guides = [...new Set(rest.map((s) => s.guide_code))];
  const pct = Math.round((done / steps.length) * 100);

  return (
    <section className="min-w-0 rounded-2xl border border-border bg-card p-4 shadow-[var(--shadow-card)] sm:p-5">
      <div className="flex items-start gap-3">
        <span className="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/15 text-accent">
          <Compass className="size-4.5" aria-hidden="true" />
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="font-display text-sm font-semibold">
            {ui("Your first steps")}{" "}
            <span className="font-normal text-muted-foreground">
              ({done} {ui("of")} {steps.length})
            </span>
          </h2>
          <Prose className="mt-1 text-xs text-muted-foreground">
            {ui(
              "Only the steps your permissions make yours. Most tick themselves as you work — the platform reads its own records rather than asking you to remember.",
            )}
          </Prose>
        </div>
      </div>

      {/* Progress as a fact rather than decoration: the same two numbers the
          heading carries, for people who read the shape before the text. */}
      <div
        className="mt-3 h-1.5 overflow-hidden rounded-full bg-muted"
        role="progressbar"
        aria-valuenow={done}
        aria-valuemin={0}
        aria-valuemax={steps.length}
        aria-label={ui("First steps completed")}
      >
        <div
          className="h-full rounded-full bg-ok transition-[width]"
          style={{ width: `${pct}%` }}
        />
      </div>

      {/* The next step, in full. One thing to do, not thirty. */}
      <div className="mt-4 rounded-xl border border-accent/30 bg-accent/5 p-4">
        <p className="text-[11px] font-semibold uppercase tracking-wide text-accent">
          {ui("Next")} · {next.guide_name}
        </p>
        <h3 className="mt-1 font-display text-base font-semibold">{next.title}</h3>
        <Prose className="mt-1 text-xs text-muted-foreground">{ui(next.why)}</Prose>
        <p className="mt-2 text-xs">
          <Evidence step={next} />
        </p>
        <div className="mt-3">
          <StepActions step={next} primary />
        </div>
      </div>

      {rest.length > 0 ? (
        <>
          <button
            type="button"
            onClick={() => setShowAll((v) => !v)}
            aria-expanded={showAll}
            className={`${TOUCH} mt-3 flex w-full items-center justify-between gap-2 rounded-md px-1 text-sm font-medium`}
          >
            <span>
              {showAll ? ui("Hide the rest") : `${rest.length} ${ui("more steps")}`}
              {done > 0 ? (
                <span className="ml-2 font-normal text-muted-foreground">
                  {done} {ui("already done")}
                </span>
              ) : null}
            </span>
            <ChevronDown
              className={`size-4 shrink-0 text-muted-foreground transition-transform ${showAll ? "rotate-180" : ""}`}
              aria-hidden="true"
            />
          </button>

          {showAll ? (
            <div className="mt-1 grid gap-4 md:grid-cols-2">
              {guides.map((code) => {
                const inGuide = rest.filter((s) => s.guide_code === code);
                const guideDone = inGuide.filter((s) => s.complete).length;
                return (
                  <div key={code} className="min-w-0 rounded-xl border border-border/70 px-4 py-2">
                    <h3 className="flex items-baseline justify-between gap-2 pt-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                      <span className="min-w-0 truncate">{inGuide[0]?.guide_name ?? code}</span>
                      <span className="shrink-0 font-normal normal-case tracking-normal">
                        {guideDone}/{inGuide.length}
                      </span>
                    </h3>
                    <ul>
                      {inGuide.map((s) => (
                        <StepRow key={`${s.guide_code}-${s.seq}`} step={s} />
                      ))}
                    </ul>
                  </div>
                );
              })}
            </div>
          ) : null}
        </>
      ) : null}
    </section>
  );
}
