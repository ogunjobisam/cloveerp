import { friendlyError } from "@/lib/errors";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";

import { ResourceProvider } from "../../lib/i18n";
import { callErp, isConfigured, supabase, type ErpSession } from "../../lib/erp";
import {
  clearStoredInvitation,
  readStoredInvitation,
  storeInvitation,
} from "../../lib/invitation-token";
import { atLeast, usePlatformMe } from "../../lib/platform";
import { onboardingView, pastedToken, selfServiceIsOpen } from "../../lib/self-service";
import { Shell, type Scope } from "./shell";
import { ErpSessionContext } from "./session-context";
import { Wordmark } from "./logo";

/**
 * The auth boundary.
 *
 * Four states, and they are deliberately distinguished rather than collapsed
 * into "loading or not":
 *
 *   not configured  — the build has no project to talk to
 *   signed out      — no session
 *   no tenant       — authenticated, but the JWT subject resolves to no
 *                     erp.app_user row, so current_tenant_id() is null
 *   ready           — a tenant context exists
 *
 * The third is worth its own screen. It is what a correctly-signed-in person
 * sees when nobody has created their principal yet, and rendering an empty
 * dashboard there would send them looking for a bug in the data instead of an
 * administrator.
 */

export function Centred({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-md">{children}</div>
    </div>
  );
}

function NotConfigured() {
  return (
    <Centred>
      <h1 className="text-lg font-semibold">Not connected to a project</h1>
      <p className="mt-2 text-sm text-muted-foreground">
        This build has no Supabase project configured. Set{" "}
        <code className="rounded bg-muted px-1 py-0.5 text-xs">VITE_SUPABASE_URL</code> and{" "}
        <code className="rounded bg-muted px-1 py-0.5 text-xs">VITE_SUPABASE_PUBLISHABLE_KEY</code>,
        then reload.
      </p>
      <p className="mt-4 text-sm text-muted-foreground">
        <Link to="/product" className="underline underline-offset-2">
          View the product page
        </Link>
      </p>
    </Centred>
  );
}

export function GoogleGlyph() {
  return (
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden="true">
      <path
        fill="#FFC107"
        d="M43.6 20.1H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.9 1.2 8 3l5.7-5.7C34.5 6.1 29.5 4 24 4 13 4 4 13 4 24s9 20 20 20 20-9 20-20c0-1.3-.1-2.7-.4-3.9z"
      />
      <path
        fill="#FF3D00"
        d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.9 1.2 8 3l5.7-5.7C34.5 6.1 29.5 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"
      />
      <path
        fill="#4CAF50"
        d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-8l-6.5 5C9.5 39.6 16.2 44 24 44z"
      />
      <path
        fill="#1976D2"
        d="M43.6 20.1H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C36.9 39.2 44 34 44 24c0-1.3-.1-2.7-.4-3.9z"
      />
    </svg>
  );
}

export type SignInProps = {
  onSignedIn?: () => void;
  /** Said above the form, for a route that knows why the person is here. */
  notice?: ReactNode;
  /**
   * Where Google sends the browser back to, as a path on this site; the origin
   * when omitted. Supabase Auth honours a path on its Site URL's own host, or
   * one on its redirect allow-list, and otherwise quietly sends the browser to
   * the Site URL instead.
   */
  returnPath?: string;
};

/**
 * The sign-in screen, on its own so `/signin` can be a place you go.
 *
 * Inside `Gate` it needs no `onSignedIn`: the auth state changes, the gate
 * re-renders, and the route the person asked for is behind it. On its own
 * route there is nothing watching, so the caller says where to go next.
 */
export function SignIn({ onSignedIn, notice, returnPath }: SignInProps = {}) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [link, setLink] = useState<"idle" | "sending" | "sent" | "rate-limited">("idle");
  const emailField = useRef<HTMLInputElement>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase!.auth.signInWithPassword({ email, password });
    if (error) setError(friendlyError(error).body ?? friendlyError(error).title);
    else onSignedIn?.();
    setBusy(false);
  }

  /**
   * A sign-in link by email, for somebody with no password — everyone who
   * joined by invitation, until they set one on their profile.
   *
   * shouldCreateUser is false, so this signs in an account that exists and
   * makes none. The screen says the same thing whether the address has an
   * account or not, because saying otherwise would tell anybody who types an
   * address whether it is a customer's. The one failure it names is being
   * asked too often, which says nothing about the address and has a remedy.
   */
  async function emailMeASignInLink() {
    setError(null);
    // Only the email field has to be valid for this; the password is not used.
    if (!emailField.current?.reportValidity()) return;
    setLink("sending");
    let limited = false;
    try {
      const { error } = await supabase!.auth.signInWithOtp({
        email: email.trim(),
        options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
      });
      limited = error !== null && isRateLimited(error);
    } catch {
      /* the same answer as any other outcome */
    }
    setLink(limited ? "rate-limited" : "sent");
  }

  async function signInWithGoogle() {
    setBusy(true);
    setError(null);
    const { error } = await supabase!.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo: `${window.location.origin}${returnPath ?? ""}` },
    });
    // On success the browser navigates away to Google; only failures return here.
    if (error) setError(friendlyError(error).body ?? friendlyError(error).title);
    setBusy(false);
  }

  return (
    <Centred>
      {notice}
      <form onSubmit={submit} className="rounded-xl border border-border bg-card p-6">
        <Wordmark size={30} />
        <h1 className="mt-4 text-lg font-semibold">Sign in to Clove ERP</h1>

        <p className="mt-1 text-sm text-muted-foreground">
          Your organisation is derived from your account. It is never chosen here.
        </p>

        <label className="mt-5 block text-sm font-medium">
          Email
          <input
            type="email"
            required
            value={email}
            onChange={(e) => {
              setEmail(e.target.value);
              setLink("idle");
            }}
            ref={emailField}
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            autoComplete="username"
          />
        </label>

        <label className="mt-3 block text-sm font-medium">
          Password
          <input
            type="password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
            autoComplete="current-password"
          />
        </label>

        {error ? (
          <p role="alert" className="mt-3 text-sm text-destructive">
            {error}
          </p>
        ) : null}

        <button
          type="submit"
          disabled={busy || link === "sending"}
          className="mt-5 w-full rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>

        <div className="my-4 flex items-center gap-3 text-xs text-muted-foreground">
          <span className="h-px flex-1 bg-border" />
          or
          <span className="h-px flex-1 bg-border" />
        </div>

        <button
          type="button"
          onClick={signInWithGoogle}
          disabled={busy}
          className="flex w-full items-center justify-center gap-2 rounded-md border border-input bg-background px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-60"
        >
          <GoogleGlyph />
          Continue with Google
        </button>

        <button
          type="button"
          onClick={() => void emailMeASignInLink()}
          disabled={busy || link === "sending"}
          className="mt-3 w-full rounded-md border border-input bg-background px-4 py-2 text-sm font-medium hover:bg-muted disabled:opacity-60"
        >
          {link === "sending" ? "Sending…" : "Email me a sign-in link"}
        </button>
        {link === "sent" ? (
          <p role="status" className="mt-3 text-sm text-muted-foreground">
            If that address has an account, a sign-in link is on its way.
          </p>
        ) : link === "rate-limited" ? (
          <p role="alert" className="mt-3 text-sm text-destructive">
            Too many sign-in links have been asked for just now. Wait a minute, then try again.
          </p>
        ) : (
          <p className="mt-2 text-center text-xs text-muted-foreground">
            Joined by invitation and have no password? Enter your email and ask for a link.
          </p>
        )}

        <p className="mt-4 text-center text-xs text-muted-foreground">
          <Link to="/product" className="underline underline-offset-2">
            About Clove ERP
          </Link>
        </p>
      </form>
    </Centred>
  );
}

/** Supabase Auth refusing because it was asked too often — the one failure worth naming. */
function isRateLimited(error: {
  status?: number | undefined;
  code?: string | undefined;
  message: string;
}) {
  return (
    error.status === 429 ||
    error.code === "over_email_send_rate_limit" ||
    error.code === "over_request_rate_limit" ||
    /rate limit|too many requests/i.test(error.message)
  );
}

/**
 * The onboarding state: signed in, but resolving to no principal anywhere.
 *
 * Organisations come by invitation. Somebody already inside one creates a
 * principal for this person and sends them a single-use link; the platform's
 * own staff create new organisations from the console. So what this screen
 * offers depends on who is looking, and it is only ever a convenience: the
 * database refuses creating an organisation or a demo to anybody it should,
 * whatever is rendered here.
 *
 *   an invitation held    only the card that joins it. Somebody who arrived
 *                         through an invitation link, or pasted one, has said
 *                         what they are here for.
 *   nothing held          "You need an invitation": who they are signed in as,
 *                         who to ask, a box to paste a link into, and Sign out.
 *   platform operators    as well as the invitation hint, creating an
 *   and owners, or        organisation (which makes the caller its first
 *   self-service open     administrator, holding every permission) or a seeded
 *                         demo. The platform owner opens and closes self-service
 *                         sign-up from the console; it is closed by default.
 *
 * The invitation is redeemed only when they press Join, on a card that names
 * the account about to join. A sign-in joins one organisation for good, and a
 * held token does not say whose it is: the link may have been opened in a
 * browser already signed in to another account, with the wrong Google account
 * picked, or planted in this tab by somebody else entirely. Only the person
 * signed in can tell, so they are asked, and "Not you?" signs them out with the
 * invitation still held for the right account. A refused invitation (expired,
 * already used) says so and offers the paste box again.
 */
function Onboarding({ email, onSignOut }: { email: string | null; onSignOut: () => void }) {
  const queryClient = useQueryClient();
  const platform = usePlatformMe();
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState<"create" | "demo" | "join" | null>(null);

  // Read once, then held here: a pasted invitation takes the same card as one
  // that arrived by link, and the card stays up with its refusal after a
  // failed attempt until the person chooses another.
  const [invitation, setInvitation] = useState<string | null>(readStoredInvitation);
  const [joinError, setJoinError] = useState<unknown>(null);

  // Platform staff who may create organisations: operators and owners, as the
  // doors decide. Support staff are asked about the switch like anybody else.
  const staff = platform.isPending
    ? undefined
    : Boolean(platform.data?.is_staff) && atLeast(platform.data?.role, "operator");

  // Asked only where the answer changes the screen: nobody holding an
  // invitation, and no operator or owner, who may create regardless.
  const selfService = useQuery({
    queryKey: ["erp_self_service_organisations_open"],
    queryFn: () => callErp<unknown>("erp_self_service_organisations_open"),
    enabled: Boolean(supabase) && (invitation ?? "").trim() === "" && staff === false,
    staleTime: 60_000,
  });
  const open = selfService.isSuccess
    ? selfServiceIsOpen(selfService.data)
    : selfService.isError
      ? false
      : undefined;

  const view = onboardingView({ invitation, staff, open });

  // Only ever from the Join button. Nothing claims on arrival.
  async function join(held: string) {
    setBusy("join");
    setJoinError(null);
    try {
      await callErp("erp_claim_invitation", { p_token: held });
      clearStoredInvitation();
      await queryClient.invalidateQueries();
    } catch (e) {
      setJoinError(e);
    } finally {
      setBusy(null);
    }
  }

  function hold(pasted: string) {
    const token = pastedToken(pasted);
    if (token === "") return;
    // Held for this tab, as an arriving link is, so "Not you?" keeps it for the
    // right account. A value that does not look like a token is not stored; it
    // is still offered, and the database says what is wrong with it.
    storeInvitation(token);
    setJoinError(null);
    setInvitation(token);
  }

  function letGo() {
    clearStoredInvitation();
    setJoinError(null);
    setInvitation(null);
  }

  async function run(which: "create" | "demo") {
    setBusy(which);
    setError(null);
    try {
      if (which === "create") {
        await callErp("erp_onboard_tenant", { p_name: name, p_code: code });
      } else {
        await callErp("erp_seed_demo");
      }
      // The session query is keyed on the auth user; invalidating everything
      // re-resolves the tenant and lands on the shell.
      await queryClient.invalidateQueries();
    } catch (e) {
      setError(e);
      // The switch may have closed since this screen asked. Asking again lets
      // a refused person see the screen that applies to them now.
      void queryClient.invalidateQueries({ queryKey: ["erp_self_service_organisations_open"] });
    } finally {
      setBusy(null);
    }
  }

  if (view === "checking") {
    return (
      <Centred>
        <p role="status" className="text-sm text-muted-foreground">
          Checking this account…
        </p>
      </Centred>
    );
  }

  const signedInAs = (
    <span className="font-medium break-all text-foreground">
      {email ?? "an account with no email address"}
    </span>
  );

  // The owner of the product arrives here on day one, belonging to no tenant
  // at all. The console has to be reachable from exactly here.
  const consoleNote =
    platform.data?.is_staff || platform.data?.claimable ? (
      <p className="mt-6 rounded-lg border border-primary/30 bg-primary/5 p-3 text-center text-xs">
        {platform.data.is_staff ? "You are platform staff." : "This deployment has no owner yet."}{" "}
        <Link to="/platform" className="font-medium underline underline-offset-2">
          Open the platform console
        </Link>
      </p>
    ) : null;

  const signOut = (
    <p className="mt-4 text-center text-xs text-muted-foreground">
      <button
        type="button"
        onClick={onSignOut}
        disabled={busy !== null}
        className="underline underline-offset-2 disabled:opacity-60"
      >
        Sign out
      </button>
    </p>
  );

  if (view === "join" && invitation !== null) {
    const refusal = joinError ? friendlyError(joinError) : null;
    return (
      <Centred>
        <section className="rounded-xl border border-primary/40 bg-primary/5 p-6">
          <h1 className="text-lg font-semibold">You have been invited to join an organisation</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Joining brings this account into the organisation that invited you, with the roles it
            has given you. An account can belong to only one organisation, so check this is the
            account the invitation was meant for.
          </p>
          <p className="mt-3 text-sm">You are signed in as {signedInAs}.</p>

          {refusal ? (
            <div role="alert" className="mt-3 text-sm">
              <p className="font-medium text-destructive">{refusal.title}</p>
              {refusal.body ? <p className="mt-1 text-muted-foreground">{refusal.body}</p> : null}
              {refusal.hint ? <p className="mt-1 text-muted-foreground">{refusal.hint}</p> : null}
              <p className="mt-1 text-muted-foreground">
                An invitation works once, expires, and is replaced when a new one is sent. Ask
                whoever invited you to send it again.
              </p>
              <button
                type="button"
                onClick={letGo}
                disabled={busy !== null}
                className="mt-2 font-medium underline underline-offset-2 disabled:opacity-60"
              >
                Use a different invitation
              </button>
            </div>
          ) : null}

          <button
            type="button"
            onClick={() => void join(invitation)}
            disabled={busy !== null}
            className="mt-4 w-full break-all rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
          >
            {busy === "join" ? "Joining…" : email ? `Join as ${email}` : "Join with this account"}
          </button>
          <p className="mt-3 text-center text-sm text-muted-foreground">
            Not you?{" "}
            <button
              type="button"
              onClick={onSignOut}
              disabled={busy !== null}
              className="font-medium underline underline-offset-2 disabled:opacity-60"
            >
              Sign out
            </button>
          </p>
        </section>
      </Centred>
    );
  }

  if (view === "invitation-only") {
    return (
      <Centred>
        <section className="rounded-xl border border-border bg-card p-6">
          <Wordmark size={30} />
          <h1 className="mt-4 text-lg font-semibold">You need an invitation</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            You are signed in as {signedInAs}, but this account is not part of an organisation yet.
          </p>
          <p className="mt-3 text-sm text-muted-foreground">
            Ask the organisation you work with to send you an invitation. Opening the link in that
            email brings you in. If it was sent to a different address, sign out and sign in with
            that one.
          </p>
          <PasteInvitation onHold={hold} disabled={busy !== null} />
          {consoleNote}
          {signOut}
        </section>
      </Centred>
    );
  }

  const refused = error ? friendlyError(error) : null;

  return (
    <Centred>
      <section className="mb-4 rounded-xl border border-primary/40 bg-primary/5 p-6">
        <h2 className="text-base font-semibold">Been invited?</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          If the organisation you work with has invited you, open the link in that email, or paste
          it here. An account can belong to only one organisation, so join theirs rather than
          creating one of your own.
        </p>
        <PasteInvitation onHold={hold} disabled={busy !== null} />
      </section>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          void run("create");
        }}
        className="rounded-xl border border-border bg-card p-6"
      >
        <h1 className="text-lg font-semibold">Create your organisation</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          You are signed in, but this account does not belong to an organisation yet. Creating one
          makes you its first administrator, holding every permission.
        </p>

        <label className="mt-5 block text-sm font-medium">
          Organisation name
          <input
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Acme Manufacturing"
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        </label>

        <label className="mt-3 block text-sm font-medium">
          Short code
          <input
            required
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="acme"
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
          />
        </label>

        {refused ? (
          <div role="alert" className="mt-3 text-sm">
            <p className="font-medium text-destructive">{refused.title}</p>
            {refused.body ? <p className="mt-1 text-muted-foreground">{refused.body}</p> : null}
            {refused.hint ? <p className="mt-1 text-muted-foreground">{refused.hint}</p> : null}
          </div>
        ) : null}

        <button
          type="submit"
          disabled={busy !== null}
          className="mt-5 w-full rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
        >
          {busy === "create" ? "Creating…" : "Create organisation"}
        </button>

        <div className="mt-4 flex items-center gap-3 text-xs text-muted-foreground">
          <span className="h-px flex-1 bg-border" />
          or
          <span className="h-px flex-1 bg-border" />
        </div>

        <button
          type="button"
          onClick={() => void run("demo")}
          disabled={busy !== null}
          className="mt-4 w-full rounded-md border border-input px-4 py-2 text-sm font-medium disabled:opacity-60"
        >
          {busy === "demo" ? "Seeding…" : "Explore a seeded demo organisation instead"}
        </button>

        {consoleNote}
        {signOut}
      </form>
    </Centred>
  );
}

/**
 * The box an invitation link or token is pasted into. It does not redeem
 * anything: what was pasted becomes the held invitation, and the card that
 * names the signed-in account asks before it joins.
 */
function PasteInvitation({
  onHold,
  disabled,
}: {
  onHold: (pasted: string) => void;
  disabled: boolean;
}) {
  const [pasted, setPasted] = useState("");
  return (
    <div className="mt-5">
      <label className="block text-sm font-medium">
        Invitation link
        <input
          value={pasted}
          onChange={(e) => setPasted(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && pasted.trim().length > 0) {
              e.preventDefault();
              onHold(pasted);
            }
          }}
          spellCheck={false}
          autoComplete="off"
          placeholder="Paste your invitation link or token"
          className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-xs"
        />
      </label>
      <button
        type="button"
        onClick={() => onHold(pasted)}
        disabled={disabled || pasted.trim().length === 0}
        className="mt-2 w-full rounded-md border border-input bg-background px-4 py-2 text-sm font-medium disabled:opacity-60"
      >
        Use this invitation
      </button>
      <p className="mt-2 text-xs text-muted-foreground">
        An invitation works once and then never again.
      </p>
    </div>
  );
}

const SCOPE_KEY = "clove-erp.scope";

function readScope(): Scope {
  try {
    const raw = localStorage.getItem(SCOPE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<Scope>;
      return { entityId: parsed.entityId ?? "", siteId: parsed.siteId ?? "" };
    }
  } catch {
    /* private window, cleared site data, or storage blocked entirely */
  }
  return { entityId: "", siteId: "" };
}

/**
 * `bare` keeps the session, the scope and the terminology but drops the desk
 * shell: the rail, the header and the area switch. The device client (Part 14)
 * is a different application against the same functions, and a warehouse
 * screen wrapped in a desk's navigation would be neither.
 */
export function Gate({
  children,
  bare = false,
  signedOut,
}: {
  children: ReactNode;
  bare?: boolean;
  /**
   * What a route shows somebody with no session, in place of the sign-in
   * screen. /join has its own: the person arrived with an invitation, and the
   * one thing to offer them is the way in that invitation carries.
   */
  signedOut?: ReactNode;
}) {
  const [authSession, setAuthSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  // Each route mounts its own Gate, so scope held in plain state would reset on
  // every navigation. It is a per-viewer convenience, not shared state, so the
  // browser is the right place for it — and it is read defensively because a
  // private window or blocked site data makes any of this throw.
  const [scope, setScope] = useState<Scope>(readScope);

  const changeScope = (s: Scope) => {
    setScope(s);
    try {
      localStorage.setItem(SCOPE_KEY, JSON.stringify(s));
    } catch {
      /* storage unavailable; the selection still applies for this page */
    }
  };

  useEffect(() => {
    if (!supabase) {
      setAuthReady(true);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setAuthSession(data.session);
      setAuthReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setAuthSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_session", authSession?.user?.id ?? null],
    queryFn: () => callErp<ErpSession>("erp_session"),
    enabled: Boolean(supabase && authSession),
  });

  if (!isConfigured) return <NotConfigured />;
  if (!authReady)
    return (
      <Centred>
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      </Centred>
    );
  if (!authSession) return signedOut ?? <SignIn />;

  const signOut = () => supabase!.auth.signOut();

  if (isPending) {
    return (
      <Centred>
        <p role="status" className="text-sm text-muted-foreground">
          Finding your organisation…
        </p>
      </Centred>
    );
  }

  if (error) {
    return (
      <Centred>
        <h1 className="text-lg font-semibold">Could not load your session</h1>
        <p className="mt-2 text-sm text-muted-foreground">{friendlyError(error).title}</p>
        <button
          onClick={signOut}
          className="mt-5 rounded-md border border-input px-4 py-2 text-sm font-medium"
        >
          Sign out
        </button>
      </Centred>
    );
  }

  if (!data?.tenant_id) {
    return <Onboarding email={authSession.user.email ?? null} onSignOut={signOut} />;
  }

  return (
    <ErpSessionContext.Provider value={{ session: data, scope }}>
      <ResourceProvider>
        {bare ? (
          children
        ) : (
          <Shell session={data} scope={scope} onScopeChange={changeScope} onSignOut={signOut}>
            {children}
          </Shell>
        )}
      </ResourceProvider>
    </ErpSessionContext.Provider>
  );
}
