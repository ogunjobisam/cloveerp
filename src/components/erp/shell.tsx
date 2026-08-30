import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useRouterState } from "@tanstack/react-router";
import { Menu } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";

import type { ErpSession } from "../../lib/erp";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { TOUCH } from "./page";

/**
 * The application shell.
 *
 * Navigation is derived from the session's permissions rather than filtered
 * after rendering. A screen the caller could not use does not appear at all,
 * which is a smaller promise than it sounds: the permission decides what is
 * *offered*, and the database decides what is *allowed*. The second is the one
 * that matters, and it holds whatever this component does.
 *
 * The layout has one breakpoint, `md`, and it is the same 768px the rest of the
 * app uses. Above it: a fixed left rail and a header carrying tenant, scope,
 * principal and sign-out. Below it: none of that fits, so the rail and
 * everything that is not identity or context moves into a drawer, and the
 * header keeps a tenant name and a single chip saying where you are working.
 *
 * The previous layout had no breakpoint at all. The rail was 224px of a 375px
 * screen and the header's control group could not wrap, so the page was both
 * wider than the viewport and unreadable in what remained.
 */

type NavItem = {
  to: string;
  /** Resource key; `label` is the fallback used until the key resolves. */
  labelKey: string;
  label: string;
  /** Absent means always visible. */
  permission?: string;
  description: string;
};

const NAV: NavItem[] = [
  {
    to: "/",
    labelKey: "nav.overview",
    label: "Overview",
    description: "Tenant, scope and platform state",
  },
  {
    to: "/master-data",
    labelKey: "nav.master_data",
    label: "Master data",
    permission: "master_data.read",
    description: "The items and parties every document depends on",
  },
  {
    to: "/sales",
    labelKey: "nav.sales",
    label: "Sales",
    permission: "sales.read",
    description: "Quotations, orders and deliveries",
  },
  {
    to: "/procurement",
    labelKey: "nav.procurement",
    label: "Procurement",
    permission: "procurement.read",
    description: "Requisitions, purchase orders and goods receipts",
  },
  {
    to: "/operations/jobs",
    labelKey: "nav.operations_jobs",
    label: "Scheduled jobs",
    permission: "administration.jobs",
    description: "What is running, what failed, and what has stopped running",
  },
  {
    to: "/operations/integrations",
    labelKey: "nav.operations_integrations",
    label: "Integrations",
    permission: "administration.integrate",
    description: "Outbound gateway health and the queue that needs a decision",
  },
  {
    to: "/operations/assurance",
    labelKey: "nav.operations_assurance",
    label: "Assurance",
    permission: "administration.read",
    description: "The structural checks the build runs on every push",
  },
  {
    to: "/administration/configuration",
    labelKey: "nav.administration_configuration",
    label: "Configuration",
    permission: "administration.configure",
    description: "Install modules and promote the change sets that put them in force",
  },
  {
    to: "/administration/permissions",
    labelKey: "nav.administration_permissions",
    label: "Permissions",
    permission: "administration.roles",
    description: "Principals, roles, and the grants between them",
  },
  {
    to: "/inventory",
    labelKey: "nav.inventory",
    label: "Inventory",
    permission: "inventory.read",
    description: "Stock health, valuation, batches, expiry and counting",
  },
  {
    to: "/production",
    labelKey: "nav.production",
    label: "Production",
    permission: "production.read",
    description: "Works orders and their progress against plan",
  },
  {
    to: "/planning",
    labelKey: "nav.planning",
    label: "Planning",
    permission: "planning.read",
    description: "Planned orders and the exceptions worth acting on",
  },
  {
    to: "/quality",
    labelKey: "nav.quality",
    label: "Quality and recall",
    permission: "quality.read",
    description: "Events, dispositions, supplier qualification and recall",
  },
  {
    to: "/logistics",
    labelKey: "nav.logistics",
    label: "Logistics",
    permission: "logistics.read",
    description: "Shipments, carrier bookings and delivery performance",
  },
  {
    to: "/finance",
    labelKey: "nav.finance",
    label: "Finance",
    permission: "finance.read",
    description: "Trial balance, periods, receivables, tax and assets",
  },
  {
    to: "/reporting",
    labelKey: "nav.reporting",
    label: "Reporting",
    permission: "reporting.read",
    description: "Data quality, duplicates and specification coverage",
  },
  {
    to: "/governance",
    labelKey: "nav.governance",
    label: "Change requests",
    permission: "master_data.read",
    description: "Proposed master data changes and the approvals on them",
  },
  {
    to: "/master-data/imports",
    labelKey: "nav.imports",
    label: "Imports",
    permission: "master_data.import",
    description: "Staged batches, preview, validation, load and rollback",
  },
  {
    to: "/administration/terminology",
    labelKey: "nav.terminology",
    label: "Terminology",
    permission: "administration.configure",
    description: "The wording of every label, per tenant",
  },
  {
    to: "/administration/tenant",
    labelKey: "nav.tenant",
    label: "Tenant lifecycle",
    permission: "administration.configure",
    description: "Go-live, export and portability, deletion",
  },
];

function ScopeSelect({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: { id: string; code: string; name: string }[];
}) {
  return (
    <label className="flex min-w-0 flex-col gap-1">
      <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
      >
        <option value="">All</option>
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.code} — {o.name}
          </option>
        ))}
      </select>
    </label>
  );
}

type MyTenant = {
  tenant_id: string;
  code: string;
  name: string;
  principal_id: string;
  is_active: boolean;
};

/**
 * Which tenant am I working in?
 *
 * Only rendered when the answer is not obvious — one membership needs no
 * chooser. It exists because membership became per-tenant, and the database
 * was resolving the resulting ambiguity by insertion order: newest principal
 * wins. That is not a choice, and a person in two tenants had no way to reach
 * the other one. The switcher is the other half of that change.
 */
function TenantSwitch() {
  const queryClient = useQueryClient();
  const { data } = useQuery({
    queryKey: ["erp_my_tenants"],
    queryFn: () => callErp<MyTenant[]>("erp_my_tenants"),
  });

  const choose = useMutation({
    mutationFn: (tenantId: string) => callErp("erp_set_active_tenant", { p_tenant_id: tenantId }),
    // Everything on screen is scoped to the tenant that just changed.
    onSuccess: () => queryClient.invalidateQueries(),
  });

  if (!data || data.length < 2) return null;

  const active = data.find((t) => t.is_active)?.tenant_id ?? "";

  return (
    <label className="flex min-w-0 flex-col gap-1">
      <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        Tenant
      </span>
      <select
        value={active}
        disabled={choose.isPending}
        onChange={(e) => choose.mutate(e.target.value)}
        className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm disabled:opacity-60`}
      >
        {data.map((t) => (
          <option key={t.tenant_id} value={t.tenant_id}>
            {t.code} — {t.name}
          </option>
        ))}
      </select>
    </label>
  );
}

export type Scope = { entityId: string; siteId: string };

function NavList({
  items,
  pathname,
  hidden,
  onNavigate,
}: {
  items: NavItem[];
  pathname: string;
  hidden: number;
  onNavigate?: () => void;
}) {
  const { t } = useT();

  return (
    <>
      <ul className="flex flex-col gap-1">
        {items.map((item) => {
          const active = item.to === "/" ? pathname === "/" : pathname.startsWith(item.to);
          return (
            <li key={item.to}>
              <Link
                to={item.to}
                onClick={onNavigate}
                className={[
                  TOUCH,
                  "flex items-center rounded-md px-3 text-sm transition-colors",
                  active
                    ? "bg-primary/10 font-medium text-foreground"
                    : "text-muted-foreground hover:bg-muted hover:text-foreground",
                ].join(" ")}
              >
                {t(item.labelKey, item.label)}
              </Link>
            </li>
          );
        })}
      </ul>

      {hidden > 0 ? (
        <p className="mt-4 px-3 text-xs text-muted-foreground">
          Some sections are not shown because this account does not hold the permissions they
          require.
        </p>
      ) : null}
    </>
  );
}

/**
 * Where you are working, in the space a phone has for it.
 *
 * Two selects and their labels are about 300px; this is the same information
 * in about 90, and tapping it opens the drawer where the selects actually
 * live. "All" is stated rather than left blank, because an empty chip reads as
 * a loading state.
 */
function ScopeChip({
  session,
  scope,
  onClick,
}: {
  session: ErpSession;
  scope: Scope;
  onClick: () => void;
}) {
  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);
  const label = [entity?.code ?? "All", site?.code ?? "All"].join(" · ");

  return (
    <button
      type="button"
      onClick={onClick}
      className={`${TOUCH} inline-flex max-w-[9rem] shrink-0 items-center gap-1 rounded-full border border-input px-3 text-xs font-medium md:hidden`}
    >
      <span className="truncate">{label}</span>
    </button>
  );
}

export function Shell({
  session,
  scope,
  onScopeChange,
  onSignOut,
  children,
}: {
  session: ErpSession;
  scope: Scope;
  onScopeChange: (s: Scope) => void;
  onSignOut: () => void;
  children: ReactNode;
}) {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const [drawerOpen, setDrawerOpen] = useState(false);

  // A drawer left open across a navigation would cover the page it just
  // reached. Closing on the path change covers every way of navigating,
  // including the browser's own back button.
  useEffect(() => setDrawerOpen(false), [pathname]);

  // Sites are filtered by the chosen entity, because a site belongs to exactly
  // one entity and offering the others invites a selection that means nothing.
  const sites = scope.entityId
    ? session.sites.filter((s) => s.entity_id === scope.entityId)
    : session.sites;

  const visible = NAV.filter((n) => !n.permission || hasPermission(session, n.permission));
  const hidden = NAV.length - visible.length;

  const identity = (
    <div className="flex flex-col gap-1">
      <span className="text-xs text-muted-foreground">
        {session.principal?.display_name ?? "Signed in"}
      </span>
      <button
        onClick={onSignOut}
        // 44px at every width, including md — a tablet in portrait is exactly
        // 768px and is a touch device. Above md the border and background go
        // away so it still reads as the text link the desktop header had; only
        // the hit area is larger.
        className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-4 text-sm font-medium md:justify-start md:border-0 md:px-0 md:text-xs md:text-muted-foreground md:underline-offset-2 md:hover:text-foreground md:hover:underline`}
      >
        Sign out
      </button>
    </div>
  );

  return (
    // overflow-x-hidden is the backstop, not the fix: everything inside is
    // meant to fit, and this only stops one mistake becoming a page that
    // scrolls sideways.
    <div className="min-h-screen overflow-x-hidden bg-background text-foreground">
      <header className="border-b border-border bg-card">
        <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 md:flex-wrap md:gap-4">
          <button
            type="button"
            onClick={() => setDrawerOpen(true)}
            aria-label="Open menu"
            aria-expanded={drawerOpen}
            className={`${TOUCH} -ml-2 inline-flex w-11 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground md:hidden`}
          >
            <Menu className="size-5" />
          </button>

          <Link to="/" className={`${TOUCH} flex shrink-0 items-center gap-2`}>
            <span className="grid size-7 place-items-center rounded-lg bg-primary text-sm font-semibold text-primary-foreground">
              e
            </span>
            <span className="hidden text-base font-semibold md:inline">ERPWare</span>
          </Link>

          <div className="flex min-w-0 flex-1 flex-col leading-tight md:flex-none">
            <span className="truncate text-sm font-medium">
              {session.tenant?.name ?? "No tenant"}
            </span>
            <span className="hidden text-xs text-muted-foreground md:inline">
              {session.tenant?.code ?? "—"}
              {session.tenant?.status && session.tenant.status !== "active"
                ? ` · ${session.tenant.status}`
                : ""}
            </span>
          </div>

          <ScopeChip session={session} scope={scope} onClick={() => setDrawerOpen(true)} />

          {/* Everything here is in the drawer below md. */}
          <div className="ml-auto hidden items-end gap-3 md:flex">
            <TenantSwitch />
            <ScopeSelect
              label="Entity"
              value={scope.entityId}
              onChange={(entityId) => onScopeChange({ entityId, siteId: "" })}
              options={session.entities}
            />
            <ScopeSelect
              label="Site"
              value={scope.siteId}
              onChange={(siteId) => onScopeChange({ ...scope, siteId })}
              options={sites}
            />
            <div className="pl-2 text-right">{identity}</div>
          </div>
        </div>
      </header>

      <Sheet open={drawerOpen} onOpenChange={setDrawerOpen}>
        <SheetContent side="left" className="flex w-[85vw] max-w-sm flex-col gap-6 overflow-y-auto">
          <SheetTitle className="text-base">{session.tenant?.name ?? "No tenant"}</SheetTitle>

          <nav aria-label="Sections">
            <NavList
              items={visible}
              pathname={pathname}
              hidden={hidden}
              onNavigate={() => setDrawerOpen(false)}
            />
          </nav>

          <div className="flex flex-col gap-3 border-t border-border pt-4">
            <TenantSwitch />
            <ScopeSelect
              label="Entity"
              value={scope.entityId}
              onChange={(entityId) => onScopeChange({ entityId, siteId: "" })}
              options={session.entities}
            />
            <ScopeSelect
              label="Site"
              value={scope.siteId}
              onChange={(siteId) => onScopeChange({ ...scope, siteId })}
              options={sites}
            />
          </div>

          <div className="mt-auto border-t border-border pt-4">{identity}</div>
        </SheetContent>
      </Sheet>

      <div className="mx-auto flex max-w-7xl gap-6 px-4 py-6">
        {/* The rail exists from md up. Below it, the drawer is the navigation
            and the content takes the full width. */}
        <nav className="hidden w-56 shrink-0 md:block" aria-label="Sections">
          <NavList items={visible} pathname={pathname} hidden={hidden} />
        </nav>

        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </div>
  );
}
