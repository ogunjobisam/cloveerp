import { test as base, type Page, type Route } from "@playwright/test";

import type { ErpSession } from "../../src/lib/erp";

/**
 * The Supabase surface, answered in the browser.
 *
 * Every screen in this application reaches the database through exactly two
 * hosts' worth of HTTP: `/auth/v1/*` for the session and `/rest/v1/rpc/*` for
 * the hundred and twenty-six `public.erp_*` functions the client calls. Both
 * are interceptable from the page, which is what makes a sweep of every route
 * possible without a stack behind it — and this container has no Docker, so
 * without it there would be no sweep at all.
 *
 * What this proves and what it does not is worth being exact about. It does
 * not prove the database returns these shapes; `erp.assert_*` and the
 * `erp_test` suites do that, against the database that actually answers. What
 * it proves is the half no assertion can reach: that the screen renders, that
 * it survives the data it is given, and that it does not throw on the way.
 *
 * The default answer is the empty one, and that is a real state rather than a
 * convenience. An organisation onboarded a minute ago has no items, no
 * documents, no movements and no history; every screen in the product will be
 * rendered against exactly this emptiness by its first user, once, and a screen
 * that throws there is broken for everybody's first impression.
 */

/**
 * `[]` rather than `{}` or null, deliberately.
 *
 * Of the ninety-nine calls that declare a return type, fifty-six declare an
 * array and the rest an object. An empty array serves both: `.length` is 0,
 * `.map()` yields nothing, and a property read gives undefined exactly as an
 * empty object would. It is the most permissive empty value available over
 * JSON, so a screen that still throws against it is one that reaches into a
 * structure without checking it is there.
 */
export const EMPTY: readonly never[] = [];

const AUTH_USER = {
  id: "00000000-0000-4000-8000-00000000e2e0",
  aud: "authenticated",
  role: "authenticated",
  email: "e2e-demo@clove.invalid",
  email_confirmed_at: "2026-01-01T00:00:00Z",
  created_at: "2026-01-01T00:00:00Z",
  updated_at: "2026-01-01T00:00:00Z",
  app_metadata: { provider: "email", providers: ["email"] },
  user_metadata: {},
  identities: [],
};

/**
 * A principal with a tenant and every permission the screens name.
 *
 * The list is exactly what supabase/ci/app_permissions.sh extracts from src —
 * the same three shapes, in the same order — so it is the set the catalogue is
 * checked against rather than a set invented here.
 *
 * Every permission rather than a chosen few, and that is not a permission test
 * — it is the opposite. CLAUDE.md is explicit that walking the interface role
 * by role duplicates `erp_test.assert_grant_suite` more slowly and less
 * truthfully, because the database refuses regardless of what renders. Holding
 * everything removes permissions as a variable so that what remains under test
 * is the rendering.
 *
 * The codes come from the catalogue check added in
 * 20260906148000_every_permission_the_screens_name_exists.sql, which is what
 * guarantees this list and the screens cannot drift apart: a code the screens
 * name and the catalogue lacks fails the build.
 */
export const PERMISSIONS = [
  "administration.audit_read",
  "administration.configure",
  "administration.integrate",
  "administration.jobs",
  "administration.read",
  "administration.roles",
  "administration.users",
  "finance.approve_payment",
  "finance.close_period",
  "finance.configure",
  "finance.post",
  "finance.read",
  "finance.reopen_period",
  "inventory.adjust",
  "inventory.count",
  "inventory.move",
  "inventory.read",
  "inventory.write_off",
  "logistics.despatch",
  "logistics.plan",
  "logistics.read",
  "master_data.import",
  "master_data.read",
  "master_data.write",
  "planning.firm",
  "planning.forecast",
  "planning.read",
  "planning.run",
  "procurement.match",
  "procurement.order",
  "procurement.read",
  "procurement.receive",
  "production.execute",
  "production.order",
  "production.read",
  "production.release",
  "quality.disposition",
  "quality.inspect",
  "quality.read",
  "quality.recall",
  "quality.release_batch",
  "reporting.define",
  "reporting.export",
  "reporting.read",
  "sales.credit_release",
  "sales.invoice",
  "sales.order",
  "sales.price",
  "sales.read",
];

export const DEMO_SESSION: ErpSession = {
  principal_id: "00000000-0000-4000-8000-0000000000a1",
  tenant_id: "00000000-0000-4000-8000-0000000000b1",
  principal: {
    display_name: "E2E Demo",
    given_name: "E2E",
    family_name: "Demo",
    email: "e2e-demo@clove.invalid",
    kind: "person",
    user_locale: "en-GB",
    document_locale: "en-GB",
    reporting_locale: "en-GB",
    timezone: "Europe/London",
  },
  tenant: { code: "E2E", name: "E2E Demonstration", status: "active" },
  entities: [{ id: "00000000-0000-4000-8000-0000000000c1", code: "E1", name: "E2E Entity" }],
  sites: [
    {
      id: "00000000-0000-4000-8000-0000000000d1",
      code: "S1",
      name: "E2E Site",
      entity_id: "00000000-0000-4000-8000-0000000000c1",
    },
  ],
  permissions: PERMISSIONS,
};

/** A principal with no tenant: authenticated, and onboarding is what it gets. */
export const NO_TENANT_SESSION: ErpSession = {
  principal_id: null,
  tenant_id: null,
  entities: [],
  sites: [],
  permissions: [],
};

/**
 * The handful of functions the shell itself calls on every screen.
 *
 * These get a real shape rather than the empty default, and the reason is a
 * finding rather than a convenience. `erp_service_notices` declares an object
 * with two array fields and ServiceBanner reads them straight —
 * `n.incidents.filter(...)` after a `if (!n) return null` that an empty array
 * passes — so an unexpected payload there does not cost the banner, it costs
 * the whole desk: the banner renders inside the shell, so the throw reaches the
 * root error boundary and every screen becomes "This page didn't load".
 *
 * A correct database never sends that payload, so this is not a defect the
 * build should fail on. It is worth knowing that the blast radius of one
 * malformed banner response is the entire application, and it is worth these
 * tests exercising the shape the screens are actually written against rather
 * than one that only proves the boundary works.
 */
const SHELL: Record<string, unknown> = {
  erp_service_notices: { maintenance: [], incidents: [] },
  erp_is_platform_organisation: false,
  erp_platform_me: { is_staff: false, role: null, claimable: false },
  erp_my_tenants: [],

  // The same again, for the four screens that read an array field off an
  // object the same way ServiceBanner does. Each was found by the sweep, each
  // costs the whole page rather than the panel, and each is the stub's doing
  // rather than the product's — the shape is taken from the type the route
  // itself declares.
  erp_my_notification_settings: {
    preferences: [],
    quiet_hours: [],
    services_installed: false,
    unread: 0,
  },
  erp_commercial_summary: { plan: null },
  erp_my_agreement: {
    contract: null,
    documents: [],
    entitlements: [],
    capabilities: [],
    meters: [],
    invoices: [],
    renewal: null,
    subscription: null,
    sub_processors: [],
    service_commitments: [],
  },
  erp_personal_data_register: { fields: [], exemptions: [] },
  erp_permissions_directory: {
    principals: [],
    roles: [],
    grants: [],
    permission_catalog: [],
  },
  erp_sender_identities: {
    identities: [],
    transactional: { from_address: "", reply_to: null, own_domain: false },
    operational: { from_address: "", reply_to: null, own_domain: false },
  },
  erp_output_health: {
    requests_24h: 0,
    requests_7d: 0,
    deliveries_7d: {},
    failure_rate_7d: 0,
    print_queue_depth: 0,
  },
  erp_analytics_contract: {
    views: [],
    credentials: [],
    services_installed: false,
    findings: [],
  },
  erp_accessibility_statement: {
    product: "Clove ERP",
    standard: "WCAG 2.2",
    level_claimed: "AA",
    conformance: "partially conforms",
    reviewed_on: "2026-01-01",
    counts: { met: 0, partially_met: 0, not_met: 0, not_applicable: 0, total: 0 },
    checked_by: { automated: "", manual: "", register: "" },
    exceptions: [],
    criteria: [],
  },
};

/** How a refusal arrives: PostgREST's shape, carrying the engine's own words. */
export type RpcFailure = {
  status?: number;
  code?: string;
  message: string;
  details?: string | null;
  hint?: string | null;
};

export type Backend = {
  /** Answer one function with this payload for the rest of the test. */
  rpc(fn: string, payload: unknown): void;
  /** Refuse one function, the way the database refuses. */
  fail(fn: string, failure: RpcFailure): void;
  /** Every `erp_*` function this page actually called, in order. */
  readonly called: string[];
  /** Uncaught client errors. Empty is the only acceptable value. */
  readonly crashes: string[];
};

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-expose-headers": "*",
  "content-type": "application/json",
};

function projectRef(url: string): string {
  return /^https?:\/\/([^.]+)\./.exec(url)?.[1] ?? "e2e";
}

async function install(page: Page, session: ErpSession | null): Promise<Backend> {
  const url = process.env["VITE_SUPABASE_URL"] ?? "";
  const ref = projectRef(url);

  const payloads = new Map<string, unknown>();
  const failures = new Map<string, RpcFailure>();
  const called: string[] = [];
  const crashes: string[] = [];

  page.on("pageerror", (e) => crashes.push(`${e.name}: ${e.message}`));

  // supabase-js reads the session from storage before it asks the network, so
  // seeding it here is what makes the first paint a signed-in one. Written
  // before any application script runs, on every navigation.
  if (session) {
    await page.addInitScript(
      ({ key, expiresAt, user }) => {
        try {
          window.localStorage.setItem(
            key,
            JSON.stringify({
              access_token: "e2e-access-token",
              token_type: "bearer",
              expires_in: 3600,
              expires_at: expiresAt,
              refresh_token: "e2e-refresh-token",
              user,
            }),
          );
        } catch {
          // A browser with storage blocked. The route handlers below still
          // answer; the application simply starts signed out.
        }
      },
      {
        key: `sb-${ref}-auth-token`,
        expiresAt: Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 365,
        user: AUTH_USER,
      },
    );
  }

  const json = (route: Route, body: unknown, status = 200) =>
    route.fulfill({ status, headers: CORS, body: JSON.stringify(body) });

  await page.route("**/auth/v1/**", async (route) => {
    if (route.request().method() === "OPTIONS") {
      return route.fulfill({ status: 204, headers: CORS, body: "" });
    }
    const path = new URL(route.request().url()).pathname;
    if (path.endsWith("/user")) return json(route, AUTH_USER);
    if (path.endsWith("/logout")) return route.fulfill({ status: 204, headers: CORS, body: "" });
    return json(route, {
      access_token: "e2e-access-token",
      token_type: "bearer",
      expires_in: 3600,
      expires_at: Math.floor(Date.now() / 1000) + 60 * 60,
      refresh_token: "e2e-refresh-token",
      user: AUTH_USER,
    });
  });

  await page.route("**/rest/v1/rpc/**", async (route) => {
    if (route.request().method() === "OPTIONS") {
      return route.fulfill({ status: 204, headers: CORS, body: "" });
    }
    const fn = new URL(route.request().url()).pathname.split("/").pop() ?? "";
    called.push(fn);

    const failure = failures.get(fn);
    if (failure) {
      return json(
        route,
        {
          code: failure.code ?? "P0001",
          message: failure.message,
          details: failure.details ?? null,
          hint: failure.hint ?? null,
        },
        failure.status ?? 400,
      );
    }

    if (payloads.has(fn)) return json(route, payloads.get(fn));
    if (fn === "erp_session") return json(route, session ?? NO_TENANT_SESSION);
    if (fn in SHELL) return json(route, SHELL[fn]);
    return json(route, EMPTY);
  });

  return {
    rpc: (fn, payload) => void payloads.set(fn, payload),
    fail: (fn, failure) => void failures.set(fn, failure),
    called,
    crashes,
  };
}

/**
 * `signedIn` decides which of the gate's states the page starts in. The tests
 * that want the desk take the default; the ones that want the sign-in screen or
 * the onboarding screen say so.
 */
type Fixtures = {
  session: ErpSession | null;
  backend: Backend;
};

export const test = base.extend<Fixtures>({
  session: [DEMO_SESSION, { option: true }],

  // The second argument is Playwright's "use" callback. It is named `provide`
  // here because the React hooks lint rule reads a call to something named
  // `use` as a React hook and refuses it, which it is not and cannot be:
  // this file never renders.
  // auto, so it installs whether or not a test names it.
  //
  // It was not, and the cost was two wasted diagnostics: a test that takes only
  // `{ page }` got no interception at all, so its browser reached for the real
  // host, was refused, and rendered the sign-in screen — which reads exactly
  // like a session that failed to establish. A fixture whose absence is
  // invisible and whose symptom is plausible is a trap; this one is always on.
  backend: [
    async ({ page, session }, provide) => {
      const backend = await install(page, session);
      await provide(backend);
    },
    { auto: true },
  ],
});

export { expect } from "@playwright/test";
