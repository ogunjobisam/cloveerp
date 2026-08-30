import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useRouterState } from "@tanstack/react-router";
import { Menu } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";

import type { ErpSession } from "../../lib/erp";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { GROUP_LABELS, GROUP_ORDER, allTiles } from "../../lib/modules";
import { iconFor } from "../../lib/module-icons";
import { useBrand, useBrandedFavicon } from "../../lib/brand";
import { BrandMark } from "./logo";
import { TOUCH } from "./page";
import { UserMenu } from "./user-menu";

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
  group: "home" | (typeof GROUP_ORDER)[number];
};

/**
 * The rail, derived from the module registry.
 *
 * It used to be a hand-written list of twenty entries in the order they were
 * built, which is why Inventory sat below Permissions and the whole thing read
 * as a pile rather than a structure. Now it is Home plus the same tiles the
 * launchpad renders, in the same three groups, so the two navigations can no
 * longer disagree about what exists.
 */
const NAV: NavItem[] = [
  { to: "/", labelKey: "nav.overview", label: "Home", group: "home" },
  ...allTiles().map((tile) => ({
    to: tile.path,
    labelKey: tile.titleKey,
    label: tile.title,
    ...(tile.permission ? { permission: tile.permission } : {}),
    group: tile.group,
  })),
];

const NAV_GROUPS: NavItem["group"][] = ["home", ...GROUP_ORDER];

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
      {NAV_GROUPS.map((group) => {
        const inGroup = items.filter((i) => i.group === group);
        if (inGroup.length === 0) return null;
        return (
          <div key={group} className="mb-4 last:mb-0">
            {group === "home" ? null : (
              <p className="mb-1 px-3 text-[11px] font-medium uppercase tracking-wide text-muted-foreground/70">
                {GROUP_LABELS[group]}
              </p>
            )}
            <ul className="flex flex-col gap-1">
              {inGroup.map((item) => {
                const active = item.to === "/" ? pathname === "/" : pathname.startsWith(item.to);
                const Icon = iconFor(item.to);
                return (
                  <li key={item.to}>
                    <Link
                      to={item.to}
                      onClick={onNavigate}
                      className={[
                        TOUCH,
                        "flex items-center gap-2.5 rounded-lg px-3 text-sm transition-colors",
                        active
                          ? "bg-accent/10 font-medium text-foreground shadow-[inset_2px_0_0_var(--accent)]"
                          : "text-muted-foreground hover:bg-muted hover:text-foreground",
                      ].join(" ")}
                    >
                      <Icon
                        className={`size-4 shrink-0 ${active ? "text-accent" : "text-muted-foreground"}`}
                      />
                      <span className="truncate">{t(item.labelKey, item.label)}</span>
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}

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
  const brand = useBrand();

  // The tab icon follows the tenant, where the browser supports it.
  useBrandedFavicon(brand);

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

  return (
    // overflow-x-hidden is the backstop, not the fix: everything inside is
    // meant to fit, and this only stops one mistake becoming a page that
    // scrolls sideways.
    <div className="min-h-screen overflow-x-hidden bg-background text-foreground">
      <header className="sticky top-0 z-30 border-b border-border bg-card/85 backdrop-blur-md">
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
            <BrandMark size={28} />
            <span className="hidden font-serif text-base font-semibold tracking-[-0.02em] md:inline">
              <span style={{ color: brand.ink }}>{brand.prefix}</span>
              <span style={{ color: brand.total }}>{brand.suffix}</span>
            </span>
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
            <UserMenu session={session} onSignOut={onSignOut} />
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

          <div className="mt-auto border-t border-border pt-4">
            <UserMenu
              session={session}
              onSignOut={onSignOut}
              onNavigate={() => setDrawerOpen(false)}
              className="w-full justify-start"
            />
          </div>
        </SheetContent>
      </Sheet>

      <div className="mx-auto flex max-w-7xl gap-6 px-4 py-6">
        {/* The rail exists from md up. Below it, the drawer is the navigation
            and the content takes the full width. */}
        <nav
          className="sticky top-[4.5rem] hidden max-h-[calc(100vh-6rem)] w-56 shrink-0 overflow-y-auto pr-1 md:block"
          aria-label="Sections"
        >
          <NavList items={visible} pathname={pathname} hidden={hidden} />
        </nav>

        <main className="min-w-0 flex-1">{children}</main>
      </div>
    </div>
  );
}
