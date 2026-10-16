// Calling CloveERP's doors as the signed-in user.
//
// Every tool acts with the user's own Supabase access token (from the OAuth
// props), so the database's permission and tenant guards apply unchanged — the
// connector can do nothing the user cannot. We never use the service role key.
import { createClient } from "@supabase/supabase-js";

export interface ConnectorEnv {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
}

/** What `completeAuthorization` stored, handed back to tools via the auth context. */
export interface UserProps {
  userId: string;
  email: string;
  /** The user's Supabase access token — used to call doors as them. */
  accessToken: string;
  /** For refresh (tokenExchangeCallback). */
  refreshToken: string;
  [key: string]: unknown;
}

/** A Supabase client bound to the user's access token, for calling public.erp_* doors. */
export function userClient(env: ConnectorEnv, props: UserProps) {
  return createClient(env.SUPABASE_URL, env.SUPABASE_PUBLISHABLE_KEY, {
    global: { headers: { Authorization: `Bearer ${props.accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Call a public.erp_* door as the user; throws the door's refusal message. */
export async function callDoor(
  env: ConnectorEnv,
  props: UserProps,
  name: string,
  args: Record<string, unknown> = {},
): Promise<unknown> {
  const client = userClient(env, props);
  const { data, error } = await client.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.message}`);
  return data;
}
