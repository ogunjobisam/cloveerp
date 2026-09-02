import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useState } from "react";

import { ErrorNote, PermissionNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";

/**
 * The onboarding interview.
 *
 * The questions are not in this file, on purpose. They are rows in
 * erp_ref.interview_question — which surface each feeds, what shape of answer
 * it takes, and which earlier answer gates it — so adding a question is a
 * migration rather than a deployment. In a product whose thesis is that
 * behaviour is configured rather than coded, six hard-coded question lists here
 * would have been the one place that isn't.
 *
 * Nothing on this screen writes configuration. Answering records an answer;
 * proposing turns the answers into change sets and the proposals that explain
 * them. Approval and promotion happen on Configuration, through the same doors
 * a hand-written change set goes through — the interview adds a producer, not a
 * second way to change things.
 */

export const Route = createFileRoute("/administration/onboarding")({
  head: () => ({
    meta: [
      { title: "Onboarding interview — Clove ERP" },
      {
        name: "description",
        content:
          "Answer questions about how the organisation works, and get a reviewable change set for each Addendum B configuration surface.",
      },
      { property: "og:title", content: "Onboarding interview — Clove ERP" },
      { property: "og:description", content: "Answer questions about how the organisation works, and get a reviewable change set for each Addendum B configuration surface." },
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

type Question = {
  code: string;
  section: string;
  surface: string;
  seq: number;
  prompt: string;
  help: string | null;
  answer_shape: string;
  choices: string[] | null;
  maps_to: string | null;
  is_required: boolean;
  applies: boolean;
  answer: unknown;
};

type Proposal = {
  proposal_id: string;
  title: string;
  rationale: string;
  status: string;
  change_set_id: string | null;
  change_set_code: string | null;
  change_set_status: string | null;
  item_count: number;
  producer_label: string | null;
  evidence: { source_kind: string; source_ref: string; observation: string }[];
};

const SECTION_TITLE: Record<string, string> = {
  "B.1": "Departments",
  "B.2": "Approvals",
  "B.3": "Posting classes and accounts",
  "B.4": "Classification",
  "B.5": "Item codes",
  "B.6": "Release areas",
};

/** What the database expects for each answer shape, built from what was typed. */
function toAnswer(shape: string, raw: string): unknown {
  switch (shape) {
    case "boolean":
      return raw === "true";
    case "integer":
    case "money":
      return Number(raw);
    case "text_list":
      return raw
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean);
    case "text_pairs":
      return raw
        .split("\n")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((line) => {
          const [left = "", ...rest] = line.split("/");
          return { left: left.trim(), right: rest.join("/").trim() };
        })
        .filter((p) => p.left && p.right);
    default:
      return raw;
  }
}

/** And back, so an answer already given is shown as it was typed. */
function fromAnswer(shape: string, answer: unknown): string {
  if (answer === null || answer === undefined) return "";
  if (shape === "text_list" && Array.isArray(answer)) return answer.join("\n");
  if (shape === "text_pairs" && Array.isArray(answer)) {
    return (answer as { left: string; right: string }[])
      .map((p) => `${p.left} / ${p.right}`)
      .join("\n");
  }
  if (shape === "boolean") return answer ? "true" : "false";
  return String(answer);
}

function QuestionRow({
  q,
  sessionId,
  onAnswered,
}: {
  q: Question;
  sessionId: string;
  onAnswered: () => void;
}) {
  const [raw, setRaw] = useState(() => fromAnswer(q.answer_shape, q.answer));

  const save = useMutation({
    mutationFn: () =>
      callErp("erp_answer_interview", {
        p_session_id: sessionId,
        p_question_code: q.code,
        p_answer: toAnswer(q.answer_shape, raw),
      }),
    onSuccess: onAnswered,
  });

  const multiline = q.answer_shape === "text_list" || q.answer_shape === "text_pairs";

  return (
    <li className="border-b border-border/60 py-4 last:border-0">
      <label className="block text-sm font-medium" htmlFor={q.code}>
        {q.prompt}
        {q.is_required ? <span className="ml-1 text-muted-foreground">(required)</span> : null}
      </label>
      {q.help ? <p className="mt-1 text-xs text-muted-foreground">{q.help}</p> : null}

      <div className="mt-2 flex flex-wrap items-start gap-2">
        {q.answer_shape === "boolean" ? (
          <select
            id={q.code}
            value={raw || "false"}
            onChange={(e) => setRaw(e.target.value)}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="false">No</option>
            <option value="true">Yes</option>
          </select>
        ) : q.answer_shape === "choice" ? (
          <select
            id={q.code}
            value={raw}
            onChange={(e) => setRaw(e.target.value)}
            className="rounded-md border border-input bg-background px-3 py-2 text-sm"
          >
            <option value="">—</option>
            {(q.choices ?? []).map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        ) : multiline ? (
          <textarea
            id={q.code}
            value={raw}
            rows={3}
            onChange={(e) => setRaw(e.target.value)}
            className="min-w-0 flex-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        ) : (
          <input
            id={q.code}
            value={raw}
            inputMode={
              q.answer_shape === "integer" || q.answer_shape === "money" ? "numeric" : "text"
            }
            onChange={(e) => setRaw(e.target.value)}
            className="min-w-0 flex-1 rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        )}

        <button
          type="button"
          onClick={() => save.mutate()}
          disabled={save.isPending}
          className={`${TOUCH} rounded-md border border-border px-3 text-sm font-medium hover:bg-muted disabled:opacity-60`}
        >
          {save.isPending ? "Saving…" : q.answer === null ? "Answer" : "Change"}
        </button>
      </div>

      {save.error ? (
        <div className="mt-2">
          <ErrorNote error={save.error} />
        </div>
      ) : null}
    </li>
  );
}

function Onboarding() {
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const [sessionId, setSessionId] = useState<string | null>(null);
  const mayConfigure = hasPermission(session, "administration.configure");

  const questions = useQuery({
    queryKey: ["erp_interview_questions", sessionId],
    queryFn: () => callErp<Question[]>("erp_interview_questions", { p_session_id: sessionId }),
    enabled: sessionId !== null,
  });

  const proposals = useQuery({
    queryKey: ["erp_proposals"],
    queryFn: () => callErp<Proposal[]>("erp_proposals"),
  });

  const start = useMutation({
    mutationFn: () => callErp<{ session_id: string }>("erp_start_interview", { p_code: null }),
    onSuccess: (r) => setSessionId(r.session_id),
  });

  const propose = useMutation({
    mutationFn: () => callErp("erp_propose_from_interview", { p_session_id: sessionId }),
    onSuccess: () => {
      setSessionId(null);
      void queryClient.invalidateQueries({ queryKey: ["erp_proposals"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_change_sets"] });
    },
  });

  const asked = (questions.data ?? []).filter((q) => q.applies);
  const sections = [...new Set(asked.map((q) => q.section))];
  const answered = asked.filter((q) => q.answer !== null).length;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Onboarding interview">
        Questions about how this organisation actually works, and a reviewable change set for each
        answer that turns into one. Nothing here changes configuration: proposing raises a change
        set, and Configuration is where it is approved and promoted, exactly as a hand-written one
        is.
      </PageHeader>

      {!mayConfigure ? <PermissionNote code="administration.configure" /> : null}

      {sessionId === null ? (
        <div className="rounded-lg border border-border bg-card p-5">
          <Prose>
            An interview asks about the six Addendum B surfaces — departments, approvals, posting
            classes, classification, item codes and release areas — and proposes one change set per
            section that has answers. Later questions appear as earlier ones are answered, so a
            section you have no use for is not asked about.
          </Prose>
          {start.error ? (
            <div className="mt-3">
              <ErrorNote error={start.error} />
            </div>
          ) : null}
          <button
            type="button"
            onClick={() => start.mutate()}
            disabled={!mayConfigure || start.isPending}
            className={`${TOUCH} mt-4 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
          >
            {start.isPending ? "Starting…" : "Start an interview"}
          </button>
        </div>
      ) : questions.isPending ? (
        <div className="rounded-lg border border-border bg-card p-5">
          <p className="text-sm text-muted-foreground">Loading the questions…</p>
        </div>
      ) : questions.error ? (
        /* Without this the screen rendered a failed read as "0 of 0 questions
           answered", which reads as an empty question bank and is the one
           thing it was not. The interview is nineteen rows of product content;
           if none arrive, something refused, and the refusal is the news. */
        <div className="rounded-lg border border-border bg-card p-5">
          <ErrorNote error={questions.error} />
        </div>
      ) : asked.length === 0 ? (
        <div className="rounded-lg border border-border bg-card p-5">
          <p className="text-sm text-muted-foreground">
            The interview returned no questions to ask. That is not an empty question bank — every
            question is gated on an earlier answer or on a permission, so this means none applied.
          </p>
        </div>
      ) : (
        <div className="flex flex-col gap-5">
          {sections.map((s) => (
            <div key={s} className="rounded-lg border border-border bg-card p-5">
              <h2 className="font-display text-base font-semibold">
                {SECTION_TITLE[s] ?? s}
                <span className="ml-2 text-xs font-normal text-muted-foreground">{s}</span>
              </h2>
              <ul className="mt-2">
                {asked
                  .filter((q) => q.section === s)
                  .map((q) => (
                    <QuestionRow
                      key={q.code}
                      q={q}
                      sessionId={sessionId}
                      onAnswered={() =>
                        void queryClient.invalidateQueries({
                          queryKey: ["erp_interview_questions"],
                        })
                      }
                    />
                  ))}
              </ul>
            </div>
          ))}

          <div className="rounded-lg border border-border bg-card p-5">
            <p className="text-sm text-muted-foreground">
              {answered} of {asked.length} questions answered. Proposing turns what you have said
              into one change set per section — you review the diff before anything is promoted.
            </p>
            {propose.error ? (
              <div className="mt-3">
                <ErrorNote error={propose.error} />
              </div>
            ) : null}
            <button
              type="button"
              onClick={() => propose.mutate()}
              disabled={!mayConfigure || propose.isPending || answered === 0}
              className={`${TOUCH} mt-4 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
            >
              {propose.isPending ? "Proposing…" : "Propose the changes"}
            </button>
          </div>
        </div>
      )}

      <div className="rounded-lg border border-border bg-card p-5">
        <h2 className="font-display text-base font-semibold">Proposals</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Each one points at a change set. Approve and promote it on Configuration.
        </p>

        {proposals.isPending ? (
          <p className="mt-3 text-sm text-muted-foreground">Loading…</p>
        ) : proposals.error ? (
          <div className="mt-3">
            <ErrorNote error={proposals.error} />
          </div>
        ) : (proposals.data ?? []).length === 0 ? (
          <p className="mt-3 text-sm text-muted-foreground">Nothing proposed yet.</p>
        ) : (
          <ul className="mt-3 flex flex-col gap-4">
            {(proposals.data ?? []).map((p) => (
              <li key={p.proposal_id} className="border-b border-border/60 pb-4 last:border-0">
                <div className="flex flex-wrap items-center gap-2">
                  <Pill tone={p.change_set_status === "promoted" ? "ok" : "warn"}>{p.status}</Pill>
                  <span className="text-sm font-medium">{p.title}</span>
                  <span className="text-xs text-muted-foreground">
                    {p.item_count} item{p.item_count === 1 ? "" : "s"}
                  </span>
                </div>
                <p className="mt-1 text-sm text-muted-foreground">{p.rationale}</p>
                {p.change_set_code ? (
                  <p className="mt-1 text-xs">
                    <Link to="/administration/configuration" className="underline">
                      {p.change_set_code}
                    </Link>{" "}
                    <span className="text-muted-foreground">· {p.change_set_status}</span>
                  </p>
                ) : null}
                {p.evidence.length > 0 ? (
                  <details className="mt-2">
                    <summary className="cursor-pointer text-xs text-muted-foreground">
                      What it was based on ({p.evidence.length})
                    </summary>
                    <ul className="mt-2 flex flex-col gap-1">
                      {p.evidence.map((e, i) => (
                        <li key={`${p.proposal_id}-${i}`} className="text-xs text-muted-foreground">
                          {e.observation}
                        </li>
                      ))}
                    </ul>
                  </details>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
