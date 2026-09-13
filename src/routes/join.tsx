import { Navigate, createFileRoute, useNavigate } from "@tanstack/react-router";
import { friendlyError } from "@/lib/errors";
import { useEffect, useState, type ReactNode } from "react";

import { Centred, Gate, GoogleGlyph, SignIn } from "../components/erp/gate";
import { Wordmark } from "../components/erp/logo";
import { useErpSession } from "../components/erp/session-context";
import { callInvite, supabase, supabaseUrl } from "../lib/erp";
import { readJoinArrival, verifiedSignInLink, type JoinArrival } from "../lib/invitation-email";
import {
  clearStoredInvitation,
  readStoredInvitation,
  storeInvitation,
} from "../lib/invitation-token";

/**
 * Where an invitation email lands.
 *
 * The link is /join#invitation=<token>&signin=<link>, and everything after the
 * # stays in the browser: no server, log or link scanner sees the token or the
 * one-time sign-in link, and a scanner that fetches the page follows nothing,
 * because signing in takes a press of the button.
 *
 * On arrival the page keeps the token for this tab (lib/invitation-token.ts)
 * and takes both out of the address bar. Then, through the ordinary gate:
 *
 *   signed out     one button, which follows the sign-in link to Supabase
 *                  Auth. Auth signs the person in and sends them back here,
 *                  where the gate's onboarding screen asks them to join as the
 *                  account they are signed in with, and the desk opens once
 *                  they press Join. A link that has expired — they last an
 *                  hour or so, the invitation a week or two — comes back as an
 *                  error, and the page offers to email a new one, or Google, or
 *                  a password. So does a link an inviter copied, which never
 *                  had a sign-in part.
 *   no organisation the onboarding screen offers the held invitation, naming the
 *                  signed-in account, and redeems it only when Join is pressed:
 *                  a token in this tab does not say whose sign-in it is for.
 *   inside one     a sign-in belongs to one organisation, so this one cannot
 *                  accept somebody else's invitation: the page says so and
 *                  offers to sign out, or, with nothing held, opens the desk.
 */

export const Route = createFileRoute("/join")({
  head: () => ({
    meta: [
      { title: "Join your organisation — Clove ERP" },
      {
        name: "description",
        content: "Accept an invitation to an organisation on Clove ERP.",
      },
      // A private door with a secret in its address: never indexed, and never
      // named to another site in a Referer header.
      { name: "robots", content: "noindex, nofollow" },
      { name: "referrer", content: "no-referrer" },
    ],
  }),
  component: JoinPage,
});

const NOTHING: JoinArrival = { invitation: null, signin: null, failure: null };

function JoinPage() {
  // Read on the first client render, before anything tidies the address. The
  // server has no address bar, and the gate renders its loading state there
  // whatever this holds, so the two never disagree about the markup.
  const [arrival] = useState<JoinArrival>(() =>
    typeof window === "undefined"
      ? NOTHING
      : readJoinArrival(window.location.hash, window.location.search),
  );

  useEffect(() => {
    if (arrival.invitation) storeInvitation(arrival.invitation);
    // Out of the address bar, so neither the token nor a spent sign-in link
    // sits in history or goes along when the address is copied. Only when this
    // page's own parameters or Auth's error are there: a session Auth sent
    // back is supabase-js's to read and clear, not this page's.
    if (!arrival.invitation && !arrival.signin && !arrival.failure) return;
    try {
      const url = new URL(window.location.href);
      for (const name of ["error", "error_code", "error_description"]) {
        url.searchParams.delete(name);
      }
      window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}`);
    } catch {
      /* the address stays as it was; nothing depends on tidying it */
    }
  }, [arrival]);

  return (
    <Gate signedOut={<JoinSignedOut arrival={arrival} />}>
      <SignedInAlready />
    </Gate>
  );
}

const PRIMARY =
  "mt-5 inline-flex w-full items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60";

function Card({ children }: { children: ReactNode }) {
  return (
    <Centred>
      <section className="rounded-xl border border-border bg-card p-6">
        <Wordmark size={30} />
        {children}
      </section>
    </Centred>
  );
}

function JoinSignedOut({ arrival }: { arrival: JoinArrival }) {
  // The token from the address, or the one held from the visit that went to
  // Auth and came back with an error.
  const [token] = useState<string | null>(() => arrival.invitation ?? readStoredInvitation());
  const signin = arrival.failure ? null : verifiedSignInLink(arrival.signin, supabaseUrl);

  const [password, setPassword] = useState(false);
  const [resend, setResend] = useState<"idle" | "sending" | "sent" | "not-sent">("idle");
  const [googleError, setGoogleError] = useState<string | null>(null);

  if (!token) {
    return (
      <SignIn
        returnPath="/join"
        notice={
          <Notice>
            This page accepts an invitation, and this visit did not bring one. Open the link in your
            invitation email again, or sign in below.
          </Notice>
        }
      />
    );
  }

  if (password) {
    return (
      <SignIn
        returnPath="/join"
        notice={
          <Notice>
            Sign in with the address your invitation was sent to, then join the organisation.{" "}
            <button
              type="button"
              onClick={() => setPassword(false)}
              className="font-medium underline underline-offset-2"
            >
              Back
            </button>
          </Notice>
        }
      />
    );
  }

  async function emailMeALink(held: string) {
    setResend("sending");
    try {
      const answer = await callInvite({ resend_token: held });
      setResend(answer.sent === true ? "sent" : "not-sent");
    } catch {
      setResend("not-sent");
    }
  }

  async function continueWithGoogle() {
    setGoogleError(null);
    if (!supabase) return;
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: `${window.location.origin}/join` },
    });
    // On success the browser has gone to Google; only a failure returns here.
    if (error) setGoogleError(friendlyError(error).body ?? friendlyError(error).title);
  }

  return (
    <Card>
      <h1 className="mt-4 text-lg font-semibold">
        {arrival.failure ? "That sign-in link has expired" : "Join your organisation"}
      </h1>
      <p className="mt-1 text-sm text-muted-foreground">
        {arrival.failure
          ? "A sign-in link works once and only for a short while, so it runs out long before the invitation does. Your invitation is still here."
          : signin
            ? "You have been invited to Clove ERP. Continue to sign in with the address the invitation was sent to, then join the organisation that invited you."
            : "You have been invited to Clove ERP. Sign in with the address the invitation was sent to, then join the organisation that invited you."}
      </p>

      {signin ? (
        <button type="button" onClick={() => window.location.assign(signin)} className={PRIMARY}>
          Sign in and join
        </button>
      ) : resend === "sent" ? (
        <p
          role="status"
          className="mt-5 rounded-md border border-primary/40 bg-primary/5 p-3 text-sm"
        >
          A sign-in link is on its way to the address the invitation was sent to. Open the newest
          email from Clove ERP to join.
        </p>
      ) : (
        <>
          <button
            type="button"
            onClick={() => void emailMeALink(token)}
            disabled={resend === "sending"}
            className={PRIMARY}
          >
            {resend === "sending"
              ? "Sending…"
              : arrival.failure
                ? "Email me a new sign-in link"
                : "Email me a sign-in link"}
          </button>
          {resend === "not-sent" ? (
            <p role="alert" className="mt-3 text-sm text-muted-foreground">
              No link could be sent. The invitation may have been used, replaced by a newer one or
              expired, in which case whoever invited you can send it again. A new link can be sent
              only every few minutes and only a few times, so if one was sent recently, use the
              newest email from Clove ERP or try again later.
            </p>
          ) : null}
        </>
      )}

      <div className="my-4 flex items-center gap-3 text-xs text-muted-foreground">
        <span className="h-px flex-1 bg-border" />
        or
        <span className="h-px flex-1 bg-border" />
      </div>

      <button
        type="button"
        onClick={() => void continueWithGoogle()}
        className="flex w-full items-center justify-center gap-2 rounded-md border border-input bg-background px-4 py-2 text-sm font-medium hover:bg-muted"
      >
        <GoogleGlyph />
        Continue with Google
      </button>
      {googleError ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {googleError}
        </p>
      ) : null}

      <p className="mt-4 text-center text-xs text-muted-foreground">
        <button
          type="button"
          onClick={() => setPassword(true)}
          className="underline underline-offset-2"
        >
          Sign in with a password instead
        </button>
      </p>
      <p className="mt-2 text-center text-xs text-muted-foreground">
        Not expecting an invitation? Close this page; nothing happens unless you sign in and choose
        to join.
      </p>
    </Card>
  );
}

function Notice({ children }: { children: ReactNode }) {
  return (
    <div className="mb-4 rounded-xl border border-primary/40 bg-primary/5 p-4 text-sm text-muted-foreground">
      {children}
    </div>
  );
}

/**
 * Signed in, and already inside an organisation.
 *
 * With nothing held, this is somebody who opened /join by hand: the desk. With
 * an invitation held, it was meant for a person who is not the one signed in
 * here — a sign-in belongs to one organisation, and erp.claim_invitation
 * refuses one that is already bound — so the page says so rather than dropping
 * it, and offers the two ways on.
 */
function SignedInAlready() {
  const { session } = useErpSession();
  const navigate = useNavigate();
  const [held] = useState<string | null>(readStoredInvitation);
  const [leaving, setLeaving] = useState(false);

  if (!held) return <Navigate to="/" replace />;

  const who = session.principal?.display_name;
  const where = session.tenant?.name;

  return (
    <section className="mx-auto w-full max-w-lg rounded-xl border border-primary/40 bg-primary/5 p-6">
      <h1 className="text-lg font-semibold">You are already signed in</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        This browser is signed in{who ? ` as ${who}` : ""}
        {where ? `, in ${where}` : ""}. A sign-in belongs to one organisation, so this account
        cannot accept an invitation into another. If the invitation went to a different address,
        sign out and accept it signed in with that one.
      </p>
      <div className="mt-4 flex flex-wrap gap-2">
        <button
          type="button"
          disabled={leaving}
          onClick={() => {
            setLeaving(true);
            void supabase?.auth.signOut().finally(() => setLeaving(false));
          }}
          className="inline-flex items-center justify-center rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
        >
          {leaving ? "Signing out…" : "Sign out and accept it"}
        </button>
        <button
          type="button"
          onClick={() => {
            clearStoredInvitation();
            void navigate({ to: "/", replace: true });
          }}
          className="inline-flex items-center justify-center rounded-md border border-input px-4 py-2 text-sm font-medium"
        >
          Go to my desk
        </button>
      </div>
    </section>
  );
}
