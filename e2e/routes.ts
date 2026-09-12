/**
 * Every route the application serves, and what each one is.
 *
 * Written out rather than discovered, because a list that derives itself from
 * the file tree agrees with the file tree by construction and would not notice
 * a route that stopped being reachable. This one is checked against the tree by
 * the first test in routes.spec.ts, so a route added without a line here fails.
 */

export type Kind =
  /** Reachable with no session at all. */
  | "public"
  /** Behind the gate, and inside the desk: the shell's Areas navigation is there. */
  | "desk"
  /**
   * Behind the gate and deliberately without the desk. `<Gate bare>` keeps the
   * session, the scope and the terminology and drops the shell — /device is a
   * warehouse screen, and a person holding a scanner has no use for an area
   * switcher.
   */
  | "bare";

export type RouteUnderTest = {
  path: string;
  kind: Kind;
  /** The file under src/routes, for the inventory check. */
  file: string;
};

export const ROUTES: readonly RouteUnderTest[] = [
  { path: "/", kind: "desk", file: "index.tsx" },
  { path: "/product", kind: "public", file: "product.tsx" },
  { path: "/contact", kind: "public", file: "contact.tsx" },
  { path: "/platform", kind: "public", file: "platform.tsx" },
  { path: "/signin", kind: "public", file: "signin.tsx" },

  { path: "/help", kind: "desk", file: "help.tsx" },
  { path: "/profile", kind: "desk", file: "profile.tsx" },
  { path: "/settings", kind: "desk", file: "settings.tsx" },
  { path: "/notifications", kind: "desk", file: "notifications.tsx" },
  { path: "/device", kind: "bare", file: "device.tsx" },

  { path: "/administration/accessibility", kind: "desk", file: "administration/accessibility.tsx" },
  { path: "/administration/adoption", kind: "desk", file: "administration/adoption.tsx" },
  { path: "/administration/audit", kind: "desk", file: "administration/audit.tsx" },
  { path: "/administration/commercial", kind: "desk", file: "administration/commercial.tsx" },
  { path: "/administration/configuration", kind: "desk", file: "administration/configuration.tsx" },
  { path: "/administration/erasure", kind: "desk", file: "administration/erasure.tsx" },
  { path: "/administration/onboarding", kind: "desk", file: "administration/onboarding.tsx" },
  { path: "/administration/organisation", kind: "desk", file: "administration/organisation.tsx" },
  { path: "/administration/packs", kind: "desk", file: "administration/packs.tsx" },
  { path: "/administration/permissions", kind: "desk", file: "administration/permissions.tsx" },
  { path: "/administration/tenant", kind: "desk", file: "administration/tenant.tsx" },
  { path: "/administration/terminology", kind: "desk", file: "administration/terminology.tsx" },

  { path: "/commercial/price-book", kind: "desk", file: "commercial/price-book.tsx" },
  { path: "/commercial/quotes", kind: "desk", file: "commercial/quotes.tsx" },

  { path: "/finance", kind: "desk", file: "finance/index.tsx" },
  {
    path: "/finance/account-determination",
    kind: "desk",
    file: "finance/account-determination.tsx",
  },
  { path: "/finance/dimensions", kind: "desk", file: "finance/dimensions.tsx" },
  { path: "/finance/cost-centres", kind: "desk", file: "finance/cost-centres.tsx" },
  { path: "/finance/statements", kind: "desk", file: "finance/statements.tsx" },

  { path: "/governance", kind: "desk", file: "governance/index.tsx" },
  { path: "/inventory", kind: "desk", file: "inventory/index.tsx" },
  { path: "/inventory/audit", kind: "desk", file: "inventory/audit.tsx" },
  { path: "/inventory/forecast", kind: "desk", file: "inventory/forecast.tsx" },
  { path: "/inventory/warehouse", kind: "desk", file: "inventory/warehouse.tsx" },

  { path: "/logistics", kind: "desk", file: "logistics/index.tsx" },
  { path: "/logistics/release-areas", kind: "desk", file: "logistics/release-areas.tsx" },

  { path: "/master-data", kind: "desk", file: "master-data/index.tsx" },
  { path: "/master-data/classification", kind: "desk", file: "master-data/classification.tsx" },
  { path: "/master-data/imports", kind: "desk", file: "master-data/imports.tsx" },
  { path: "/master-data/item-supply", kind: "desk", file: "master-data/item-supply.tsx" },

  { path: "/operations/assurance", kind: "desk", file: "operations/assurance.tsx" },
  { path: "/operations/continuity", kind: "desk", file: "operations/continuity.tsx" },
  { path: "/operations/cutover", kind: "desk", file: "operations/cutover.tsx" },
  { path: "/operations/devices", kind: "desk", file: "operations/devices.tsx" },
  { path: "/operations/integrations", kind: "desk", file: "operations/integrations.tsx" },
  { path: "/operations/jobs", kind: "desk", file: "operations/jobs.tsx" },
  { path: "/operations/output", kind: "desk", file: "operations/output.tsx" },

  { path: "/planning", kind: "desk", file: "planning/index.tsx" },
  { path: "/procurement", kind: "desk", file: "procurement/index.tsx" },
  { path: "/production", kind: "desk", file: "production/index.tsx" },
  { path: "/quality", kind: "desk", file: "quality/index.tsx" },
  { path: "/sales", kind: "desk", file: "sales/index.tsx" },

  { path: "/reporting", kind: "desk", file: "reporting/index.tsx" },
  { path: "/reporting/distribution", kind: "desk", file: "reporting/distribution.tsx" },
  { path: "/reporting/reproducibility", kind: "desk", file: "reporting/reproducibility.tsx" },

  // A document that does not exist. The screen has to say so rather than throw:
  // a stale link out of somebody's email is the ordinary way to arrive here.
  {
    path: "/documents/00000000-0000-4000-8000-000000000fff",
    kind: "desk",
    file: "documents/$documentId.tsx",
  },
];
