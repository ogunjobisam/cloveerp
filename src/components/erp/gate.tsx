import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";

import { ResourceProvider } from "../../lib/i18n";
import { callErp, isConfigured, supabase, type ErpSession } from "../../lib/erp";
import { Shell, type Scope } from "./shell";

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

function Centred({ children }: { children: ReactNode }) {
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

function SignIn() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { error } = await supabase!.auth.signInWithPassword({ email, password });
    if (error) setError(error.message);
    setBusy(false);
  }

  return (
    <Centred>
      <form onSubmit={submit} className="rounded-xl border border-border bg-card p-6">
        <h1 className="text-lg font-semibold">Sign in to ERPWare</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Your tenant is derived from your account. It is never chosen here.
        </p>

        <label className="mt-5 block text-sm font-medium">
          Email
          <input
            type="email"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
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
          disabled={busy}
          className="mt-5 w-full rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
        >
          {busy ? "Signing in…" : "Sign in"}
        </button>

        <p className="mt-4 text-center text-xs text-muted-foreground">
          <Link to="/product" className="underline underline-offset-2">
            About ERPWare
          </Link>
        </p>
      </form>
    </Centred>
  );
}

/**
 * The onboarding state: signed in, but resolving to no principal anywhere.
 *
 * Two ways out, because there are two ways to arrive here and only one of them
 * is a new customer.
 *
 * Creating a tenant makes the caller its first principal, with an
 * administrator role holding every permission — tenant, principal, role and
 * grant in one transaction, because half of that list is worse than none.
 *
 * Redeeming an invitation is the other: somebody already inside a tenant
 * created a principal for this person and handed them a single-use token. It
 * belongs on the same screen, since from here the two states are
 * indistinguishable — you are signed in and the database has nothing to say
 * about you.
 */
function Onboarding({ onSignOut }: { onSignOut: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<"create" | "demo" | "redeem" | null>(null);

  async function run(which: "create" | "demo" | "redeem") {
    setBusy(which);
    setError(null);
    try {
      if (which === "create") {
        await callErp("erp_onboard_tenant", { p_name: name, p_code: code });
      } else if (which === "redeem") {
        await callErp("erp_claim_invitation", { p_token: token.trim() });
      } else {
        await callErp("erp_seed_demo");
      }
      // The session query is keyed on the auth user; invalidating everything
      // re-resolves the tenant and lands on the shell.
      await queryClient.invalidateQueries();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <Centred>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          run("create");
        }}
        className="rounded-xl border border-border bg-card p-6"
      >
        <h1 className="text-lg font-semibold">Create your tenant</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          You are signed in, but this identity resolves to no principal yet. Creating a tenant makes
          you its first principal, with an administrator role holding every permission.
        </p>

        <label className="mt-5 block text-sm font-medium">
          Tenant name
          <input
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Acme Manufacturing"
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        </label>

        <label className="mt-3 block text-sm font-medium">
          Tenant code
          <input
            required
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="acme"
            className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-sm"
          />
        </label>

        {error ? (
          <p role="alert" className="mt-3 text-sm text-destructive">
            {error}
          </p>
        ) : null}

        <button
          type="submit"
          disabled={busy !== null}
          className="mt-5 w-full rounded-md bg-primary px-4 py-2 text-sm font-semibold text-primary-foreground disabled:opacity-60"
        >
          {busy === "create" ? "Creating…" : "Create tenant"}
        </button>

        <div className="mt-4 flex items-center gap-3 text-xs text-muted-foreground">
          <span className="h-px flex-1 bg-border" />
          or
          <span className="h-px flex-1 bg-border" />
        </div>

        <button
          type="button"
          onClick={() => run("demo")}
          disabled={busy !== null}
          className="mt-4 w-full rounded-md border border-input px-4 py-2 text-sm font-medium disabled:opacity-60"
        >
          {busy === "demo" ? "Seeding…" : "Explore a seeded demo tenant instead"}
        </button>

        <div className="mt-6 border-t border-border pt-4">
          <label className="block text-sm font-medium">
            Been invited instead?
            <input
              value={token}
              onChange={(e) => setToken(e.target.value)}
              spellCheck={false}
              autoComplete="off"
              placeholder="Paste your invitation token"
              className="mt-1 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-xs"
            />
          </label>
          <button
            type="button"
            onClick={() => run("redeem")}
            disabled={busy !== null || token.trim().length === 0}
            className="mt-2 w-full rounded-md border border-input px-4 py-2 text-sm font-medium disabled:opacity-60"
          >
            {busy === "redeem" ? "Redeeming…" : "Redeem invitation"}
          </button>
          <p className="mt-2 text-xs text-muted-foreground">
            A token works once and then never again.
          </p>
        </div>

        <p className="mt-4 text-center text-xs text-muted-foreground">
          <button type="button" onClick={onSignOut} className="underline underline-offset-2">
            Sign out
          </button>
        </p>
      </form>
    </Centred>
  );
}

const SCOPE_KEY = "erpware.scope";

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

export function Gate({ children }: { children: ReactNode }) {
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
        <p className="text-sm text-muted-foreground">Loading…</p>
      </Centred>
    );
  if (!authSession) return <SignIn />;

  const signOut = () => supabase!.auth.signOut();

  if (isPending) {
    return (
      <Centred>
        <p className="text-sm text-muted-foreground">Resolving your tenant…</p>
      </Centred>
    );
  }

  if (error) {
    return (
      <Centred>
        <h1 className="text-lg font-semibold">Could not load your session</h1>
        <p className="mt-2 text-sm text-muted-foreground">{(error as Error).message}</p>
        <button
          onClick={signOut}
          className="mt-5 rounded-md border border-input px-4 py-2 text-sm font-medium"
        >
          Sign out
        </button>
      </Centred>
    );
  }

  if (!data?.tenant_id) return <Onboarding onSignOut={signOut} />;

  return (
    <ErpSessionContext.Provider value={{ session: data, scope }}>
      <ResourceProvider>
      <Shell session={data} scope={scope} onScopeChange={changeScope} onSignOut={signOut}>
        {children}
      </Shell>
      </ResourceProvider>
    </ErpSessionContext.Provider>
  );
}

export { ErpSessionContext, useErpSession } from "./session-context";

