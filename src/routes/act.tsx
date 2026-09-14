import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";

import { Gate, SignIn } from "../components/erp/gate";
import { useErpSession } from "../components/erp/session-context";
import {
  actView,
  clearStoredAction,
  explain,
  outcomeWords,
  readActArrival,
  readStoredAction,
  storeAction,
  summaryRows,
  viewForRefusal,
  type ActArrival,
  type ActDecision,
  type ActView,
  type EmailActionPeek,
} from "../lib/email-action";
import { callErp, supabase } from "../lib/erp";
import { friendlyError } from "../lib/errors";

/**
 * Where an approval email's Approve and Reject buttons land.
 *
 * The link is /act#t=<token>&d=approve|reject. The token only finds the task:
 * it signs nobody in and decides nothing. Everything after the # stays in the
 * browser, so no server, log or link scanner receives it, and a scanner that
 * opens the page decides nothing, because deciding takes a press of the button
 * by somebody signed in.
 *
 * On arrival the page keeps the link for this tab (lib/email-action.ts) and
 * takes it out of the address bar. Then, through the ordinary gate:
 *
 *   signed out        the sign-in screen, which brings the person back here.
 *   the wrong person  erp_email_action_peek answers only the person the email
 *                     was sent to, so anybody else is told the link is not for
 *                     them, and nothing about the request.
 *   another company   the request belongs to another organisation the person
 *                     works in: one press switches, as the account menu does.
 *   the right place   what is being asked, and one button, Approve or Reject.
 *                     A rejection needs a reason. erp_decide_approval_from_email
 *                     decides it as the signed-in person, under every rule a
 *                     decision at the desk is under.
 *   moved on          a link that ran out, was used, or whose request changed
 *                     or was decided says so, and offers the request itself.
 *
 * The words are the page's own, as /join's are: it is a landing page for one
 * email, not a screen an organisation renames.
 */

export const Route = createFileRoute("/act")({
  head: () => ({
    meta: [
      { title: "Approve or reject a request — Clove ERP" },
      {
        name: "description",
        content: "Decide an approval request from an email, signed in as yourself.",
      },
      // A private door with a secret in its address: never indexed, and never
      // named to another site in a Referer header.
      { name: "robots", content: "noindex, nofollow" },
      { name: "referrer", content: "no-referrer" },
    ],
  }),
  component: ActPage,
});

const NOTHING: ActArrival = { token: null, decision: null };

function ActPage() {
  // Read on the first client render, before anything tidies the address. The
  // server has no address bar, and the gate renders its loading state there
  // whatever this holds.
  const [arrival] = useState<ActArrival>(() =>
    typeof window === "undefined" ? NOTHING : readActArrival(window.location.hash),
  );

  useEffect(() => {
    if (arrival.token) storeAction(arrival);
    // Out of the address bar, so the token neither sits in history nor goes
    // along when the address is copied. Only this page's own parameters: a
    // session Auth sent back in the fragment is supabase-js's to read.
    if (!arrival.token && !/(^#|&)(t|d)=/.test(window.location.hash)) return;
    try {
      window.history.replaceState(
        window.history.state,
        "",
        `${window.location.pathname}${window.location.search}`,
      );
    } catch {
      /* the address stays as it was; nothing depends on tidying it */
    }
  }, [arrival]);

  return (
    <Gate
      signedOut={
        <SignIn
          returnPath="/act"
          notice={
            <Notice>
              Sign in to decide the request from your email. The link only finds the request: it is
              decided by you, signed in as yourself, when you press the button.
            </Notice>
          }
        />
      }
    >
      <ActDesk arrival={arrival} />
    </Gate>
  );
}

type Decided = {
  status: string;
  decision: ActDecision;
  task_id: string;
  document_id: string | null;
};

const PRIMARY =
  "inline-flex min-h-11 items-center justify-center rounded-md bg-primary px-5 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60";
const SECONDARY =
  "inline-flex min-h-11 items-center justify-center rounded-md border border-input px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-60";

function ActDesk({ arrival }: { arrival: ActArrival }) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();

  // The link from the address, or the one held from before signing in.
  const [held] = useState<ActArrival>(() => (arrival.token ? arrival : readStoredAction()));
  const token = held.token;
  const [decision, setDecision] = useState<ActDecision | null>(held.decision);
  const [comment, setComment] = useState("");
  const [movedOn, setMovedOn] = useState<ActView | null>(null);

  const peek = useQuery({
    queryKey: ["erp_email_action_peek", token],
    queryFn: () => callErp<EmailActionPeek>("erp_email_action_peek", { p_token: token }),
    enabled: token !== null,
    retry: false,
  });

  const switchOrganisation = useMutation({
    mutationFn: (tenantId: string) => callErp("erp_set_active_tenant", { p_tenant_id: tenantId }),
    // Everything on screen is scoped to the organisation that just changed.
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const decide = useMutation({
    mutationFn: (v: { approve: boolean; reason: string }) =>
      callErp<Decided>("erp_decide_approval_from_email", {
        p_token: token,
        p_approve: v.approve,
        p_comment: v.reason.trim() === "" ? null : v.reason.trim(),
      }),
    onSuccess: () => {
      clearStoredAction();
      void queryClient.invalidateQueries({ queryKey: ["erp_my_approvals"] });
    },
    onError: (error) => {
      const view = viewForRefusal(error);
      if (view) {
        setMovedOn(view);
        void peek.refetch();
      }
    },
  });

  const view =
    movedOn ??
    actView({
      token,
      peek: peek.data,
      peekError: peek.error,
      pending: peek.isPending,
      sessionTenantId: session.tenant_id,
    });
  const found = peek.data;

  if (decide.data) {
    const done = decide.data;
    return (
      <Card>
        <h1 className="text-xl font-semibold">Decision recorded</h1>
        <p role="status" className="mt-2 text-sm text-muted-foreground">
          {outcomeWords(done.decision, done.status)}
        </p>
        <Onward taskId={done.task_id} documentId={done.document_id} />
      </Card>
    );
  }

  if (view === "usable" && found) {
    const rows = summaryRows(found, (iso) =>
      new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }),
    );
    const rejecting = decision === "reject";
    const failure =
      decide.error && !viewForRefusal(decide.error) ? friendlyError(decide.error) : null;
    return (
      <Card>
        <h1 className="text-xl font-semibold">
          {decision === "approve"
            ? "Approve this request"
            : decision === "reject"
              ? "Reject this request"
              : "Your approval is needed"}
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Check what is being asked. Nothing is decided until you press the button below.
        </p>

        <dl className="mt-4 divide-y divide-border rounded-lg border border-border text-sm">
          {rows.map((row) => (
            <div key={row.label} className="flex flex-wrap gap-x-4 gap-y-0.5 px-3 py-2">
              <dt className="w-40 shrink-0 text-muted-foreground">{row.label}</dt>
              <dd className="min-w-0 flex-1 break-words font-medium">{row.value}</dd>
            </div>
          ))}
        </dl>

        {decision === null ? (
          <div className="mt-5 flex flex-wrap gap-2">
            <button type="button" className={PRIMARY} onClick={() => setDecision("approve")}>
              Approve
            </button>
            <button type="button" className={SECONDARY} onClick={() => setDecision("reject")}>
              Reject
            </button>
          </div>
        ) : (
          <form
            className="mt-5 flex flex-col gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              decide.mutate({ approve: !rejecting, reason: comment });
            }}
          >
            <label className="flex flex-col gap-1 text-sm">
              <span className="font-medium">
                {rejecting ? "Why are you rejecting it?" : "Comment (optional)"}
              </span>
              <textarea
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                rows={3}
                required={rejecting}
                maxLength={2000}
                className="rounded-md border border-input bg-background px-3 py-2 text-sm"
              />
              {rejecting ? (
                <span className="text-xs text-muted-foreground">
                  The request goes back to whoever asked for it, with your reason.
                </span>
              ) : null}
            </label>

            {failure ? (
              <div
                role="alert"
                className="rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm"
              >
                <p className="font-medium">{failure.title}</p>
                {failure.body ? <p className="mt-1 text-muted-foreground">{failure.body}</p> : null}
                {failure.hint ? <p className="mt-1 text-muted-foreground">{failure.hint}</p> : null}
              </div>
            ) : null}

            <div className="flex flex-wrap items-center gap-3">
              <button
                type="submit"
                className={PRIMARY}
                disabled={decide.isPending || (rejecting && comment.trim() === "")}
              >
                {decide.isPending ? "Recording…" : rejecting ? "Reject" : "Approve"}
              </button>
              <button
                type="button"
                className="text-sm underline underline-offset-2"
                onClick={() => setDecision(rejecting ? "approve" : "reject")}
              >
                {rejecting ? "Approve instead" : "Reject instead"}
              </button>
            </div>
          </form>
        )}

        <Onward taskId={found.task_id} documentId={found.document_id} />
      </Card>
    );
  }

  const words = explain(view, found?.tenant_name ?? null);

  if (view === "wrong_organisation" && found) {
    const refused = switchOrganisation.error ? friendlyError(switchOrganisation.error) : null;
    return (
      <Card>
        <h1 className="text-xl font-semibold">{words.heading}</h1>
        <p className="mt-1 text-sm text-muted-foreground">{words.body}</p>
        <div className="mt-5 flex flex-wrap gap-2">
          <button
            type="button"
            className={PRIMARY}
            disabled={switchOrganisation.isPending}
            onClick={() => {
              setMovedOn(null);
              switchOrganisation.mutate(found.tenant_id);
            }}
          >
            {switchOrganisation.isPending
              ? "Switching…"
              : `Switch to ${found.tenant_name ?? "that organisation"}`}
          </button>
        </div>
        {refused ? (
          <p role="alert" className="mt-3 text-sm text-muted-foreground">
            {refused.title} Sign in with the account that belongs to that organisation to decide it.
          </p>
        ) : null}
      </Card>
    );
  }

  return (
    <Card>
      <h1 className="text-xl font-semibold">{words.heading}</h1>
      <p
        role={view === "checking" ? "status" : undefined}
        className="mt-1 text-sm text-muted-foreground"
      >
        {words.body}
      </p>
      {view === "not_for_you" ? (
        <div className="mt-5 flex flex-wrap gap-2">
          <button
            type="button"
            className={SECONDARY}
            onClick={() => {
              void supabase?.auth.signOut();
            }}
          >
            Sign out
          </button>
        </div>
      ) : null}
      {view === "checking" ? null : (
        <Onward
          taskId={view === "not_for_you" ? null : (found?.task_id ?? null)}
          documentId={view === "not_for_you" ? null : (found?.document_id ?? null)}
        />
      )}
    </Card>
  );
}

function Card({ children }: { children: ReactNode }) {
  return (
    <section className="mx-auto w-full min-w-0 max-w-2xl rounded-xl border border-border bg-card p-6">
      {children}
    </section>
  );
}

function Notice({ children }: { children: ReactNode }) {
  return (
    <div className="mb-4 rounded-xl border border-primary/40 bg-primary/5 p-4 text-sm text-muted-foreground">
      {children}
    </div>
  );
}

/** Where to go instead of, or after, deciding from the link. */
function Onward({ taskId, documentId }: { taskId: string | null; documentId: string | null }) {
  return (
    <p className="mt-5 flex flex-wrap gap-x-4 gap-y-2 text-sm">
      <Link
        to="/governance"
        search={taskId ? { task: taskId } : {}}
        className="font-medium underline underline-offset-2"
      >
        {taskId ? "Open the request in My approvals" : "Go to My approvals"}
      </Link>
      {documentId ? (
        <Link
          to="/documents/$documentId"
          params={{ documentId }}
          className="font-medium underline underline-offset-2"
        >
          Open the document
        </Link>
      ) : null}
    </p>
  );
}
