import { createClient, type Session } from "@supabase/supabase-js";

/**
 * The single point at which the front end touches the database.
 *
 * Everything below goes through `public.erp_*` functions rather than table
 * endpoints. That is deliberate: the `erp` schema is not exposed to PostgREST,
 * because exposing it would put roughly a hundred and twenty tables on the REST
 * surface at once. Row-level security would still hold — but "protected by RLS"
 * and "deliberately exposed" are different claims, and only the second is a
 * design.
 *
 * So reads come from a small curated API, and writes go through the functions
 * that already gate them (`erp.submit_command`, `erp.apply_stock_movement`,
 * `erp_ai.apply_proposal`), each of which authorises, validates and records.
 * There is no CRUD endpoint onto a table anywhere in this client, and that is
 * the point rather than an omission.
 */

/**
 * The project this build talks to when the host names no other.
 *
 * These are here rather than only in the environment because a build that
 * reads only the environment is a build that can arrive unconfigured, and one
 * did: the values lived in a tracked `.env` until it left version control, and
 * from then on every publish shipped an application whose first screen told the
 * visitor to set two variables. The application is published by hand from
 * Lovable and the values are inlined at build time, so nothing downstream could
 * repair it either.
 *
 * The publishable key is public by design. Supabase ships it in the client
 * bundle of every application built on it — this one included, before and after
 * this change — and it is the key the browser presents on every request. On
 * this project it opens nothing on its own: `anon` holds EXECUTE on no function
 * in any product schema (`erp.assert_no_public_execute`), the `erp` schema is
 * not exposed to PostgREST at all, and every table is behind row-level
 * security. What it buys is that every build starts connected — Lovable's
 * publish, the build CI runs with no environment at all, a fresh clone, a fork.
 *
 * The environment still wins where it is set, which is how a preview or a
 * second project is pointed elsewhere without touching the source.
 */
const DEFAULT_SUPABASE_URL = "https://xpzffnnhnhcqyjqcueja.supabase.co";
const DEFAULT_SUPABASE_PUBLISHABLE_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhwemZmbm5obmhjcXlqcWN1ZWphIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgwMDIyNDIsImV4cCI6MjEwMzU3ODI0Mn0.PKnEUURM8CTNVkBjgA_pCoQJheGmL_6I7UD1-5Uywjk";

const url = (import.meta.env["VITE_SUPABASE_URL"] as string | undefined) || DEFAULT_SUPABASE_URL;
const key =
  (import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined) ||
  DEFAULT_SUPABASE_PUBLISHABLE_KEY;

/** The project this build talks to. Read these rather than the variables. */
export const supabaseUrl = url;
export const supabasePublishableKey = key;

export const isConfigured = Boolean(url && key);

export const supabase = isConfigured
  ? createClient(url, key, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  : null;

/**
 * Whether this browser is holding a session, without waiting to ask.
 *
 * `supabase.auth.getSession()` is asynchronous, so the first paint cannot know
 * whether anybody is signed in; the root route needs to, because it shows the
 * product page to a visitor and the desk to a person who works here, and
 * flashing one before the other is worse than either. supabase-js persists the
 * session under a key derived from the project ref, so its presence is a good
 * enough hint to render against — and only a hint: the real check still runs
 * and still decides.
 *
 * False on the server, where there is no storage and no session, so the public
 * page is what gets rendered into the HTML.
 */
export function hasStoredSession(): boolean {
  if (typeof window === "undefined") return false;
  const ref = url.match(/^https?:\/\/([^.]+)\./)?.[1];
  if (!ref) return false;
  try {
    return Boolean(window.localStorage.getItem(`sb-${ref}-auth-token`));
  } catch {
    // A private window, or site data blocked. Treated as signed out: the
    // visitor sees the public page and can still sign in from it.
    return false;
  }
}

export type ErpEntity = { id: string; code: string; name: string };
export type ErpSite = { id: string; code: string; name: string; entity_id: string | null };

export type ErpSession = {
  principal_id: string | null;
  tenant_id: string | null;
  principal?: {
    display_name: string;
    given_name?: string | null;
    family_name?: string | null;
    email: string | null;
    kind: "person" | "service";
    user_locale: string | null;
    document_locale?: string | null;
    reporting_locale?: string | null;
    timezone: string | null;
  };
  tenant?: { code: string; name: string; status: string };
  entities: ErpEntity[];
  sites: ErpSite[];
  permissions: string[];
};

/**
 * An error from the database, with everything the database said.
 *
 * The engine raises `CLOVEERP_*` errors carrying a `hint` that is often the
 * next command to run — `erp.create_item` names `erp_create_uom`,
 * `guard_live_configuration` names `erp.promote_change_set`. Throwing only
 * `error.message` discarded all of it, which turned a refusal that explains
 * itself into one that does not.
 */
export class ErpError extends Error {
  readonly code: string | undefined;
  readonly details: string | undefined;
  readonly hint: string | undefined;

  constructor(
    message: string,
    parts: { code?: string | undefined; details?: string | undefined; hint?: string | undefined },
  ) {
    super(message);
    this.name = "ErpError";
    this.code = parts.code;
    this.details = parts.details;
    this.hint = parts.hint;
  }

  /**
   * The refusal token the engine leads its message with, verbatim.
   *
   * Verbatim rather than normalised, because friendlyError() strips this exact
   * substring out of the message before showing what is left. Two prefixes are
   * accepted for one release: 20260904980000 moved every refusal from ERPWARE_
   * to CLOVEERP_, and the database and this site are deployed separately and by
   * hand, so for a while whichever went first is ahead of the other.
   *
   * The character class includes digits. It did not, and four tokens carry one
   * — CLOVEERP_C1_SUITE_FAILED matched as far as the C, resolved to nothing,
   * and left "1_SUITE_FAILED: …" on the screen with the prefix stripped off.
   */
  get erpCode(): string | null {
    return /^((?:CLOVEERP|ERPWARE)_[A-Z0-9_]+)/.exec(this.message)?.[1] ?? null;
  }

  /**
   * 42501 is what `erp.authorise()` raises. Worth distinguishing because it is
   * the one failure a screen should treat as an answer rather than a fault:
   * the database decided, and it decided no.
   */
  get isPermissionDenied(): boolean {
    const token = this.erpCode;
    return (
      this.code === "42501" ||
      token === "CLOVEERP_PERMISSION_DENIED" ||
      token === "ERPWARE_PERMISSION_DENIED"
    );
  }
}

/**
 * Calling a `public.erp_*` function.
 *
 * Errors are surfaced rather than swallowed. A screen that renders empty when
 * the call failed is indistinguishable from one where there is genuinely
 * nothing to show, and the difference matters most exactly when something is
 * wrong.
 */
export async function callErp<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) {
    throw new Error(
      "Supabase is not configured. Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY.",
    );
  }

  const { data, error } = await supabase.rpc(fn, args);

  if (error) {
    // PostgREST reports a missing function as PGRST202. Worth naming, because
    // the likeliest cause is the migrations not having been applied to the
    // project this build is pointed at — which is a deployment problem, not a
    // code one, and says so.
    if (error.code === "PGRST202") {
      throw new ErpError(
        `${fn} does not exist on this project. The Clove ERP migrations may not have been applied to it.`,
        { code: error.code },
      );
    }
    throw new ErpError(error.message, {
      code: error.code,
      details: error.details ?? undefined,
      hint: error.hint ?? undefined,
    });
  }

  return data as T;
}

export const emptySession: ErpSession = {
  principal_id: null,
  tenant_id: null,
  entities: [],
  sites: [],
  permissions: [],
};

export function hasPermission(session: ErpSession | null, code: string): boolean {
  return Boolean(session?.permissions?.includes(code));
}

export async function currentSession(): Promise<Session | null> {
  if (!supabase) return null;
  const { data } = await supabase.auth.getSession();
  return data.session;
}
