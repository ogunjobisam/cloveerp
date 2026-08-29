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

const url = import.meta.env["VITE_SUPABASE_URL"] as string | undefined;
const key = import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined;

export const isConfigured = Boolean(url && key);

export const supabase = isConfigured
  ? createClient(url!, key!, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  : null;

export type ErpEntity = { id: string; code: string; name: string };
export type ErpSite = { id: string; code: string; name: string; entity_id: string | null };

export type ErpSession = {
  principal_id: string | null;
  tenant_id: string | null;
  principal?: {
    display_name: string;
    email: string | null;
    kind: "person" | "service";
    user_locale: string | null;
    timezone: string | null;
  };
  tenant?: { code: string; name: string; status: string };
  entities: ErpEntity[];
  sites: ErpSite[];
  permissions: string[];
};

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
      throw new Error(
        `${fn} does not exist on this project. The ERPWare migrations may not have been applied to it.`,
      );
    }
    throw new Error(error.message);
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
