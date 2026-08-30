import { useQuery } from "@tanstack/react-query";
import { createContext, useContext, type ReactNode } from "react";

import { callErp } from "./erp";

/**
 * Resource keys, per spec §3.10 and the refusal in Part 7: no hard-coded
 * user-facing text.
 *
 * The dictionary is not in this file. It is `erp_ref.resource` — product
 * content, shipped with the release, one row per key and locale — with
 * `erp.resource_override` layered on top, which is tenant content. A tenant
 * that calls a delivery note a despatch advice changes a row, not a build.
 *
 * `t(key, fallback)` takes a fallback deliberately. A missing key must not
 * render as `document.delivery` in front of a user, and a screen must not
 * disappear because a resource has not been seeded yet. The fallback is
 * English of last resort, and `erp.resource_coverage_report()` is what tells
 * you which keys are still relying on it.
 */

export type Resources = Record<string, string>;

const ResourceContext = createContext<{ resources: Resources; locale: string }>({
  resources: {},
  locale: "en",
});

export function ResourceProvider({
  locale = "en",
  children,
}: {
  locale?: string;
  children: ReactNode;
}) {
  const { data } = useQuery({
    queryKey: ["erp_resources", { p_locale: locale }],
    queryFn: () => callErp<Resources>("erp_resources", { p_locale: locale }),
    // Terminology changes when configuration is promoted, not between clicks.
    staleTime: 5 * 60_000,
  });

  return (
    <ResourceContext.Provider value={{ resources: data ?? {}, locale }}>
      {children}
    </ResourceContext.Provider>
  );
}

/**
 * The key for a piece of interface wording, derived from the wording itself.
 *
 * Screen chrome — column headings, action labels, empty states — is too
 * numerous to name by hand, and a hand-named key drifts from the text it
 * names. Deriving `ui.<slug>_<hash>` from the English source keeps the two in
 * step, and `erp_ref.ui_key()` computes the identical key in the database, so
 * the terminology screen can offer every one of them for renaming.
 */
export function uiKey(text: string): string {
  let h = 2166136261;
  for (let i = 0; i < text.length; i += 1) {
    h = Math.imul(h ^ text.charCodeAt(i), 16777619) >>> 0;
  }
  const slug =
    text
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 40)
      .replace(/^_+|_+$/g, "") || "x";
  return `ui.${slug}_${h.toString(36)}`;
}

/** The resolver. Every user-facing literal in a screen should pass through it. */
export function useT() {
  const { resources, locale } = useContext(ResourceContext);

  function t(key: string, fallback: string): string {
    const value = resources[key];
    return value && value.length > 0 ? value : fallback;
  }

  /**
   * Interface wording, keyed by its own source text. The English in the call
   * is the product's own copy — the dictionary row it seeds — so a tenant that
   * renames it sees the new wording everywhere that phrase appears.
   */
  function ui(text: string): string {
    const value = resources[uiKey(text)];
    return value && value.length > 0 ? value : text;
  }

  /** Whether a key is genuinely resolved, for the terminology screen. */
  function has(key: string): boolean {
    return Boolean(resources[key]);
  }

  return { t, ui, has, locale, resources };
}


/** Convenience for the common case: one key, one fallback, no other props. */
export function T({ k, fallback }: { k: string; fallback: string }) {
  const { t } = useT();
  return <>{t(k, fallback)}</>;
}
