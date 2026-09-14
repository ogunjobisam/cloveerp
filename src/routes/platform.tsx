import { useMutation, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link } from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  BookOpen,
  Building2,
  CalendarCheck,
  Handshake,
  ReceiptText,
  ShieldCheck,
  Server,
} from "lucide-react";

import { Wordmark } from "../components/erp/logo";
import { Pill } from "../components/erp/panel";
import { TOUCH } from "../components/erp/page";
import { callErp, isConfigured, supabase } from "../lib/erp";
import { ROLE_BLURB, usePlatformMe, type PlatformRole } from "../lib/platform";
import {
  CONSOLE_SECTIONS,
  consoleSearch,
  locate,
  parseConsoleSearch,
  type ConsoleView,
  type SectionKey,
  type ViewKey,
} from "../lib/platform-console";
import { Card, Fail } from "../components/platform/kit";
import { Companies, Ownership } from "../components/platform/organisations";
import { OrganisationPage } from "../components/platform/organisation";
import { Staff } from "../components/platform/staff";
import { Activity } from "../components/platform/activity";
import { Decisions } from "../components/platform/decisions";
import { Enquiries } from "../components/platform/enquiries";
import { Plans } from "../components/platform/plans";
import { Today } from "../components/platform/today";
import { HealthSummary } from "../components/platform/health-summary";
import { Diagnostics } from "../components/platform/diagnostics";
import { Queue } from "../components/platform/queue";
import { Deployment } from "../components/platform/deployment";
import { Incidents } from "../components/platform/incidents";
import { Contracts } from "../components/platform/contracts";
import { Quotes } from "../components/platform/quotes";
import { Revenue } from "../components/platform/revenue";
import { SellingPage } from "../components/platform/catalogue";

/**
 * The platform console.
 *
 * It sits outside the tenant shell on purpose. The shell exists to render one
 * company; this screen is about all of them, and its most important user — the
 * owner on the day the product is first deployed — has no company at all. A
 * console that only appeared once you belonged somewhere would be unreachable
 * exactly when it is needed.
 *
 * SECTIONS BY JOB, AND THE PLACE IN THE ADDRESS
 *
 * The sections are the jobs of running the business — Today, Customers, Sales,
 * Catalogue, Billing, Platform — rather than the areas the code was written in,
 * and the console opens on Today: what needs doing, each with a button to the
 * tab that does it.
 *
 * Where you are is in the URL (?section=…&view=…&org=…), read by
 * src/lib/platform-console.ts, so every place can be linked to, bookmarked and
 * returned to with Back. An address that names nowhere opens Today.
 *
 * The panels live in components/platform. This file is the shell, the auth gate
 * and the navigation.
 */

export const Route = createFileRoute("/platform")({
  validateSearch: parseConsoleSearch,
  head: () => ({
    meta: [
      { title: "Platform console — Clove ERP" },
      {
        name: "description",
        content:
          "Onboard companies, manage platform staff, and review every platform action taken across Clove ERP tenants.",
      },
      { property: "og:title", content: "Platform console — Clove ERP" },
      {
        property: "og:description",
        content:
          "Onboard companies, manage platform staff, and review audited cross-tenant access.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: PlatformConsole,
});

const ICONS: Record<SectionKey, ReactNode> = {
  today: <CalendarCheck className="size-4" />,
  customers: <Building2 className="size-4" />,
  sales: <Handshake className="size-4" />,
  catalogue: <BookOpen className="size-4" />,
  billing: <ReceiptText className="size-4" />,
  platform: <Server className="size-4" />,
};

type ViewContext = { role: PlatformRole; org: string | null };

/**
 * Every tab's panel. Keyed by the view keys in platform-console.ts, so a tab
 * added there without a panel here does not compile.
 */
const PANELS: Record<ViewKey, (ctx: ViewContext) => ReactNode> = {
  today: () => <Today />,
  organisations: ({ role, org }) =>
    org ? <OrganisationPage code={org} role={role} /> : <Companies role={role} />,
  ownership: () => <Ownership />,
  enquiries: ({ role }) => <Enquiries role={role} />,
  quotes: ({ role }) => <Quotes role={role} />,
  contracts: ({ role }) => <Contracts role={role} />,
  selling: ({ role }) => <SellingPage role={role} />,
  plans: () => <Plans />,
  revenue: ({ role }) => <Revenue role={role} />,
  health: () => <HealthSummary />,
  diagnostics: () => <Diagnostics />,
  queue: () => <Queue />,
  deployment: () => <Deployment />,
  incidents: () => <Incidents />,
  staff: ({ role }) => <Staff role={role} />,
  activity: () => <Activity />,
  decisions: () => <Decisions />,
};

function Frame({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="min-h-screen bg-background">
      <header className="sticky top-0 z-20 border-b border-border bg-background/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-4 py-3">
          <div className="flex items-center gap-3">
            <Wordmark size={26} />
            <span className="rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary">
              Platform
            </span>
          </div>
          <div className="flex items-center gap-3">
            {right}
            <Link
              to="/"
              className={`${TOUCH} inline-flex items-center text-sm underline underline-offset-2`}
            >
              Back to the app
            </Link>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
    </div>
  );
}

/** The tabs of a section, in their groups where it has any. */
function groupsOf(views: readonly ConsoleView[]): { group: string | null; views: ConsoleView[] }[] {
  const out: { group: string | null; views: ConsoleView[] }[] = [];
  for (const v of views) {
    const group = v.group ?? null;
    const last = out[out.length - 1];
    if (last && last.group === group) last.views.push(v);
    else out.push({ group, views: [v] });
  }
  return out;
}

function PlatformConsole() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const search = Route.useSearch();
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!supabase) {
      setReady(true);
      return;
    }
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const me = usePlatformMe(Boolean(session));

  const claim = useMutation({
    mutationFn: () => callErp("erp_platform_claim_ownership", { p_display_name: null }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["erp_platform_me"] }),
  });

  // Two different things, and folding them together left the console spinning
  // for ever on a build with no project rather than saying so once.
  if (!isConfigured) {
    return (
      <Frame>
        <Card
          title="Not connected to a project"
          icon={<ShieldCheck className="size-4 text-primary" />}
        >
          <p className="text-sm text-muted-foreground">
            This build has no Supabase project configured, so there is nothing for the console to
            read. Set{" "}
            <code className="rounded bg-muted px-1 py-0.5 text-xs">VITE_SUPABASE_URL</code> and{" "}
            <code className="rounded bg-muted px-1 py-0.5 text-xs">
              VITE_SUPABASE_PUBLISHABLE_KEY
            </code>{" "}
            in the host and publish again.
          </p>
        </Card>
      </Frame>
    );
  }

  if (!ready) {
    return (
      <Frame>
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      </Frame>
    );
  }

  if (!session) {
    return (
      <Frame>
        <Card title="Sign in first" icon={<ShieldCheck className="size-4 text-primary" />}>
          <p className="text-sm text-muted-foreground">
            The platform console is only offered to signed-in platform staff.{" "}
            <Link to="/signin" className="underline underline-offset-2">
              Sign in
            </Link>{" "}
            and come back.
          </p>
        </Card>
      </Frame>
    );
  }

  if (me.isPending) {
    return (
      <Frame>
        <p className="text-sm text-muted-foreground">Checking your platform access…</p>
      </Frame>
    );
  }

  if (!me.data?.is_staff) {
    return (
      <Frame right={<span className="text-xs text-muted-foreground">{session.user.email}</span>}>
        <Card title="Not platform staff" icon={<ShieldCheck className="size-4 text-primary" />}>
          {me.data?.claimable ? (
            <>
              <p className="text-sm text-muted-foreground">
                Nobody owns this deployment yet. Claiming ownership makes this account the first
                owner, and the claim itself is recorded. It can only ever happen once.
              </p>
              {claim.error ? <div className="mt-3">{<Fail error={claim.error} />}</div> : null}
              <button
                type="button"
                onClick={() => claim.mutate()}
                disabled={claim.isPending}
                className={`${TOUCH} mt-4 rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
              >
                {claim.isPending ? "Claiming…" : "Claim ownership"}
              </button>
            </>
          ) : (
            <p className="text-sm text-muted-foreground">
              This account is not on the platform staff list. An owner can add it.
            </p>
          )}
        </Card>
      </Frame>
    );
  }

  const role = me.data.role as PlatformRole;
  const { section, view, org } = locate(search);

  return (
    <Frame
      right={
        <span className="hidden items-center gap-2 text-xs text-muted-foreground sm:inline-flex">
          {me.data.email}
          {/* What the role may do, on the role itself: it read as a second
              sentence of Today's subtitle, run on from the section's own. */}
          <span title={ROLE_BLURB[role]} className="inline-flex">
            <Pill tone={role === "owner" ? "ok" : role === "operator" ? "warn" : "muted"}>
              {role}
            </Pill>
            <span className="sr-only">. {ROLE_BLURB[role]}</span>
          </span>
        </span>
      }
    >
      <div className="flex flex-col gap-6 lg:flex-row">
        {/* The rail. Horizontal and scrollable below lg, because a console read
            on a phone at 2am is a real thing that happens. Links, not buttons:
            each section is an address that can be opened in a new tab. */}
        <nav aria-label="Console sections" className="lg:w-52 lg:shrink-0">
          <ul className="flex gap-1 overflow-x-auto lg:flex-col lg:overflow-visible">
            {CONSOLE_SECTIONS.map((s) => {
              const current = s.key === section.key;
              return (
                <li key={s.key} className="shrink-0 lg:shrink">
                  <Link
                    to="/platform"
                    search={consoleSearch(s.key)}
                    aria-current={current ? "page" : undefined}
                    className={`${TOUCH} flex w-full items-center gap-2 whitespace-nowrap rounded-md px-3 text-sm font-medium ${
                      current ? "bg-primary text-primary-foreground" : "hover:bg-muted"
                    }`}
                  >
                    {ICONS[s.key]}
                    {s.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </nav>

        <div className="min-w-0 flex-1">
          <div className="mb-5">
            <h1 className="font-display text-2xl font-semibold tracking-tight">{section.label}</h1>
            <p className="mt-1 text-sm text-muted-foreground">{section.blurb}</p>
          </div>

          {/* A second level only where a section genuinely holds more than one
              thing. A single-view section shows no chrome for choosing it. */}
          {section.views.length > 1 ? (
            <nav
              aria-label={`${section.label} tabs`}
              className="mb-5 flex flex-wrap gap-x-3 gap-y-1 overflow-x-auto rounded-lg border border-border bg-card p-1"
            >
              {groupsOf(section.views).map((g) => (
                <div key={g.group ?? "tabs"} className="flex min-w-0 items-center gap-1">
                  {g.group ? (
                    <span className="px-2 text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                      {g.group}
                    </span>
                  ) : null}
                  {g.views.map((v) => {
                    const current = v.key === view.key;
                    return (
                      <Link
                        key={v.key}
                        to="/platform"
                        search={consoleSearch(section.key, v.key as ViewKey)}
                        aria-current={current ? "page" : undefined}
                        className={`${TOUCH} inline-flex shrink-0 items-center rounded-md px-3 text-sm font-medium ${
                          current ? "bg-muted" : "hover:bg-muted/60"
                        }`}
                      >
                        {v.label}
                      </Link>
                    );
                  })}
                </div>
              ))}
            </nav>
          ) : null}

          {PANELS[view.key]({ role, org })}
        </div>
      </div>
    </Frame>
  );
}
