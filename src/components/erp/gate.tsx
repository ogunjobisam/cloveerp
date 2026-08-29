import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";

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

function NoTenant({ onSignOut }: { onSignOut: () => void }) {
  return (
    <Centred>
      <h1 className="text-lg font-semibold">No tenant for this account</h1>
      <p className="mt-2 text-sm text-muted-foreground">
        You are signed in, but this identity does not resolve to a principal in any tenant. Until an
        administrator creates one, there is no tenant context — and without a tenant context the
        platform deliberately shows nothing rather than showing something.
      </p>
      <button
        onClick={onSignOut}
        className="mt-5 rounded-md border border-input px-4 py-2 text-sm font-medium"
      >
        Sign out
      </button>
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

  if (!data?.tenant_id) return <NoTenant onSignOut={signOut} />;

  return (
    <ErpSessionContext.Provider value={{ session: data, scope }}>
      <Shell session={data} scope={scope} onScopeChange={changeScope} onSignOut={signOut}>
        {children}
      </Shell>
    </ErpSessionContext.Provider>
  );
}

export const ErpSessionContext = createContext<{
  session: ErpSession;
  scope: Scope;
} | null>(null);

export function useErpSession() {
  const ctx = useContext(ErpSessionContext);
  if (!ctx) throw new Error("useErpSession must be used inside the authenticated shell");
  return ctx;
}
