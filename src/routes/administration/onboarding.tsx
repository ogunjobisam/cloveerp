import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import {
  Check,
  ChevronLeft,
  ChevronRight,
  Circle,
  Clock,
  Plus,
  Sparkles,
  TriangleAlert,
  X,
} from "lucide-react";
import { Fragment, useCallback, useEffect, useRef, useState, type ReactNode } from "react";

import { ActionButton, ErrorNote, PermissionNote, useErpAction } from "../../components/erp/action";
import { registerActionOpener } from "../../components/erp/action-registry";
import { Gate } from "../../components/erp/gate";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { Pill } from "../../components/erp/panel";
import { useErpSession } from "../../components/erp/session-context";
import { useUnsavedGuard } from "../../components/erp/unsaved";
import { callErp, ErpError, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import {
  answerText,
  buildAnswer,
  describeItem,
  emptyDraft,
  entryFor,
  fill,
  fromAnswer,
  hasAnswer,
  listHas,
  missingRequired,
  namesFromQuestions,
  outcomeKind,
  pendingProposals,
  readAccept,
  readItems,
  readQuestions,
  readSessions,
  resumeSection,
  SECTION_ORDER,
  sectionProgress,
  skipsSave,
  statusKind,
  statusText,
  unsavedCodes,
  unsavedQuestions,
  wireValue,
  type AcceptResult,
  type AcceptStep,
  type Draft,
  type Invalid,
  type InterviewSession,
  type ListEntry,
  type Names,
  type Pair,
  type Question,
  type Refusal,
  type SessionProposal,
  type Suggestion,
  type Translate,
} from "../../lib/interview";

/**
 * The onboarding interview.
 *
 * The questions are not in this file, on purpose. They are rows in
 * erp_ref.interview_question — which surface each feeds, what shape of answer
 * it takes, which earlier answer gates it — and the door hands each one back
 * with the options worth offering and the answer this organisation most likely
 * gives, so adding a question or a starting point is a migration rather than a
 * deployment.
 *
 * The screen asks a section at a time, in the order the answers can be put in
 * force: the organisation first, because everything below names a company.
 * Every answer saves as it is given. Proposing turns the answers into changes
 * and nothing more; accepting is a separate press, and before go-live it puts
 * them in force the way a module installer does, while after go-live it stops
 * at the second administrator the database insists on.
 */

export const Route = createFileRoute("/administration/onboarding")({
  head: () => ({
    meta: [
      { title: "Onboarding interview — Clove ERP" },
      {
        name: "description",
        content:
          "Answer questions about how the organisation works, a section at a time, and accept the changes your answers propose.",
      },
      { property: "og:title", content: "Onboarding interview — Clove ERP" },
      {
        property: "og:description",
        content:
          "Answer questions about how the organisation works, a section at a time, and accept the changes your answers propose.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Onboarding />
    </Gate>
  ),
});

/** Long enough to finish a word, short enough that leaving the page rarely beats it. */
const TYPING_PAUSE_MS = 700;

/** Changes listed before "Show every change". */
const ITEM_LIMIT = 12;

const SECTIONS: readonly string[] = SECTION_ORDER;

function sectionText(section: string, ui: Translate): { title: string; blurb: string } {
  switch (section) {
    case "B.7":
      return {
        title: ui("Your organisation"),
        blurb: ui(
          "Your companies, where they trade, how their books are numbered, and how stock is costed and picked.",
        ),
      };
    case "B.1":
      return {
        title: ui("Departments"),
        blurb: ui("The teams that spend money or approve spending."),
      };
    case "B.2":
      return {
        title: ui("Approvals"),
        blurb: ui(
          "Which documents need someone's sign-off before they count, and above what value.",
        ),
      };
    case "B.3":
      return {
        title: ui("Accounting codes"),
        blurb: ui(
          "How products and business partners are grouped so their transactions reach the right nominal accounts.",
        ),
      };
    case "B.4":
      return {
        title: ui("Product classification"),
        blurb: ui(
          "The ways you group products for search and reporting, such as brand or storage condition.",
        ),
      };
    case "B.5":
      return {
        title: ui("Product codes"),
        blurb: ui("Whether new product codes follow a pattern, and what it looks like."),
      };
    case "B.6":
      return {
        title: ui("Marshalling areas"),
        blurb: ui("Where stock is gathered before picking and despatch."),
      };
    case "finance":
      return { title: ui("Setting up the books"), blurb: "" };
    default:
      return { title: section, blurb: "" };
  }
}

function questionAnchor(code: string): string {
  return `question-${code.replace(/[^A-Za-z0-9]+/g, "-")}`;
}

function scrollToId(id: string, focus = false) {
  // After the render that puts the element on the page, not before it.
  window.setTimeout(() => {
    const el = document.getElementById(id);
    el?.scrollIntoView({ behavior: "smooth", block: "start" });
    if (focus) el?.focus({ preventScroll: true });
  }, 50);
}

function Card({ id, children }: { id?: string; children: ReactNode }) {
  return (
    <section id={id} className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      {children}
    </section>
  );
}

// ── The screen ─────────────────────────────────────────────────────────────

function Onboarding() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const mayConfigure = hasPermission(session, "administration.configure");
  const [viewing, setViewing] = useState<string | null>(null);

  const sessions = useQuery({
    queryKey: ["erp_interview_sessions"],
    queryFn: async () => readSessions(await callErp<unknown>("erp_interview_sessions")),
    enabled: mayConfigure,
  });

  const start = useErpAction({
    fn: "erp_start_interview",
    invalidates: ["erp_interview_sessions"],
    onDone: () => setViewing(null),
  });
  const startInterview = start.mutate;

  const list = sessions.data?.sessions ?? [];
  const live = sessions.data?.live ?? false;
  const open = list.find((s) => s.status === "open") ?? null;
  const viewed = viewing === null ? null : (list.find((s) => s.session_id === viewing) ?? null);
  const earlier = list.filter((s) => s.status === "proposed");

  // The walkthrough opens these by door name. They are registered on mount,
  // because the walkthrough reads whether an opener exists as it renders, and
  // read what the page knows at the moment they are pressed.
  const latest = useRef({ loaded: false, open: false, starting: false });
  useEffect(() => {
    latest.current = {
      loaded: sessions.data !== undefined,
      open: open !== null,
      starting: start.isPending,
    };
  });

  useEffect(() => {
    if (!mayConfigure) return undefined;
    const show = (id: string) => {
      setViewing(null);
      scrollToId(id);
    };
    const offs = [
      registerActionOpener("erp_start_interview", () => {
        const now = latest.current;
        if (now.open) show("interview-section");
        else if (now.loaded && !now.starting) {
          setViewing(null);
          startInterview({ p_code: null });
        } else show("interview-start");
      }),
      registerActionOpener("erp_answer_interview", () =>
        show(latest.current.open ? "interview-section" : "interview-start"),
      ),
      registerActionOpener("erp_propose_from_interview", () =>
        show(latest.current.open ? "interview-propose" : "interview-start"),
      ),
    ];
    return () => offs.forEach((off) => off());
  }, [mayConfigure, startInterview]);

  let body: ReactNode;
  if (!mayConfigure) {
    body = <PermissionNote code="administration.configure" />;
  } else if (sessions.isPending) {
    body = (
      <Card>
        <p className="text-sm text-muted-foreground">{ui("Loading your interviews…")}</p>
      </Card>
    );
  } else if (sessions.data === undefined) {
    body = (
      <Card>
        <ErrorNote error={sessions.error} />
      </Card>
    );
  } else if (viewed) {
    body = (
      <Outcome
        key={viewed.session_id}
        session={viewed}
        live={live}
        onBack={() => setViewing(null)}
      />
    );
  } else {
    body = (
      <>
        {open ? (
          <Interview key={open.session_id} session={open} onProposed={setViewing} />
        ) : (
          <Card id="interview-start">
            <h2 className="font-display text-base font-semibold">{ui("Start the interview")}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {ui(
                "Seven short sections, starting with your organisation. Your answers save as you give them, so you can stop at any time and pick up where you left off.",
              )}
            </p>
            {start.error ? (
              <div className="mt-3">
                <ErrorNote error={start.error} />
              </div>
            ) : null}
            <div className="mt-4">
              <ActionButton onClick={() => startInterview({ p_code: null })} busy={start.isPending}>
                {start.isPending ? ui("Starting…") : ui("Start the interview")}
              </ActionButton>
            </div>
          </Card>
        )}
        {earlier.length > 0 ? <EarlierInterviews sessions={earlier} onOpen={setViewing} /> : null}
      </>
    );
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.administration_onboarding", "Onboarding interview")}>
        {ui(
          "Your first-day questionnaire. Describe how the business works — your companies, departments, who signs off spending, how products are grouped and coded — and your answers become the set-up to match. Most questions come with a likely answer you can take with one press. Nothing changes until you accept what your answers propose.",
        )}
      </PageHeader>
      {mayConfigure && sessions.data !== undefined && sessions.error ? (
        <RefreshNote
          error={sessions.error}
          busy={sessions.isFetching}
          onRetry={() => void sessions.refetch()}
        />
      ) : null}
      {body}
    </div>
  );
}

function EarlierInterviews({
  sessions,
  onOpen,
}: {
  sessions: InterviewSession[];
  onOpen: (id: string) => void;
}) {
  const { ui, locale } = useT();
  return (
    <Card>
      <h2 className="font-display text-base font-semibold">{ui("Earlier interviews")}</h2>
      <p className="mt-1 text-sm text-muted-foreground">
        {ui("Open one to see what its answers proposed and whether those changes are in force.")}
      </p>
      <ul className="mt-3 flex flex-col divide-y divide-border/60">
        {sessions.map((s) => {
          const inForce = s.proposals.filter(
            (p) => statusKind(p.change_set_status) === "in_force",
          ).length;
          return (
            <li key={s.session_id} className="flex flex-wrap items-center gap-3 py-3">
              <div className="min-w-0 flex-1">
                <p className="font-mono text-xs">{s.code}</p>
                <p className="text-xs text-muted-foreground">
                  {s.proposed_at ? new Date(s.proposed_at).toLocaleDateString(locale) : "—"}
                </p>
              </div>
              <Pill tone={s.proposals.length > 0 && inForce === s.proposals.length ? "ok" : "warn"}>
                {ui("In force")} {inForce}/{s.proposals.length}
              </Pill>
              <ActionButton variant="secondary" onClick={() => onOpen(s.session_id)}>
                {ui("See what it proposed")}
              </ActionButton>
            </li>
          );
        })}
      </ul>
    </Card>
  );
}

// ── Answering ──────────────────────────────────────────────────────────────

function Interview({
  session,
  onProposed,
}: {
  session: InterviewSession;
  onProposed: (id: string) => void;
}) {
  const { ui } = useT();
  const questions = useQuery({
    queryKey: ["erp_interview_questions", session.session_id],
    queryFn: async () =>
      readQuestions(
        await callErp<unknown>("erp_interview_questions", { p_session_id: session.session_id }),
      ),
  });

  if (questions.isPending) {
    return (
      <Card id="interview-section">
        <p className="text-sm text-muted-foreground">{ui("Loading the questions…")}</p>
      </Card>
    );
  }
  if (questions.data === undefined) {
    // A failed read is not an empty question list, and must not look like one.
    return (
      <Card id="interview-section">
        <ErrorNote error={questions.error} />
      </Card>
    );
  }
  if (questions.data.length === 0) {
    return (
      <Card id="interview-section">
        <p className="text-sm text-muted-foreground">
          {ui(
            "No questions came back for this interview. That is not expected: refresh the page, and if it stays empty, ask your administrator to check the product content was installed.",
          )}
        </p>
      </Card>
    );
  }
  // A refresh that failed after the questions loaded keeps the desk, and the
  // answers being typed into it, on the page: the note says the questions may
  // be out of date, and the next refresh that succeeds clears it. The desk
  // stays the second child either way, so the note coming and going never
  // remounts it.
  return (
    <>
      {questions.error ? (
        <RefreshNote
          error={questions.error}
          busy={questions.isFetching}
          onRetry={() => void questions.refetch()}
        />
      ) : null}
      <InterviewDesk session={session} questions={questions.data} onProposed={onProposed} />
    </>
  );
}

/** A background refresh failed; what is on the page is the last that loaded. */
function RefreshNote({
  error,
  busy,
  onRetry,
}: {
  error: unknown;
  busy: boolean;
  onRetry: () => void;
}) {
  const { ui } = useT();
  return (
    <div
      role="status"
      className="flex min-w-0 flex-wrap items-center gap-3 rounded-md border border-amber-500/40 bg-amber-500/5 px-3 py-2"
    >
      <TriangleAlert
        className="size-4 shrink-0 text-amber-700 dark:text-amber-400"
        aria-hidden="true"
      />
      <p className="min-w-0 flex-1 text-sm">
        {ui(
          "Could not refresh. What you see is what last loaded, and your unsaved answers are kept.",
        )}
      </p>
      <ActionButton variant="secondary" onClick={onRetry} busy={busy}>
        {ui("Try again")}
      </ActionButton>
      <details className="w-full text-xs text-muted-foreground">
        <summary className="cursor-pointer">{ui("Why")}</summary>
        <div className="mt-2">
          <ErrorNote error={error} />
        </div>
      </details>
    </div>
  );
}

type Phase = "idle" | "waiting" | "saving" | "saved" | "invalid" | "error";
type SaveState = { phase: Phase; error: unknown; invalid: Invalid | null };

const IDLE: SaveState = { phase: "idle", error: null, invalid: null };

/**
 * Every answer saves as it is given.
 *
 * A pick saves at once; typing saves after a pause. Saves for one question run
 * one after another, so a slow first save cannot land after a later one, and
 * only the latest decides what the badge says. Clearing a question sends JSON
 * null, which the door takes as withdrawing the answer.
 */
function useAutosave(sessionId: string) {
  const save = useErpAction({
    fn: "erp_answer_interview",
    invalidates: ["erp_interview_questions", "erp_interview_sessions"],
  });
  const { mutateAsync } = save;
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const [states, setStates] = useState<Record<string, SaveState>>({});
  const sent = useRef<Record<string, unknown>>({});
  const timers = useRef<Record<string, { handle: ReturnType<typeof setTimeout>; value: unknown }>>(
    {},
  );
  const chains = useRef<Record<string, Promise<void>>>({});
  const latest = useRef<Record<string, number>>({});
  const failed = useRef<Set<string>>(new Set());
  // The same set, as state, so the screen can read it while rendering.
  const [failedCodes, setFailedCodes] = useState<ReadonlySet<string>>(() => new Set());

  const mark = useCallback((code: string, state: SaveState) => {
    setStates((s) => ({ ...s, [code]: state }));
  }, []);

  const setFailed = useCallback((code: string, on: boolean) => {
    if (on) failed.current.add(code);
    else failed.current.delete(code);
    setFailedCodes(new Set(failed.current));
  }, []);

  const queue = useCallback(
    (code: string, value: unknown) => {
      sent.current[code] = value;
      const n = (latest.current[code] ?? 0) + 1;
      latest.current[code] = n;
      mark(code, { phase: "saving", error: null, invalid: null });
      const run = (chains.current[code] ?? Promise.resolve())
        .then(() =>
          mutateAsync({ p_session_id: sessionId, p_question_code: code, p_answer: value }),
        )
        .then(
          () => {
            if (latest.current[code] !== n) return;
            setFailed(code, false);
            mark(code, { phase: "saved", error: null, invalid: null });
          },
          (error: unknown) => {
            if (latest.current[code] !== n) return;
            delete sent.current[code];
            setFailed(code, true);
            mark(code, { phase: "error", error, invalid: null });
          },
        );
      chains.current[code] = run;
    },
    [mark, mutateAsync, sessionId, setFailed],
  );

  const change = useCallback(
    (q: Question, draft: Draft, typing: boolean) => {
      setDrafts((d) => ({ ...d, [q.code]: draft }));
      const waiting = timers.current[q.code];
      if (waiting) {
        clearTimeout(waiting.handle);
        delete timers.current[q.code];
      }
      const built = buildAnswer(q, draft);
      if (built.kind === "invalid") {
        mark(q.code, { phase: "invalid", error: null, invalid: built });
        return;
      }
      const value = wireValue(built);
      const held =
        q.code in sent.current ? sent.current[q.code] : hasAnswer(q.answer) ? q.answer : null;
      // A question whose last save failed is sent again even when the answer
      // matches what is held, or going back to the stored value would leave
      // it failed with no card saying so.
      if (skipsSave(value, held, failed.current.has(q.code))) {
        mark(
          q.code,
          q.code in sent.current ? { phase: "saved", error: null, invalid: null } : IDLE,
        );
        return;
      }
      if (typing) {
        mark(q.code, { phase: "waiting", error: null, invalid: null });
        timers.current[q.code] = {
          value,
          handle: setTimeout(() => {
            delete timers.current[q.code];
            queue(q.code, value);
          }, TYPING_PAUSE_MS),
        };
      } else {
        queue(q.code, value);
      }
    },
    [mark, queue],
  );

  /**
   * Saves what is still waiting, and names the questions among `applying`
   * whose answers did not save. A failure under a question that no longer
   * applies does not count: propose does not read that answer.
   */
  const flush = useCallback(
    async (applying: ReadonlySet<string>): Promise<string[]> => {
      for (const [code, waiting] of Object.entries(timers.current)) {
        clearTimeout(waiting.handle);
        delete timers.current[code];
        queue(code, waiting.value);
      }
      await Promise.all(Object.values(chains.current));
      return unsavedCodes(failed.current, applying);
    },
    [queue],
  );

  // Leaving the page does not strand a typed answer in a timer.
  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const [code, waiting] of Object.entries(pending)) {
        clearTimeout(waiting.handle);
        queue(code, waiting.value);
      }
    };
  }, [queue]);

  const draftOf = (q: Question): Draft => drafts[q.code] ?? fromAnswer(q.answer_shape, q.answer);
  const stateOf = (code: string): SaveState => states[code] ?? IDLE;
  const valueOf = (q: Question): unknown => {
    if (!(q.code in drafts)) return q.answer;
    return wireValue(buildAnswer(q, draftOf(q)));
  };
  const retry = (q: Question) => {
    const built = buildAnswer(q, draftOf(q));
    if (built.kind !== "invalid") queue(q.code, wireValue(built));
  };
  const saving = Object.values(states).some((s) => s.phase === "waiting" || s.phase === "saving");

  return { change, draftOf, stateOf, valueOf, retry, flush, saving, failedCodes };
}

function InterviewDesk({
  session,
  questions,
  onProposed,
}: {
  session: InterviewSession;
  questions: Question[];
  onProposed: (id: string) => void;
}) {
  const { ui } = useT();
  const autosave = useAutosave(session.session_id);
  const [section, setSection] = useState<string>(
    () => resumeSection(sectionProgress(questions)) ?? SECTIONS[0] ?? "B.7",
  );
  const [flushing, setFlushing] = useState(false);
  // What the last press of Propose found not saved, until each saves.
  const [notSaved, setNotSaved] = useState<string[]>([]);

  const propose = useErpAction({
    fn: "erp_propose_from_interview",
    invalidates: [
      "erp_interview_sessions",
      "erp_interview_questions",
      "erp_proposals",
      "erp_change_sets",
    ],
    onDone: () => onProposed(session.session_id),
  });

  // Progress and what is missing follow what the screen holds, so the counts
  // move as a person answers rather than when the next read comes back.
  const held = questions.map((q) => ({ ...q, answer: autosave.valueOf(q) }));
  const progress = sectionProgress(held);
  const missing = missingRequired(held);
  const invalid = questions.filter(
    (q) => q.applies && autosave.stateOf(q.code).phase === "invalid",
  );
  const unsaved = unsavedQuestions(
    questions,
    (code) => autosave.stateOf(code).phase === "error",
    notSaved,
    autosave.failedCodes,
  );
  useUnsavedGuard(autosave.saving || flushing || invalid.length > 0);

  const index = Math.max(0, SECTIONS.indexOf(section));
  const here = progress.find((p) => p.section === section);
  const asked = questions.filter((q) => q.section === section && q.applies);
  const text = sectionText(section, ui);

  const adoptable = asked.filter(
    (q) =>
      q.code !== "approval.threshold" &&
      hasAnswer(q.likely) &&
      !hasAnswer(autosave.valueOf(q)) &&
      autosave.stateOf(q.code).phase !== "invalid",
  );

  const go = (next: string, code?: string) => {
    setSection(next);
    if (code) scrollToId(questionAnchor(code));
    else scrollToId("interview-section-title", true);
  };

  const doPropose = async () => {
    const applying = new Set(questions.filter((q) => q.applies).map((q) => q.code));
    setFlushing(true);
    let codes: string[] = [];
    try {
      codes = await autosave.flush(applying);
    } finally {
      setFlushing(false);
    }
    setNotSaved(codes);
    // Proposing over an answer that did not save would propose the old one;
    // the list above says which, rather than the press doing nothing.
    if (codes.length === 0) propose.mutate({ p_session_id: session.session_id });
  };

  const pct = here && here.asked > 0 ? Math.round((here.answered / here.asked) * 100) : 0;

  return (
    <>
      <nav aria-label={ui("Interview sections")} className="min-w-0 overflow-x-auto pb-1">
        <ol className="flex min-w-fit items-stretch gap-1">
          {SECTIONS.map((s, i) => {
            const p = progress.find((x) => x.section === s);
            const active = s === section;
            return (
              <li key={s} className="min-w-0 flex-1 basis-40">
                <button
                  type="button"
                  onClick={() => go(s)}
                  aria-current={active ? "step" : undefined}
                  className={[
                    "flex h-14 w-full min-w-0 items-center gap-2 pr-5 text-left transition-colors",
                    i === 0 ? "step-chevron-first pl-4" : "step-chevron pl-7",
                    active
                      ? "bg-accent text-accent-foreground"
                      : "bg-soft text-foreground hover:bg-muted-foreground/15",
                  ].join(" ")}
                >
                  <span
                    className={`grid size-6 shrink-0 place-items-center rounded-full text-[11px] font-semibold tabular-nums ${
                      active ? "bg-accent-foreground/25" : "bg-card text-muted-foreground"
                    }`}
                  >
                    {p?.complete ? <Check className="size-3.5" aria-hidden="true" /> : i + 1}
                  </span>
                  <span className="min-w-0 flex-1 truncate text-sm font-semibold">
                    {sectionText(s, ui).title}
                  </span>
                  <span
                    className={`shrink-0 rounded-full px-1.5 py-0.5 text-[11px] tabular-nums ${
                      active ? "bg-accent-foreground/25" : "bg-card text-muted-foreground"
                    }`}
                  >
                    {p?.answered ?? 0}/{p?.asked ?? 0}
                  </span>
                </button>
              </li>
            );
          })}
        </ol>
      </nav>

      <section
        id="interview-section"
        aria-labelledby="interview-section-title"
        className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5"
      >
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
              {ui("Section")} {index + 1}/{SECTIONS.length}
            </p>
            <h2
              id="interview-section-title"
              tabIndex={-1}
              className="mt-0.5 font-display text-lg font-semibold"
            >
              {text.title}
            </h2>
            {text.blurb ? <p className="mt-1 text-sm text-muted-foreground">{text.blurb}</p> : null}
          </div>
          {adoptable.length > 0 ? (
            <ActionButton
              variant="secondary"
              onClick={() =>
                adoptable.forEach((q) =>
                  autosave.change(q, fromAnswer(q.answer_shape, q.likely), false),
                )
              }
            >
              {ui("Use the suggested answers for this section")}
            </ActionButton>
          ) : null}
        </div>

        <div
          className="mt-3 h-1.5 overflow-hidden rounded-full bg-muted"
          role="progressbar"
          aria-valuenow={here?.answered ?? 0}
          aria-valuemin={0}
          aria-valuemax={here?.asked ?? 0}
          aria-label={ui("Questions answered in this section")}
        >
          <div
            className="h-full rounded-full bg-ok transition-[width]"
            style={{ width: `${pct}%` }}
          />
        </div>

        {asked.length === 0 ? (
          <p className="mt-4 text-sm text-muted-foreground">
            {ui("Nothing in this section applies, given your earlier answers.")}
          </p>
        ) : (
          <ul className="mt-2 divide-y divide-border/60">
            {asked.map((q) => (
              <QuestionCard
                key={q.code}
                q={q}
                draft={autosave.draftOf(q)}
                state={autosave.stateOf(q.code)}
                onChange={(draft, typing) => autosave.change(q, draft, typing)}
                onRetry={() => autosave.retry(q)}
              />
            ))}
          </ul>
        )}

        <div className="mt-4 flex flex-wrap items-center justify-between gap-2 border-t border-border/60 pt-4">
          {index > 0 ? (
            <ActionButton variant="secondary" onClick={() => go(SECTIONS[index - 1] ?? section)}>
              <ChevronLeft className="mr-1 size-4" aria-hidden="true" />
              {ui("Back")}
            </ActionButton>
          ) : (
            <span />
          )}
          {index < SECTIONS.length - 1 ? (
            <ActionButton onClick={() => go(SECTIONS[index + 1] ?? section)}>
              {ui("Next")}
              <ChevronRight className="ml-1 size-4" aria-hidden="true" />
            </ActionButton>
          ) : (
            <ActionButton onClick={() => scrollToId("interview-propose")}>
              {ui("Review and propose")}
              <ChevronRight className="ml-1 size-4" aria-hidden="true" />
            </ActionButton>
          )}
        </div>
      </section>

      <Card id="interview-propose">
        <h2 className="font-display text-base font-semibold">{ui("Propose the changes")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          {ui(
            "Proposing turns your answers into changes, one group per section. You see every change in plain words before anything is put in force, and a question left unanswered changes nothing.",
          )}
        </p>
        {missing.length > 0 ? (
          <div className="mt-3 rounded-md border border-amber-500/40 bg-amber-500/5 p-3">
            <p className="text-sm font-medium">
              {ui("Answer these first — they are needed before you can propose:")}
            </p>
            <ul className="mt-2 flex flex-col gap-1">
              {missing.map((q) => (
                <li key={q.code}>
                  <button
                    type="button"
                    onClick={() => go(q.section, q.code)}
                    className="text-left text-sm text-accent underline underline-offset-2"
                  >
                    {sectionText(q.section, ui).title}: {q.prompt}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        {invalid.length > 0 ? (
          <p className="mt-3 text-sm text-destructive">
            {ui("Some answers need correcting before you can propose.")}
          </p>
        ) : null}
        {unsaved.length > 0 ? (
          <div className="mt-3">
            <p className="text-sm text-destructive">
              {ui("Some answers did not save. Try saving them again before you propose:")}
            </p>
            <ul className="mt-2 flex flex-col gap-1">
              {unsaved.map((q) => (
                <li key={q.code}>
                  <button
                    type="button"
                    onClick={() => go(q.section, q.code)}
                    className="text-left text-sm text-accent underline underline-offset-2"
                  >
                    {sectionText(q.section, ui).title}: {q.prompt}
                  </button>
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        {propose.error ? (
          <div className="mt-3">
            <ErrorNote error={propose.error} />
          </div>
        ) : null}
        <div className="mt-4 flex flex-wrap items-center gap-3">
          <ActionButton
            onClick={() => void doPropose()}
            busy={propose.isPending || flushing}
            disabled={missing.length > 0 || invalid.length > 0 || unsaved.length > 0}
          >
            {propose.isPending || flushing ? ui("Proposing…") : ui("Propose the changes")}
          </ActionButton>
          {autosave.saving ? (
            <span className="text-xs text-muted-foreground">
              {ui("Your last answers are still saving.")}
            </span>
          ) : null}
        </div>
      </Card>
    </>
  );
}

function invalidText(invalid: Invalid, ui: Translate): string {
  switch (invalid.reason) {
    case "not_a_number":
      return ui("That is not a number. Type digits, for example 5,000.");
    case "not_whole":
      return ui("Use a whole number.");
    case "too_many_decimals":
      return fill(ui("Use at most {places} decimal places."), { places: invalid.max });
    case "out_of_range":
      return invalid.min !== null && invalid.max !== null
        ? fill(ui("Use a number from {min} to {max}."), { min: invalid.min, max: invalid.max })
        : invalid.min !== null
          ? fill(ui("Use a number of at least {min}."), { min: invalid.min })
          : ui("That number is too large for this question.");
    case "not_a_choice":
      return ui("Choose one of the options.");
    case "incomplete_rows":
      return ui("Each row needs both columns filled in. Finish or remove the unfinished rows.");
  }
}

function QuestionCard({
  q,
  draft,
  state,
  onChange,
  onRetry,
}: {
  q: Question;
  draft: Draft;
  state: SaveState;
  onChange: (draft: Draft, typing: boolean) => void;
  onRetry: () => void;
}) {
  const { ui, locale } = useT();
  const anchor = questionAnchor(q.code);
  const promptId = `${anchor}-prompt`;
  const built = buildAnswer(q, draft);
  const raw = draft.kind === "scalar" ? draft.raw : "";
  const likely = hasAnswer(q.likely) && built.kind === "empty";

  let control: ReactNode;
  switch (q.answer_shape) {
    case "boolean":
    case "choice":
      control = (
        <OptionButtons
          q={q}
          value={raw}
          labelledBy={promptId}
          onPick={(value) => onChange({ kind: "scalar", raw: value }, false)}
        />
      );
      break;
    case "text_list":
      control = (
        <ListEditor
          q={q}
          entries={draft.kind === "list" ? draft.entries : []}
          onChange={(entries) => onChange({ kind: "list", entries }, false)}
        />
      );
      break;
    case "text_pairs":
      control = (
        <PairsEditor
          q={q}
          rows={draft.kind === "pairs" ? draft.rows : []}
          onChange={(rows, typing) => onChange({ kind: "pairs", rows }, typing)}
        />
      );
      break;
    default:
      control =
        q.suggestions.length > 0 ? (
          <PickOrType
            q={q}
            raw={raw}
            onChange={(value, typing) => onChange({ kind: "scalar", raw: value }, typing)}
          />
        ) : (
          <input
            type="text"
            aria-labelledby={promptId}
            value={raw}
            inputMode={
              q.answer_shape === "integer"
                ? "numeric"
                : q.answer_shape === "money"
                  ? "decimal"
                  : "text"
            }
            placeholder={q.example ?? ""}
            onChange={(e) => onChange({ kind: "scalar", raw: e.target.value }, true)}
            className={`${TOUCH} w-full min-w-0 rounded-md border border-input bg-background px-3 text-sm sm:max-w-md`}
          />
        );
  }

  return (
    <li id={anchor} className="scroll-mt-24 py-5">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <h3 id={promptId} className="min-w-0 flex-1 text-sm font-medium">
          {q.prompt}
          {q.is_required ? (
            <span className="ml-1 font-normal text-muted-foreground">{ui("(required)")}</span>
          ) : null}
        </h3>
        <span
          aria-live="polite"
          className={`shrink-0 text-xs ${state.phase === "error" ? "text-destructive" : "text-muted-foreground"}`}
        >
          {state.phase === "waiting" || state.phase === "saving"
            ? ui("Saving…")
            : state.phase === "saved"
              ? ui("Saved")
              : state.phase === "error"
                ? ui("Not saved")
                : ""}
        </span>
      </div>
      {q.help ? <p className="mt-1 text-xs text-muted-foreground">{q.help}</p> : null}

      <div className="mt-3 min-w-0">{control}</div>

      {likely ? (
        <div className="mt-3 flex flex-wrap items-center gap-2 rounded-md border border-accent/30 bg-accent/5 px-3 py-2">
          <Sparkles className="size-4 shrink-0 text-accent" aria-hidden="true" />
          <p className="min-w-0 flex-1 text-sm">
            <span className="text-muted-foreground">{ui("Likely answer:")}</span>{" "}
            {answerText(q, q.likely, ui, locale)}
          </p>
          <ActionButton
            variant="secondary"
            onClick={() => onChange(fromAnswer(q.answer_shape, q.likely), false)}
          >
            {ui("Use this")}
          </ActionButton>
        </div>
      ) : null}

      {state.phase === "invalid" && state.invalid ? (
        <p className="mt-2 text-sm text-destructive">{invalidText(state.invalid, ui)}</p>
      ) : null}

      {state.phase === "error" ? (
        <div className="mt-2 flex flex-col items-start gap-2">
          <ErrorNote error={state.error} />
          <ActionButton variant="secondary" onClick={onRetry}>
            {ui("Try saving again")}
          </ActionButton>
        </div>
      ) : null}

      {built.kind === "answer" ? (
        <button
          type="button"
          onClick={() => onChange(emptyDraft(q.answer_shape), false)}
          className={`${TOUCH} mt-1 text-xs font-medium text-muted-foreground underline underline-offset-2 hover:text-foreground`}
        >
          {ui("Clear this answer")}
        </button>
      ) : null}
    </li>
  );
}

function fallbackOption(value: string, label: string): Suggestion {
  return {
    value,
    code: null,
    label,
    note: null,
    axis: null,
    likely: false,
    available: true,
    unavailable_reason: null,
    present: false,
  };
}

/** A yes/no or a choice: every option on show, with what choosing it means. */
function OptionButtons({
  q,
  value,
  labelledBy,
  onPick,
}: {
  q: Question;
  value: string;
  labelledBy: string;
  onPick: (value: string) => void;
}) {
  const { ui } = useT();
  const options =
    q.suggestions.length > 0
      ? q.suggestions
      : q.answer_shape === "boolean"
        ? [fallbackOption("true", ui("Yes")), fallbackOption("false", ui("No"))]
        : q.choices.map((c) => fallbackOption(c, c));
  const likelyValue = hasAnswer(q.likely) ? String(q.likely) : null;

  return (
    <div role="radiogroup" aria-labelledby={labelledBy} className="grid gap-2 sm:grid-cols-2">
      {options.map((o) => {
        const checked = value === o.value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={checked}
            disabled={!o.available}
            onClick={() => onPick(o.value)}
            className={`${TOUCH} flex min-w-0 flex-col items-start gap-0.5 rounded-lg border px-3 py-2 text-left transition-colors disabled:cursor-not-allowed disabled:opacity-70 ${
              checked
                ? "border-accent bg-accent/10 ring-1 ring-accent"
                : "border-input bg-background hover:border-accent/50"
            }`}
          >
            <span className="flex w-full items-center gap-2 text-sm font-medium">
              {checked ? (
                <Check className="size-4 shrink-0 text-accent" aria-hidden="true" />
              ) : (
                <Circle className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
              )}
              <span className="min-w-0 flex-1">{o.label}</span>
              {o.likely || likelyValue === o.value ? (
                <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[11px] font-normal text-muted-foreground">
                  {ui("Likely")}
                </span>
              ) : null}
            </span>
            {o.note ? <span className="pl-6 text-xs text-muted-foreground">{o.note}</span> : null}
            {!o.available && o.unavailable_reason ? (
              <span className="pl-6 text-xs text-destructive">{o.unavailable_reason}</span>
            ) : null}
          </button>
        );
      })}
    </div>
  );
}

/** Pick one of the values offered, or type one that is not on the list. */
function PickOrType({
  q,
  raw,
  onChange,
}: {
  q: Question;
  raw: string;
  onChange: (value: string, typing: boolean) => void;
}) {
  const { ui } = useT();
  const matched = q.suggestions.find((s) => s.value === raw.trim());
  const withCode = q.answer_shape !== "integer";

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <div className="flex min-w-0 flex-col gap-2 sm:flex-row">
        <select
          aria-label={`${q.prompt} — ${ui("pick from the list")}`}
          value={matched?.value ?? ""}
          onChange={(e) => {
            if (e.target.value !== "") onChange(e.target.value, false);
          }}
          className={`${TOUCH} min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm`}
        >
          <option value="">{ui("Choose…")}</option>
          {q.suggestions.map((s) => (
            <option key={s.value} value={s.value} disabled={!s.available}>
              {withCode && s.label !== s.value ? `${s.label} (${s.value})` : s.label}
            </option>
          ))}
        </select>
        <input
          type="text"
          aria-label={`${q.prompt} — ${ui("or type your own")}`}
          value={raw}
          inputMode={q.answer_shape === "integer" ? "numeric" : "text"}
          placeholder={q.example ?? ui("Or type your own")}
          onChange={(e) => onChange(e.target.value, true)}
          className={`${TOUCH} min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm`}
        />
      </div>
      {matched?.note ? <p className="text-xs text-muted-foreground">{matched.note}</p> : null}
    </div>
  );
}

/** A list: what is in it, the starting points worth adding, and a box for anything else. */
function ListEditor({
  q,
  entries,
  onChange,
}: {
  q: Question;
  entries: ListEntry[];
  onChange: (entries: ListEntry[]) => void;
}) {
  const { ui } = useT();
  const [typed, setTyped] = useState("");

  const add = (entry: ListEntry | null) => {
    if (entry === null || listHas(entries, entry)) return;
    onChange([...entries, entry]);
  };
  const addTyped = () => {
    const entry = entryFor(typed, q.suggestions);
    if (entry === null) return;
    add(entry);
    setTyped("");
  };

  return (
    <div className="flex min-w-0 flex-col gap-3">
      {entries.length === 0 ? (
        <p className="text-xs text-muted-foreground">{ui("Nothing added yet.")}</p>
      ) : (
        <ul className="flex flex-wrap gap-2" aria-label={ui("Your answer so far")}>
          {entries.map((e, i) => (
            <li
              key={`${e.code ?? ""}|${e.name}`}
              className="inline-flex max-w-full items-center gap-1 rounded-full border border-border bg-muted/50 py-0.5 pl-3 pr-1 text-sm"
            >
              <span className="min-w-0 truncate">{e.name}</span>
              {e.code !== null && e.code !== e.name ? (
                <span className="font-mono text-[11px] text-muted-foreground">{e.code}</span>
              ) : null}
              <button
                type="button"
                onClick={() => onChange(entries.filter((_, j) => j !== i))}
                aria-label={`${ui("Remove")} ${e.name}`}
                className="grid size-8 shrink-0 place-items-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground"
              >
                <X className="size-3.5" aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}

      {q.suggestions.length > 0 ? (
        <div className="min-w-0">
          <p className="text-xs font-medium text-muted-foreground">
            {ui("Starting points — press one to add it, press it again to take it out")}
          </p>
          <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {q.suggestions.map((s) => {
              const entry: ListEntry = { code: s.code ?? s.value, name: s.label };
              const added = listHas(entries, entry);
              return (
                <button
                  key={s.value}
                  type="button"
                  aria-pressed={added}
                  disabled={!s.available && !added}
                  onClick={() =>
                    added ? onChange(entries.filter((e) => !listHas([e], entry))) : add(entry)
                  }
                  className={`${TOUCH} flex min-w-0 flex-col items-start gap-0.5 rounded-lg border px-3 py-2 text-left transition-colors disabled:cursor-not-allowed disabled:opacity-70 ${
                    added
                      ? "border-accent bg-accent/10"
                      : "border-input bg-background hover:border-accent/50"
                  }`}
                >
                  <span className="flex w-full items-center gap-2 text-sm font-medium">
                    {added ? (
                      <Check className="size-4 shrink-0 text-accent" aria-hidden="true" />
                    ) : (
                      <Plus className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                    )}
                    <span className="min-w-0 flex-1">{s.label}</span>
                    {s.likely ? (
                      <span className="shrink-0 rounded-full bg-muted px-1.5 py-0.5 text-[11px] font-normal text-muted-foreground">
                        {ui("Likely")}
                      </span>
                    ) : null}
                  </span>
                  {s.note ? (
                    <span className="pl-6 text-xs text-muted-foreground">{s.note}</span>
                  ) : null}
                  {s.present ? (
                    <span className="pl-6 text-xs text-emerald-700 dark:text-emerald-400">
                      {ui("already in your organisation")}
                    </span>
                  ) : null}
                  {!s.available && s.unavailable_reason ? (
                    <span className="pl-6 text-xs text-destructive">{s.unavailable_reason}</span>
                  ) : null}
                </button>
              );
            })}
          </div>
        </div>
      ) : null}

      <div className="flex min-w-0 flex-wrap gap-2">
        <input
          type="text"
          aria-label={`${q.prompt} — ${ui("add your own")}`}
          value={typed}
          placeholder={q.example ?? ui("Type a name, then press Add")}
          onChange={(e) => setTyped(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              addTyped();
            }
          }}
          className={`${TOUCH} min-w-0 flex-1 rounded-md border border-input bg-background px-3 text-sm sm:max-w-md`}
        />
        <ActionButton variant="secondary" onClick={addTyped} disabled={typed.trim() === ""}>
          {ui("Add")}
        </ActionButton>
      </div>
    </div>
  );
}

/** The value a select offers for "none of these — let me type it". */
const SOMETHING_ELSE = "__something_else__";

function pairHeadings(code: string, ui: Translate): [string, string] {
  switch (code) {
    case "org.companies":
      return [ui("Company code"), ui("Company name")];
    case "org.currencies":
      return [ui("Company"), ui("Currency")];
    case "org.countries":
      return [ui("Company"), ui("Country")];
    case "org.locales":
      return [ui("Company"), ui("Language")];
    case "org.legislation":
      return [ui("Company"), ui("Tax and legal rules")];
    case "org.identity_by_class":
      return [ui("Kind of product"), ui("Labelled at")];
    case "org.allocation_by_site":
      return [ui("Site"), ui("Picking order")];
    case "classification.values":
      return [ui("Grouping"), ui("Value")];
    default:
      return [ui("Name"), ui("Value")];
  }
}

function pair(left: string, right: string, code?: string | null): Pair {
  const out: Pair = { left, right };
  if (code) out.code = code;
  return out;
}

/** Rows of two columns: a thing on the left, what applies to it on the right. */
function PairsEditor({
  q,
  rows,
  onChange,
}: {
  q: Question;
  rows: Pair[];
  onChange: (rows: Pair[], typing: boolean) => void;
}) {
  const { ui } = useT();
  const [leftHeading, rightHeading] = pairHeadings(q.code, ui);
  const [typingLeft, setTypingLeft] = useState<boolean[]>([]);
  const [typingRight, setTypingRight] = useState<boolean[]>([]);
  const free = q.code === "org.companies";
  const byGrouping = q.code === "classification.values";

  const suggestedLefts = new Set(q.left_suggestions.map((l) => l.value));
  const leftOptions = [
    ...q.left_suggestions.map((l) => ({
      value: l.value,
      label: l.label !== l.value ? `${l.label} (${l.value})` : l.label,
    })),
    ...[...new Set(rows.map((r) => r.left.trim()))]
      .filter((v) => v !== "" && !suggestedLefts.has(v))
      .map((v) => ({ value: v, label: v })),
  ];

  const set = (i: number, next: Pair, typing: boolean) =>
    onChange(
      rows.map((r, j) => (j === i ? next : r)),
      typing,
    );
  const flag = (list: boolean[], i: number, on: boolean) => {
    const copy = [...list];
    copy[i] = on;
    return copy;
  };
  const remove = (i: number) => {
    setTypingLeft((l) => l.filter((_, j) => j !== i));
    setTypingRight((l) => l.filter((_, j) => j !== i));
    onChange(
      rows.filter((_, j) => j !== i),
      false,
    );
  };

  const cell = `${TOUCH} w-full min-w-0 rounded-md border border-input bg-background px-3 text-sm`;

  return (
    <div className="flex min-w-0 flex-col gap-2">
      {rows.length > 0 ? (
        <div
          aria-hidden="true"
          className="hidden grid-cols-[minmax(0,1fr)_minmax(0,1fr)_2.75rem] gap-2 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground sm:grid"
        >
          <span>{leftHeading}</span>
          <span>{rightHeading}</span>
          <span />
        </div>
      ) : (
        <p className="text-xs text-muted-foreground">{ui("No rows yet.")}</p>
      )}

      <ul className="flex min-w-0 flex-col gap-2">
        {rows.map((row, i) => {
          const rightOptions = byGrouping
            ? q.suggestions.filter((s) => s.axis === row.left)
            : q.suggestions;
          const matched = byGrouping
            ? rightOptions.find(
                (s) =>
                  (row.code !== undefined && (s.code ?? s.value) === row.code) ||
                  (row.code === undefined && s.label === row.right),
              )
            : rightOptions.find((s) => s.value === row.right);
          // With nothing suggested on the left, the left column is typed; the
          // values typed in other rows are offered only where there is a list.
          const leftTyped = free || q.left_suggestions.length === 0 || (typingLeft[i] ?? false);
          const rightTyped =
            free ||
            rightOptions.length === 0 ||
            (typingRight[i] ?? false) ||
            (row.right !== "" && matched === undefined);

          return (
            <li
              key={i}
              className="grid min-w-0 grid-cols-1 gap-2 rounded-md border border-border/60 p-2 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_2.75rem] sm:border-0 sm:p-0"
            >
              {leftTyped ? (
                <input
                  type="text"
                  aria-label={`${leftHeading} ${i + 1}`}
                  value={row.left}
                  placeholder={free ? ui("for example UK") : leftHeading}
                  onChange={(e) =>
                    set(i, pair(e.target.value, row.right, byGrouping ? null : row.code), true)
                  }
                  className={cell}
                />
              ) : (
                <select
                  aria-label={`${leftHeading} ${i + 1}`}
                  value={row.left}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === SOMETHING_ELSE) {
                      setTypingLeft((l) => flag(l, i, true));
                      set(i, pair("", byGrouping ? "" : row.right), false);
                    } else if (byGrouping) {
                      set(i, pair(v, ""), false);
                    } else {
                      set(i, pair(v, row.right, row.code), false);
                    }
                  }}
                  className={cell}
                >
                  <option value="">{ui("Choose…")}</option>
                  {leftOptions.map((o) => (
                    <option key={o.value} value={o.value}>
                      {o.label}
                    </option>
                  ))}
                  <option value={SOMETHING_ELSE}>{ui("Something else…")}</option>
                </select>
              )}

              {rightTyped ? (
                <input
                  type="text"
                  aria-label={`${rightHeading} ${i + 1}`}
                  value={row.right}
                  placeholder={
                    free ? ui("for example Northern Trading Ltd") : (q.example ?? rightHeading)
                  }
                  onChange={(e) => set(i, pair(row.left, e.target.value), true)}
                  className={cell}
                />
              ) : (
                <select
                  aria-label={`${rightHeading} ${i + 1}`}
                  value={matched?.value ?? ""}
                  disabled={byGrouping && row.left === ""}
                  onChange={(e) => {
                    const v = e.target.value;
                    if (v === SOMETHING_ELSE) {
                      setTypingRight((l) => flag(l, i, true));
                      set(i, pair(row.left, ""), false);
                      return;
                    }
                    const s = rightOptions.find((x) => x.value === v);
                    if (!s) set(i, pair(row.left, ""), false);
                    else if (byGrouping) set(i, pair(row.left, s.label, s.code ?? s.value), false);
                    else set(i, pair(row.left, s.value), false);
                  }}
                  className={cell}
                >
                  <option value="">{ui("Choose…")}</option>
                  {rightOptions.map((s) => (
                    <option key={s.value} value={s.value} disabled={!s.available}>
                      {s.label !== s.value && !byGrouping ? `${s.label} (${s.value})` : s.label}
                    </option>
                  ))}
                  <option value={SOMETHING_ELSE}>{ui("Something else…")}</option>
                </select>
              )}

              <button
                type="button"
                onClick={() => remove(i)}
                aria-label={`${ui("Remove row")} ${i + 1}`}
                className={`${TOUCH} grid w-full place-items-center rounded-md border border-input text-muted-foreground hover:text-foreground sm:w-11`}
              >
                <X className="size-4" aria-hidden="true" />
              </button>
            </li>
          );
        })}
      </ul>

      <div>
        <ActionButton
          variant="secondary"
          onClick={() => {
            setTypingLeft((l) => [...l, false]);
            setTypingRight((l) => [...l, false]);
            onChange([...rows, { left: "", right: "" }], false);
          }}
        >
          <Plus className="mr-1 size-4" aria-hidden="true" />
          {ui("Add a row")}
        </ActionButton>
      </div>

      {free && q.left_suggestions.some((l) => l.present) ? (
        <p className="text-xs text-muted-foreground">
          {ui("Already in your organisation:")}{" "}
          {q.left_suggestions
            .filter((l) => l.present)
            .map((l) => (l.label !== l.value ? `${l.label} (${l.value})` : l.value))
            .join(", ")}
        </p>
      ) : null}
    </div>
  );
}

// ── What the answers proposed ──────────────────────────────────────────────

function refusalError(refusal: Refusal): ErpError {
  // The register is keyed by the refusal's token, which the screen finds at
  // the start of the message; a message that arrives without it gets it back.
  // A refusal with no token carries the database's error code instead, which
  // is what the friendly wording for a duplicate or a missing record reads.
  const token = /^(CLOVEERP|ERPWARE)_[A-Z0-9_]+$/.test(refusal.code);
  const message =
    token && !refusal.message.startsWith(refusal.code)
      ? `${refusal.code}: ${refusal.message}`
      : refusal.message;
  return new ErpError(message, {
    code: token || refusal.code === "" ? undefined : refusal.code,
    details: refusal.detail ?? undefined,
    hint: refusal.hint ?? undefined,
  });
}

function Outcome({
  session,
  live,
  onBack,
}: {
  session: InterviewSession;
  live: boolean;
  onBack: () => void;
}) {
  const { ui, locale } = useT();
  const queryClient = useQueryClient();
  const [result, setResult] = useState<AcceptResult | null>(null);

  const accept = useErpAction({
    fn: "erp_accept_interview",
    invalidates: ["erp_interview_sessions", "erp_change_set_items", "erp_proposals"],
    // Putting changes in force changes what every other screen can show.
    onDone: (raw) => {
      setResult(readAccept(raw));
      void queryClient.invalidateQueries();
    },
  });

  // Only for naming things in the sentences below; a failure here costs the
  // labels, not the page.
  const questions = useQuery({
    queryKey: ["erp_interview_questions", session.session_id],
    queryFn: async () =>
      readQuestions(
        await callErp<unknown>("erp_interview_questions", { p_session_id: session.session_id }),
      ),
    retry: false,
  });
  const names = namesFromQuestions(questions.data ?? []);

  const pending = pendingProposals(session.proposals, live);
  const someApproved = session.proposals.some(
    (p) => statusKind(p.change_set_status) === "approved",
  );
  const allInForce =
    session.proposals.length > 0 &&
    session.proposals.every((p) => statusKind(p.change_set_status) === "in_force");
  const stepFor = (section: string) => result?.steps.find((s) => s.step === section) ?? null;
  const finance =
    result?.steps.find((s) => s.step === "finance" && outcomeKind(s) !== "not_needed") ?? null;
  const hasOrganisation = session.proposals.some((p) => p.section === "B.7");

  return (
    <>
      <Card>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <h2 className="font-display text-lg font-semibold">
              {ui("What your answers propose")}
            </h2>
            <p className="mt-0.5 text-xs text-muted-foreground">
              <span className="font-mono">{session.code}</span>
              {session.proposed_at
                ? ` · ${new Date(session.proposed_at).toLocaleString(locale)}`
                : null}
            </p>
          </div>
          <ActionButton variant="secondary" onClick={onBack}>
            <ChevronLeft className="mr-1 size-4" aria-hidden="true" />
            {ui("Back to interviews")}
          </ActionButton>
        </div>
        <p className="mt-3 text-sm text-muted-foreground">
          {live
            ? ui(
                "This organisation is live, so a second administrator approves these changes before they are in force. Nothing below changes anything until then.",
              )
            : ui(
                "This organisation is not live yet, so accepting puts these changes in force straight away, in order: your organisation first, then the books, departments, approvals and the rest.",
              )}
        </p>
      </Card>

      {session.status !== "proposed" ? (
        <Card>
          <p className="text-sm text-muted-foreground">
            {ui("Getting what your answers propose…")}
          </p>
        </Card>
      ) : session.proposals.length === 0 ? (
        <Card>
          <p className="text-sm text-muted-foreground">
            {ui("Nothing was proposed from this interview.")}
          </p>
        </Card>
      ) : (
        <ol className="flex min-w-0 flex-col gap-3">
          {finance && !hasOrganisation ? (
            <li>
              <FinanceCard step={finance} />
            </li>
          ) : null}
          {session.proposals.map((p) => (
            <Fragment key={p.proposal_id}>
              <li>
                <ProposalCard proposal={p} names={names} step={stepFor(p.section)} />
              </li>
              {finance && p.section === "B.7" ? (
                <li>
                  <FinanceCard step={finance} />
                </li>
              ) : null}
            </Fragment>
          ))}
        </ol>
      )}

      {session.status === "proposed" && session.proposals.length > 0 ? (
        <Card id="interview-accept">
          {result ? (
            <p className="text-sm">
              {ui("In force")}: {result.landed} · {ui("Waiting")}: {result.waiting} ·{" "}
              {ui("Needs attention")}: {result.refused}
            </p>
          ) : null}
          {accept.error ? (
            <div className="mt-3">
              <ErrorNote error={accept.error} />
            </div>
          ) : null}
          {pending.length > 0 ? (
            <>
              <p className="mt-2 text-sm text-muted-foreground">
                {live
                  ? ui(
                      "Sending these for approval puts them in front of another administrator on Configuration. Nothing changes until they approve.",
                    )
                  : ui(
                      "This puts every change above in force, in order. A change that cannot go in yet is reported on its card with what to do, and the rest still go in.",
                    )}
              </p>
              <div className="mt-3">
                <ActionButton
                  onClick={() => accept.mutate({ p_session_id: session.session_id })}
                  busy={accept.isPending}
                >
                  {accept.isPending
                    ? ui("Working…")
                    : live
                      ? ui("Send for approval")
                      : ui("Put these changes in force")}
                </ActionButton>
              </div>
            </>
          ) : (
            <p className="mt-2 text-sm text-muted-foreground">
              {allInForce
                ? ui("Everything this interview proposed is in force.")
                : someApproved
                  ? ui(
                      "Nothing here is waiting for you. A change waiting for approval is approved on Configuration, and an approved change is put in force there.",
                    )
                  : ui(
                      "Nothing here is waiting for you. A change waiting for approval is approved on Configuration.",
                    )}
            </p>
          )}
        </Card>
      ) : null}
    </>
  );
}

function FinanceCard({ step }: { step: AcceptStep }) {
  const { ui } = useT();
  return (
    <article className="min-w-0 rounded-xl border border-dashed border-border bg-card/60 p-4 sm:p-5">
      <h3 className="text-sm font-semibold">{ui("Setting up the books")}</h3>
      <p className="mt-1 text-xs text-muted-foreground">
        {outcomeKind(step) === "chart_in_place"
          ? ui(
              "You chose statutory numbering, so its nominal accounts are added now. The books themselves are set up when you accept accounting codes.",
            )
          : ui(
              "Accounting codes need books to post to, so the books are set up for each company that has none, with nominal accounts numbered the way you chose.",
            )}
      </p>
      <StepOutcome step={step} />
    </article>
  );
}

function ProposalCard({
  proposal,
  names,
  step,
}: {
  proposal: SessionProposal;
  names: Names;
  step: AcceptStep | null;
}) {
  const { ui, locale } = useT();
  const [all, setAll] = useState(false);
  const changeSetId = proposal.change_set_id;
  const items = useQuery({
    queryKey: ["erp_change_set_items", changeSetId],
    queryFn: async () =>
      readItems(await callErp<unknown>("erp_change_set_items", { p_change_set_id: changeSetId })),
    enabled: changeSetId !== null,
  });
  const kind = statusKind(proposal.change_set_status);
  const tone =
    kind === "in_force"
      ? "ok"
      : kind === "not_applied"
        ? "bad"
        : kind === "proposed"
          ? "muted"
          : "warn";
  const rows = items.data ?? [];
  const shown = all ? rows : rows.slice(0, ITEM_LIMIT);

  return (
    <article className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="text-sm font-semibold">{sectionText(proposal.section, ui).title}</h3>
        <Pill tone={tone}>{statusText(proposal.change_set_status, ui)}</Pill>
        <span className="text-xs text-muted-foreground">({proposal.item_count})</span>
      </div>

      {changeSetId === null ? null : items.isPending ? (
        <p className="mt-2 text-sm text-muted-foreground">{ui("Loading the changes…")}</p>
      ) : items.error ? (
        <div className="mt-2">
          <ErrorNote error={items.error} />
        </div>
      ) : (
        <ul className="mt-2 flex list-disc flex-col gap-1 pl-5 text-sm">
          {shown.map((item) => (
            <li key={item.item_id} className="break-words">
              {describeItem(item, ui, { locale, names })}
            </li>
          ))}
        </ul>
      )}
      {rows.length > ITEM_LIMIT ? (
        <button
          type="button"
          onClick={() => setAll((v) => !v)}
          aria-expanded={all}
          className={`${TOUCH} text-xs font-medium text-muted-foreground underline underline-offset-2 hover:text-foreground`}
        >
          {all ? ui("Show fewer changes") : ui("Show every change")}
        </button>
      ) : null}

      {step ? <StepOutcome step={step} /> : null}

      {changeSetId !== null ? (
        <p className="mt-3 text-xs">
          <Link
            to="/administration/configuration"
            search={{ change: changeSetId }}
            className="font-medium text-accent underline underline-offset-2"
          >
            {ui("See this change on Configuration")}
          </Link>
        </p>
      ) : null}
    </article>
  );
}

function StepOutcome({ step }: { step: AcceptStep }) {
  const { ui } = useT();
  const line = (icon: ReactNode, words: string, tone: string) => (
    <p className={`mt-3 flex items-start gap-2 text-sm font-medium ${tone}`}>
      {icon}
      <span className="min-w-0">{words}</span>
    </p>
  );
  const ok = "text-emerald-700 dark:text-emerald-400";
  const waiting = "text-amber-700 dark:text-amber-400";
  const clock = <Clock className="mt-0.5 size-4 shrink-0" aria-hidden="true" />;
  const check = <Check className="mt-0.5 size-4 shrink-0" aria-hidden="true" />;

  switch (outcomeKind(step)) {
    case "in_force":
      return line(check, ui("In force"), ok);
    case "books_set_up":
      return line(check, ui("The books are set up"), ok);
    case "chart_in_place":
      return line(check, ui("The nominal accounts are in place"), ok);
    case "waiting_second":
      return line(clock, ui("Waiting for a second administrator to approve"), waiting);
    case "approved_waiting":
      return line(clock, ui("Approved, waiting to be put in force on Configuration"), waiting);
    case "waiting_approval":
      return line(
        clock,
        ui("Waiting for approval from the people your approval rules name"),
        waiting,
      );
    case "waiting_section":
      return line(
        clock,
        fill(ui("Waiting for {section} to go in first"), {
          section: sectionText(step.waits_for ?? "", ui).title,
        }),
        waiting,
      );
    case "needs_attention":
      return (
        <div className="mt-3 flex flex-col gap-2">
          {line(
            <TriangleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />,
            ui("Needs attention"),
            "text-destructive",
          )}
          {step.refusal ? <ErrorNote error={refusalError(step.refusal)} /> : null}
        </div>
      );
    case "not_acceptable":
      return line(
        <TriangleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />,
        ui("This change can no longer be put in force. Start a new interview to propose it again."),
        "text-destructive",
      );
    default:
      return line(check, ui("Nothing to do here"), "text-muted-foreground");
  }
}
