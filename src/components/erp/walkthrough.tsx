import { useQuery } from "@tanstack/react-query";
import { Link, useRouterState } from "@tanstack/react-router";
import { ArrowRight, Check, Circle, Compass, EyeOff, Lock, RefreshCw } from "lucide-react";
import { useState } from "react";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { friendlyError } from "@/lib/errors";
import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  nextScreen,
  nextStep,
  settingsScreenFor,
  stepState,
  type SetupScreenProgress,
  type Walkthrough,
  type WalkthroughStep,
} from "../../lib/walkthrough";
import { useErpAction } from "./action";
import { hasActionOpener, openAction } from "./action-registry";

/**
 * The Settings walkthrough (specification Part 22).
 *
 * One button on every Settings screen, big enough to see, that opens the
 * screen's steps in the order they are taken: what to do, why, the form it
 * opens, whether the organisation's own tables say it is done, and what on
 * other screens has to exist first. The steps come from erp_ref.setup_step
 * through erp_setup_walkthrough(); the evidence beside each is read from the
 * organisation, not from a tick somebody remembered.
 *
 * The button opens the form rather than pointing at it, through the action
 * registry: a dialog on the page that drives the step's door answers to its
 * name. Where the form is hand-rolled and does not register, the step names
 * the action and leaves the finding to the person.
 *
 * Ticks and "not for us" belong to the organisation, because a company either
 * exists or it does not, whoever is looking.
 */

const TOUCH = "min-h-11";
const INVALIDATES = ["erp_setup_walkthrough", "erp_setup_progress"];

function useWalkthrough(path: string | null, enabled: boolean) {
  return useQuery({
    queryKey: ["erp_setup_walkthrough", { p_screen_path: path }],
    queryFn: () => callErp<Walkthrough>("erp_setup_walkthrough", { p_screen_path: path }),
    enabled: enabled && path !== null,
  });
}

/** The button in the page header, and the sheet it opens. */
export function WalkthroughButton() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const path = settingsScreenFor(pathname);
  const { ui } = useT();
  const [open, setOpen] = useState(false);
  const walk = useWalkthrough(path, open);

  if (!path) return null;

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-expanded={open}
        className={`${TOUCH} inline-flex shrink-0 items-center gap-2 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground hover:bg-primary/90`}
      >
        <Compass className="size-4" aria-hidden="true" />
        {ui("Walkthrough")}
      </button>

      <Sheet open={open} onOpenChange={setOpen}>
        <SheetContent
          side="right"
          className="flex w-[92vw] max-w-lg flex-col gap-4 overflow-y-auto"
        >
          <SheetTitle className="text-base">
            {ui("Walkthrough")}
            {walk.data?.screen ? ` · ${walk.data.screen.title}` : ""}
          </SheetTitle>
          <SheetDescription className="text-xs text-muted-foreground">
            {walk.data?.screen?.blurb ??
              ui("The steps on this screen, in the order they are taken.")}
          </SheetDescription>

          {walk.isPending ? (
            <p role="status" className="text-sm text-muted-foreground">
              {ui("Loading…")}
            </p>
          ) : walk.error ? (
            <div role="alert">
              <p className="text-sm font-medium text-destructive">{ui("This did not load.")}</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {friendlyError(walk.error).title}
              </p>
            </div>
          ) : !walk.data?.screen ? (
            <p className="text-sm text-muted-foreground">
              {ui("This screen is not in the setup order.")}
            </p>
          ) : (
            <WalkthroughBody
              data={walk.data}
              onOpened={() => setOpen(false)}
              onRefresh={() => void walk.refetch()}
              refreshing={walk.isFetching}
            />
          )}
        </SheetContent>
      </Sheet>
    </>
  );
}

function WalkthroughBody({
  data,
  onOpened,
  onRefresh,
  refreshing,
}: {
  data: Walkthrough;
  onOpened: () => void;
  onRefresh: () => void;
  refreshing: boolean;
}) {
  const { ui } = useT();
  const screen = data.screen;
  if (!screen) return null;
  const steps = [...data.steps].sort((a, b) => a.seq - b.seq);
  const next = nextStep(steps);
  const complete = steps.filter((s) => s.complete).length;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
        <span>
          {ui("Setup order")}: {screen.seq} / {screen.screens}
        </span>
        <span>
          {complete} / {steps.length} {ui("done")}
        </span>
        <button
          type="button"
          onClick={onRefresh}
          className="inline-flex items-center gap-1 rounded-md border border-input px-2 py-1 hover:bg-muted"
        >
          <RefreshCw className={`size-3 ${refreshing ? "animate-spin" : ""}`} aria-hidden="true" />
          {ui("Refresh")}
        </button>
      </div>

      <ol className="flex flex-col gap-3">
        {steps.map((step) => (
          <StepCard key={step.code} step={step} next={next} onOpened={onOpened} />
        ))}
      </ol>

      <nav className="flex flex-wrap items-center justify-between gap-2 border-t border-border pt-3 text-sm">
        {screen.previous ? (
          <Link to={screen.previous.screen_path} className="underline" onClick={onOpened}>
            ← {ui("Previous screen")}: {screen.previous.title}
          </Link>
        ) : (
          <span />
        )}
        {screen.next ? (
          <Link to={screen.next.screen_path} className="underline" onClick={onOpened}>
            {ui("Next screen")}: {screen.next.title} →
          </Link>
        ) : null}
      </nav>
      <Link to="/settings" className="text-xs text-muted-foreground underline" onClick={onOpened}>
        {ui("All screens, in order")}
      </Link>
    </div>
  );
}

function StepCard({
  step,
  next,
  onOpened,
}: {
  step: WalkthroughStep;
  next: WalkthroughStep | null;
  onOpened: () => void;
}) {
  const { ui } = useT();
  const state = stepState(step, next);
  const mark = useErpAction({ fn: "erp_mark_setup_step", invalidates: INVALIDATES });
  const dismiss = useErpAction({ fn: "erp_dismiss_setup_step", invalidates: INVALIDATES });
  const busy = mark.isPending || dismiss.isPending;
  const error = mark.error ?? dismiss.error;
  const canOpen = step.action_fn !== null && hasActionOpener(step.action_fn);

  const ring =
    state === "next"
      ? "border-primary ring-1 ring-primary"
      : state === "done"
        ? "border-border bg-muted/40"
        : "border-border";

  return (
    <li className={`rounded-lg border p-3 ${ring}`}>
      <div className="flex items-start gap-3">
        <span className="mt-0.5 shrink-0" aria-hidden="true">
          {state === "done" ? (
            <Check className="size-4 text-emerald-600" />
          ) : state === "aside" ? (
            <EyeOff className="size-4 text-muted-foreground" />
          ) : state === "waiting" ? (
            <Lock className="size-4 text-muted-foreground" />
          ) : (
            <Circle
              className={`size-4 ${state === "next" ? "text-primary" : "text-muted-foreground"}`}
            />
          )}
        </span>
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium">
            {step.seq}. {step.title}
          </p>
          <p className="mt-0.5 text-xs text-muted-foreground">{step.why}</p>

          <p className="mt-1.5 text-xs">
            {state === "done" && step.satisfied && step.evidence ? (
              <span className="text-emerald-700">{step.evidence}</span>
            ) : state === "done" ? (
              <span className="text-emerald-700">{ui("Ticked as done")}</span>
            ) : state === "aside" ? (
              <span className="text-muted-foreground">{ui("Set aside as not applying")}</span>
            ) : step.evidence ? (
              <span className="text-muted-foreground">{step.evidence}</span>
            ) : null}
          </p>

          {step.requires.length > 0 && state === "waiting" ? (
            <p className="mt-1 text-xs text-muted-foreground">
              {ui("Waiting on")}:{" "}
              {step.requires
                .filter((r) => !r.complete)
                .map((r, i) => (
                  <span key={r.code}>
                    {i > 0 ? ", " : ""}
                    <Link to={r.screen_path} className="underline" onClick={onOpened}>
                      {r.title}
                    </Link>
                  </span>
                ))}
            </p>
          ) : null}

          {!step.permitted ? (
            <p className="mt-1 text-xs text-muted-foreground">
              {ui("Not yours to take")} · <span className="font-mono">{step.permission_code}</span>
            </p>
          ) : null}

          <div className="mt-2 flex flex-wrap items-center gap-2">
            {canOpen && step.permitted && state !== "done" ? (
              <button
                type="button"
                onClick={() => {
                  if (step.action_fn && openAction(step.action_fn)) onOpened();
                }}
                className={`${TOUCH} inline-flex items-center gap-1.5 rounded-md px-3 text-sm ${
                  state === "next"
                    ? "bg-primary font-semibold text-primary-foreground"
                    : "border border-input font-medium"
                }`}
              >
                {step.action_label}
                <ArrowRight className="size-4" aria-hidden="true" />
              </button>
            ) : state !== "done" ? (
              <span className="text-xs text-muted-foreground">
                {ui("On this screen")}: {step.action_label}
              </span>
            ) : null}

            {step.permitted && !step.satisfied ? (
              <button
                type="button"
                disabled={busy}
                onClick={() => mark.mutate({ p_code: step.code, p_done: step.done_at === null })}
                className={`${TOUCH} rounded-md border border-input px-3 text-sm`}
              >
                {step.done_at ? ui("Undo") : ui("Mark done")}
              </button>
            ) : null}

            {step.permitted && !step.satisfied ? (
              <button
                type="button"
                disabled={busy}
                onClick={() =>
                  dismiss.mutate({ p_code: step.code, p_dismissed: step.dismissed_at === null })
                }
                className={`${TOUCH} rounded-md px-3 text-sm text-muted-foreground underline`}
              >
                {step.dismissed_at ? ui("Bring back") : ui("Not for us")}
              </button>
            ) : null}
          </div>

          {error ? (
            <p role="alert" className="mt-1 text-xs text-destructive">
              {friendlyError(error).title}
            </p>
          ) : null}
        </div>
      </div>
    </li>
  );
}

/** The Settings home: every screen in the order, how far along, and what is next. */
export function SetupOverview() {
  const { ui } = useT();
  const progress = useQuery({
    queryKey: ["erp_setup_progress"],
    queryFn: () => callErp<SetupScreenProgress[]>("erp_setup_progress"),
  });

  if (progress.isPending) {
    return (
      <p role="status" className="text-sm text-muted-foreground">
        {ui("Loading…")}
      </p>
    );
  }
  if (progress.error || !progress.data) return null;

  const screens = [...progress.data].sort((a, b) => a.seq - b.seq);
  const next = nextScreen(screens);
  const total = screens.reduce((n, s) => n + s.total, 0);
  const complete = screens.reduce((n, s) => n + s.complete, 0);

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-semibold">{ui("Set up, step by step")}</h2>
        <span className="text-xs text-muted-foreground">
          {complete} / {total} {ui("done")}
        </span>
      </div>

      {next?.next ? (
        <div className="mt-3 rounded-lg border border-primary/40 bg-primary/5 p-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            {ui("The next thing to do")}
          </p>
          <p className="mt-1 text-sm font-medium">{next.next.title}</p>
          <p className="text-xs text-muted-foreground">{next.title}</p>
          <Link
            to={next.screen_path}
            className={`${TOUCH} mt-2 inline-flex items-center gap-1.5 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground`}
          >
            {next.next.action_label}
            <ArrowRight className="size-4" aria-hidden="true" />
          </Link>
        </div>
      ) : (
        <p className="mt-3 text-sm text-muted-foreground">
          {ui("Everything in the setup order is done.")}
        </p>
      )}

      <ol className="mt-4 grid gap-1.5 sm:grid-cols-2">
        {screens.map((s) => (
          <li key={s.screen_path} className="flex items-center gap-2 text-sm">
            <span className="w-5 shrink-0 text-right text-xs text-muted-foreground">{s.seq}.</span>
            <Link to={s.screen_path} className="min-w-0 flex-1 truncate underline">
              {s.title}
            </Link>
            <span
              className={`shrink-0 text-xs ${s.next ? "text-muted-foreground" : "text-emerald-700"}`}
            >
              {s.complete} / {s.total}
            </span>
          </li>
        ))}
      </ol>
    </section>
  );
}
