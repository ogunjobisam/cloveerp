import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useRouterState } from "@tanstack/react-router";
import type { ReactNode } from "react";

import type { ErpSession } from "../../lib/erp";
import { callErp, hasPermission } from "../../lib/erp";

/**
 * The application shell.
 *
 * Navigation is derived from the session's permissions rather than filtered
 * after rendering. A screen the caller could not use does not appear at all,
 * which is a smaller promise than it sounds: the permission decides what is
 * *offered*, and the database decides what is *allowed*. The second is the one
 * that matters, and it holds whatever this component does.
 */

type NavItem = {
  to: string;
  label: string;
  /** Absent means always visible. */
  permission?: string;
  description: string;
};

const NAV: NavItem[] = [
  { to: "/", label: "Overview", description: "Tenant, scope and platform state" },
  {
    to: "/operations/jobs",
    label: "Scheduled jobs",
    permission: "administration.jobs",
    description: "What is running, what failed, and what has stopped running",
  },
  {
    to: "/operations/integrations",
    label: "Integrations",
    permission: "administration.integrate",
    description: "Outbound gateway health and the queue that needs a decision",
  },
  {
    to: "/operations/assurance",
    label: "Assurance",
    permission: "administration.read",
    description: "The structural checks the build runs on every push",
  },
  {
    to: "/administration/permissions",
    label: "Permissions",
    permission: "administration.roles",
    description: "Principals, roles, and the grants between them",
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
    <label className="flex flex-col gap-1">
      <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        {label}
      </span>
      <select
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="rounded-md border border-input bg-background px-2 py-1.5 text-sm"
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
    <label className="flex flex-col gap-1">
      <span className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
        Tenant
      </span>
      <select
        value={active}
        disabled={choose.isPending}
        onChange={(e) => choose.mutate(e.target.value)}
        className="rounded-md border border-input bg-background px-2 py-1.5 text-sm disabled:opacity-60"
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

  // Sites are filtered by the chosen entity, because a site belongs to exactly
  // one entity and offering the others invites a selection that means nothing.
  const sites = scope.entityId
    ? session.sites.filter((s) => s.entity_id === scope.entityId)
    : session.sites;

  const visible = NAV.filter((n) => !n.permission || hasPermission(session, n.permission));

  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="border-b border-border bg-card">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-4 px-4 py-3">
          <Link to="/" className="flex items-center gap-2">
            <span className="grid size-7 place-items-center rounded-lg bg-primary text-sm font-semibold text-primary-foreground">
              e
            </span>
            <span className="text-base font-semibold">ERPWare</span>
          </Link>

          <div className="flex flex-col leading-tight">
            <span className="text-sm font-medium">{session.tenant?.name ?? "No tenant"}</span>
            <span className="text-xs text-muted-foreground">
              {session.tenant?.code ?? "—"}
              {session.tenant?.status && session.tenant.status !== "active"
                ? ` · ${session.tenant.status}`
                : ""}
            </span>
          </div>

          <div className="ml-auto flex items-end gap-3">
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
            <div className="flex flex-col items-end gap-1 pl-2">
              <span className="text-xs text-muted-foreground">
                {session.principal?.display_name ?? "Signed in"}
              </span>
              <button
                onClick={onSignOut}
                className="text-xs font-medium text-muted-foreground underline-offset-2 hover:text-foreground hover:underline"
              >
                Sign out
              </button>
            </div>
          </div>
        </div>
      </header>

      <div className="mx-auto flex max-w-7xl gap-6 px-4 py-6">
        <nav className="w-56 shrink-0" aria-label="Sections">
          <ul className="flex flex-col gap-1">
            {visible.map((item) => {
              const active = item.to === "/" ? pathname === "/" : pathname.startsWith(item.to);
              return (
                <li key={item.to}>
                  <Link
                    to={item.to}
                    className={[
                      "block rounded-md px-3 py-2 text-sm transition-colors",
                      active
                        ? "bg-primary/10 font-medium text-foreground"
                        : "text-muted-foreground hover:bg-muted hover:text-foreground",
                    ].join(" ")}
                  >
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>

          {visible.length < NAV.length ? (
            <p className="mt-4 px-3 text-xs text-muted-foreground">
              Some sections are not shown because this account does not hold the permissions they
              require.
            </p>
          ) : null}
        </nav>

        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </div>
  );
}
