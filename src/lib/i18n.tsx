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

/** The resolver. Every user-facing literal in a screen should pass through it. */
export function useT() {
  const { resources, locale } = useContext(ResourceContext);

  function t(key: string, fallback: string): string {
    const value = resources[key];
    return value && value.length > 0 ? value : fallback;
  }

  /** Whether a key is genuinely resolved, for the terminology screen. */
  function has(key: string): boolean {
    return Boolean(resources[key]);
  }

  return { t, has, locale, resources };
}

/** Convenience for the common case: one key, one fallback, no other props. */
export function T({ k, fallback }: { k: string; fallback: string }) {
  const { t } = useT();
  return <>{t(k, fallback)}</>;
}
