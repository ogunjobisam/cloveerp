import { useQuery } from "@tanstack/react-query";

import { supabasePublishableKey, supabaseUrl } from "./erp";

/**
 * Whether the project this page talks to offers Google sign-in.
 *
 * Google is switched on per Supabase project, by hand: production has it,
 * the demonstration and a new client's project do not
 * (supabase/ci/provision_project.sh sets no external provider, and the
 * console's checklist keeps it as an item). A Google button on a project
 * without it does not fail where the person can see: supabase-js sends the
 * browser to Auth's authorise address, which answers a page of raw JSON
 * saying the provider is not enabled. So the button is offered only where the
 * project's own Auth says Google is on.
 *
 * Auth answers that publicly: GET <project>/auth/v1/settings with the
 * publishable key says which external providers are enabled, among other
 * things. supabase-js has no call for it, so it is a plain request.
 */

/** Where a project's Auth says which providers it has. */
export function authSettingsUrl(projectUrl: string): string {
  return `${projectUrl.replace(/\/+$/, "")}/auth/v1/settings`;
}

/**
 * What Auth's settings say about Google, read strictly: only a literal true
 * offers the button. A failed request, an older Auth, or any other shape is
 * no Google, because the button on a project without it leads to a dead end.
 */
export function readGoogleEnabled(settings: unknown): boolean {
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) return false;
  const external: unknown = Reflect.get(settings, "external");
  if (external === null || typeof external !== "object" || Array.isArray(external)) return false;
  return Reflect.get(external, "google") === true;
}

/**
 * How long one project's answer is believed. A provider is switched on or off
 * by hand, rarely; an hour is short enough to notice and long enough that a
 * sign-in screen does not ask on every visit.
 */
export const AUTH_SETTINGS_STALE_MS = 60 * 60 * 1000;

/**
 * Whether to offer Google on this page's sign-in: false until the project's
 * Auth has said yes, and false if it cannot be asked.
 */
export function useGoogleSignIn(): boolean {
  const url = supabaseUrl;
  const key = supabasePublishableKey;
  const settings = useQuery({
    queryKey: ["auth_settings", url],
    queryFn: async ({ signal }): Promise<boolean> => {
      const response = await fetch(authSettingsUrl(url), { headers: { apikey: key }, signal });
      if (!response.ok) throw new Error(`Auth settings answered ${response.status}`);
      return readGoogleEnabled(await response.json());
    },
    enabled: url !== "" && key !== "",
    staleTime: AUTH_SETTINGS_STALE_MS,
    gcTime: AUTH_SETTINGS_STALE_MS,
    retry: 1,
  });
  return settings.data === true;
}
