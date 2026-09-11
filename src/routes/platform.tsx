import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  Building2,
  FileSignature,
  Gavel,
  HeartPulse,
  LayoutDashboard,
  ShieldCheck,
  Users,
} from "lucide-react";

import { Wordmark } from "../components/erp/logo";
import { Ownership } from "../components/erp/ownership";
import { Pill } from "../components/erp/panel";
import { TOUCH } from "../components/erp/page";
import { callErp, isConfigured, supabase } from "../lib/erp";
import { ROLE_BLURB, usePlatformMe, type PlatformRole } from "../lib/platform";
import { Card, Fail } from "../components/platform/kit";
import { Companies } from "../components/platform/organisations";
import { Staff } from "../components/platform/staff";
import { Activity } from "../components/platform/activity";
import { Decisions } from "../components/platform/decisions";
import { Enquiries } from "../components/platform/enquiries";
import { Plans } from "../components/platform/plans";
import { Overview } from "../components/platform/overview";
import { Diagnostics } from "../components/platform/diagnostics";
import { Queue } from "../components/platform/queue";
import { Deployment } from "../components/platform/deployment";
import { Incidents } from "../components/platform/incidents";
import { Contracts } from "../components/platform/contracts";
import { Revenue } from "../components/platform/revenue";

/**
 * The platform console.
 *
 * It sits outside the tenant shell on purpose. The shell exists to render one
 * company; this screen is about all of them, and its most important user — the
 * owner on the day the product is first deployed — has no company at all. A
 * console that only appeared once you belonged somewhere would be unreachable
 * exactly when it is needed.
 *
 * FOUR AREAS, NOT NINE TABS
 *
 * This began as five equally-weighted tabs and would have become nine. Nine
 * answers "where is everything" and never answers "what should I look at",
 * which is the question somebody opening a console actually has. So the areas
 * are grouped the way the app shell groups its navigation, and Overview is the
 * landing view: it reads across every organisation and links into the area that
 * fixes whatever it found.
 *
 * The panels themselves live in components/platform. This file is the shell,
 * the auth gate and the rail — it was 1,037 lines and would have been twice
 * that.
 */

export const Route = createFileRoute("/platform")({
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

/**
 * The four jobs this console has. Ownership sits under Organisations because it
 * is an action taken once in the life of a company and belongs beside the
 * company it transfers, not in a tab of its own.
 */
type AreaKey = "overview" | "organisations" | "commercial" | "health" | "governance";

const AREAS: {
  key: AreaKey;
  label: string;
  blurb: string;
  icon: ReactNode;
  views: { key: string; label: string }[];
}[] = [
  {
    key: "overview",
    label: "Overview",
    blurb: "What needs you, across every organisation.",
    icon: <LayoutDashboard className="size-4" />,
    views: [{ key: "overview", label: "Overview" }],
  },
  {
    key: "organisations",
    label: "Organisations",
    blurb: "The companies on this deployment, and everything done to one.",
    icon: <Building2 className="size-4" />,
    views: [
      { key: "organisations", label: "All organisations" },
      { key: "ownership", label: "Ownership transfers" },
      { key: "plans", label: "Plans and subscriptions" },
    ],
  },
  {
    key: "commercial",
    label: "Commercial",
    blurb:
      "Contracts with the organisations on this deployment, what each provisions, and what they add up to.",
    icon: <FileSignature className="size-4" />,
    views: [
      { key: "contracts", label: "Contracts" },
      { key: "revenue", label: "Revenue and renewals" },
      { key: "enquiries", label: "Enquiries" },
    ],
  },
  {
    key: "health",
    label: "Health",
    blurb: "Whether this deployment is sound, doing its work, and up to date.",
    icon: <HeartPulse className="size-4" />,
    views: [
      { key: "diagnostics", label: "Diagnostics" },
      { key: "queue", label: "Jobs and queue" },
      { key: "deployment", label: "Deployment" },
      { key: "incidents", label: "Incidents and notices" },
    ],
  },
  {
    key: "governance",
    label: "Governance",
    blurb: "Who may work here, what they did, and what was decided.",
    icon: <Gavel className="size-4" />,
    views: [
      { key: "staff", label: "Staff" },
      { key: "activity", label: "Activity" },
      { key: "decisions", label: "Decisions" },
    ],
  },
];

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

function PlatformConsole() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [area, setArea] = useState<AreaKey>("overview");
  const [view, setView] = useState<string | null>(null);
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

  const current = AREAS.find((a) => a.key === area) ?? AREAS[0]!;
  const currentView =
    view && current.views.some((v) => v.key === view) ? view : current.views[0]!.key;

  const go = (next: string) => {
    const target = AREAS.find((a) => a.key === next);
    if (!target) return;
    setArea(target.key);
    setView(target.views[0]!.key);
  };

  return (
    <Frame
      right={
        <span className="hidden items-center gap-2 text-xs text-muted-foreground sm:inline-flex">
          {me.data.email}
          <Pill tone={role === "owner" ? "ok" : role === "operator" ? "warn" : "muted"}>
            {role}
          </Pill>
        </span>
      }
    >
      <div className="flex flex-col gap-6 lg:flex-row">
        {/* The rail. Horizontal and scrollable below lg, because a console read
            on a phone at 2am is a real thing that happens. */}
        <nav className="lg:w-52 lg:shrink-0">
          <ul className="flex gap-1 overflow-x-auto lg:flex-col lg:overflow-visible">
            {AREAS.map((a) => (
              <li key={a.key} className="shrink-0 lg:shrink">
                <button
                  type="button"
                  onClick={() => {
                    setArea(a.key);
                    setView(a.views[0]!.key);
                  }}
                  className={`${TOUCH} flex w-full items-center gap-2 whitespace-nowrap rounded-md px-3 text-sm font-medium ${
                    area === a.key ? "bg-primary text-primary-foreground" : "hover:bg-muted"
                  }`}
                >
                  {a.icon}
                  {a.label}
                </button>
              </li>
            ))}
          </ul>
        </nav>

        <div className="min-w-0 flex-1">
          <div className="mb-5">
            <h1 className="font-display text-2xl font-semibold tracking-tight">{current.label}</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              {current.blurb} {area === "overview" ? ROLE_BLURB[role] : ""}
            </p>
          </div>

          {/* A second level only where an area genuinely holds more than one
              thing. A single-view area shows no chrome for choosing it. */}
          {current.views.length > 1 ? (
            <nav className="mb-5 flex gap-1 overflow-x-auto rounded-lg border border-border bg-card p-1">
              {current.views.map((v) => (
                <button
                  key={v.key}
                  type="button"
                  onClick={() => setView(v.key)}
                  className={`${TOUCH} shrink-0 rounded-md px-3 text-sm font-medium ${
                    currentView === v.key ? "bg-muted" : "hover:bg-muted/60"
                  }`}
                >
                  {v.label}
                </button>
              ))}
            </nav>
          ) : null}

          {currentView === "overview" ? <Overview onGo={go} /> : null}
          {currentView === "organisations" ? <Companies role={role} /> : null}
          {currentView === "ownership" ? <Ownership /> : null}
          {currentView === "diagnostics" ? <Diagnostics /> : null}
          {currentView === "queue" ? <Queue /> : null}
          {currentView === "deployment" ? <Deployment /> : null}
          {currentView === "incidents" ? <Incidents /> : null}
          {currentView === "staff" ? <Staff role={role} /> : null}
          {currentView === "activity" ? <Activity /> : null}
          {currentView === "decisions" ? <Decisions /> : null}
          {currentView === "plans" ? <Plans /> : null}
          {currentView === "contracts" ? <Contracts role={role} /> : null}
          {currentView === "revenue" ? <Revenue role={role} /> : null}
          {currentView === "enquiries" ? <Enquiries role={role} /> : null}
        </div>
      </div>
    </Frame>
  );
}
