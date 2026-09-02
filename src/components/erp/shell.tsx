import { Link, useRouterState } from "@tanstack/react-router";
import { Briefcase, Menu, Settings2 } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";

import type { ErpSession } from "../../lib/erp";
import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { usePlatformOrganisation } from "../../lib/platform-organisation";
import {
  AREA_HOME,
  GROUP_LABELS,
  SETTINGS_GROUPS,
  WORK_GROUPS,
  allTiles,
  areaOf,
  type Area,
  type TileGroup,
} from "../../lib/modules";
import { iconFor } from "../../lib/module-icons";
import { useBrand, useBrandedFavicon } from "../../lib/brand";
import { ContextHelp } from "./context-help";
import { BrandMark } from "./logo";
import { TOUCH } from "./page";
import { UserMenu } from "./user-menu";

/**
 * The application shell.
 *
 * Two areas, one switch. Work is the operating flow and its records; Settings
 * is the organisation, its configuration, its plumbing and its assurance. The
 * header carries the switch, and the rail shows only the area you are in, so
 * a warehouse operative's rail is six entries long and an administrator
 * setting the organisation up is not scrolling past worklists to find the
 * permission screen. Which area a path belongs to is derived from the tile
 * registry, never from the URL's spelling.
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
 */

type NavItem = {
  to: string;
  /** Resource key; `label` is the fallback used until the key resolves. */
  labelKey: string;
  label: string;
  /** Absent means always visible. */
  permission?: string;
  /** Offered only inside the platform's own organisation. */
  platformOnly?: boolean;
  group: "home" | TileGroup;
  area: Area;
};

/**
 * The rail, derived from the module registry: each area's home, then the same
 * tiles the launchpads render, in the same groups, so the navigations cannot
 * disagree about what exists or where it lives.
 */
const NAV: NavItem[] = [
  { to: "/", labelKey: "nav.overview", label: "Home", group: "home", area: "work" },
  { to: "/settings", labelKey: "nav.settings", label: "Settings", group: "home", area: "settings" },
  ...allTiles().map((tile) => ({
    to: tile.path,
    labelKey: tile.titleKey,
    label: tile.title,
    ...(tile.permission ? { permission: tile.permission } : {}),
    ...(tile.platformOnly ? { platformOnly: true } : {}),
    group: tile.group,
    area: areaOf(tile.group),
  })),
];

const AREA_GROUPS: Record<Area, NavItem["group"][]> = {
  work: ["home", ...WORK_GROUPS],
  settings: ["home", ...SETTINGS_GROUPS],
};

/** Which area a path is in: the longest tile prefix decides; Settings home is its own. */
function areaOfPath(pathname: string): Area {
  if (pathname === "/settings" || pathname.startsWith("/settings/")) return "settings";
  const match = allTiles()
    .filter((t) => pathname === t.path || pathname.startsWith(`${t.path}/`))
    .sort((a, b) => b.path.length - a.path.length)[0];
  return match ? areaOf(match.group) : "work";
}

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

export type Scope = { entityId: string; siteId: string };

/**
 * The switch between the two areas. Offered only when the account can open
 * something in both; an operative with no settings at all sees no switch and
 * no mention of an area they cannot enter.
 */
function AreaSwitch({
  area,
  counts,
  onNavigate,
  className = "",
}: {
  area: Area;
  counts: Record<Area, number>;
  onNavigate?: () => void;
  className?: string;
}) {
  const { t } = useT();
  if (counts.settings === 0 || counts.work === 0) return null;

  const items: { area: Area; labelKey: string; label: string; icon: typeof Briefcase }[] = [
    { area: "work", labelKey: "nav.work", label: "Work", icon: Briefcase },
    { area: "settings", labelKey: "nav.settings", label: "Settings", icon: Settings2 },
  ];

  return (
    <nav aria-label="Areas" className={className}>
      <ul className="inline-flex rounded-lg border border-border bg-muted/50 p-0.5">
        {items.map((item) => {
          const active = item.area === area;
          const Icon = item.icon;
          return (
            <li key={item.area}>
              <Link
                to={AREA_HOME[item.area]}
                onClick={onNavigate}
                aria-current={active ? "location" : undefined}
                className={[
                  "inline-flex min-h-10 items-center gap-1.5 rounded-md px-3 text-sm font-medium transition-colors",
                  active
                    ? "bg-card text-foreground shadow-[var(--shadow-card)]"
                    : "text-muted-foreground hover:text-foreground",
                ].join(" ")}
              >
                <Icon className="size-4" />
                {t(item.labelKey, item.label)}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

function NavList({
  items,
  area,
  pathname,
  hidden,
  onNavigate,
}: {
  items: NavItem[];
  area: Area;
  pathname: string;
  hidden: number;
  onNavigate?: () => void;
}) {
  const { t, ui } = useT();

  return (
    <>
      {AREA_GROUPS[area].map((group) => {
        const inGroup = items.filter((i) => i.area === area && i.group === group);
        if (inGroup.length === 0) return null;
        return (
          <div key={group} className="mb-4 last:mb-0">
            {group === "home" ? null : (
              <p className="mb-1 px-3 text-[11px] font-medium uppercase tracking-wide text-muted-foreground">
                {ui(GROUP_LABELS[group])}
              </p>
            )}
            <ul className="flex flex-col gap-1">
              {inGroup.map((item) => {
                const active =
                  item.group === "home"
                    ? pathname === item.to
                    : pathname === item.to || pathname.startsWith(`${item.to}/`);
                const Icon = iconFor(item.to);
                return (
                  <li key={item.to}>
                    <Link
                      to={item.to}
                      onClick={onNavigate}
                      aria-current={active ? "page" : undefined}
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
          {ui(
            "Some sections are not shown because this account does not hold the permissions they require.",
          )}
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

  const platform = usePlatformOrganisation(Boolean(session.tenant_id));
  const visible = NAV.filter(
    (n) => (!n.permission || hasPermission(session, n.permission)) && (!n.platformOnly || platform),
  );
  const hidden = NAV.length - visible.length;
  const area = areaOfPath(pathname);
  const counts: Record<Area, number> = {
    work: visible.filter((n) => n.area === "work" && n.group !== "home").length,
    settings: visible.filter((n) => n.area === "settings" && n.group !== "home").length,
  };

  return (
    // overflow-x-hidden is the backstop, not the fix: everything inside is
    // meant to fit, and this only stops one mistake becoming a page that
    // scrolls sideways.
    <div className="min-h-screen overflow-x-hidden bg-background text-foreground">
      {/* The first thing a keyboard reaches. Invisible until focused, so it
          costs sighted mouse users nothing and saves a keyboard user the
          twenty-odd rail links on every page (WCAG 2.4.1). */}
      <a
        href="#main"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded-md focus:bg-card focus:px-4 focus:py-2 focus:text-sm focus:font-medium focus:shadow-[var(--shadow-card)]"
      >
        Skip to content
      </a>
      <header className="sticky top-0 z-30 border-b border-border bg-card/85 backdrop-blur-md">
        <div className="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 md:gap-4">
          <button
            type="button"
            onClick={() => setDrawerOpen(true)}
            aria-label="Open menu"
            aria-expanded={drawerOpen}
            className={`${TOUCH} -ml-2 inline-flex w-11 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground md:hidden`}
          >
            <Menu className="size-5" />
          </button>

          <Link to={AREA_HOME[area]} className={`${TOUCH} flex shrink-0 items-center gap-2`}>
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

          <AreaSwitch area={area} counts={counts} className="hidden md:block" />

          <ScopeChip session={session} scope={scope} onClick={() => setDrawerOpen(true)} />

          {/* Help for the screen you are on, at every width: the one control
              that stays out of the drawer, because the question "what is this
              screen for" is asked most on the phone. */}
          <ContextHelp />

          {/* Everything here is in the drawer below md. */}
          <div className="ml-auto hidden items-end gap-3 md:flex">
            <ScopeSelect
              label="Company"
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

          <AreaSwitch area={area} counts={counts} onNavigate={() => setDrawerOpen(false)} />

          <nav aria-label="Sections">
            <NavList
              items={visible}
              area={area}
              pathname={pathname}
              hidden={hidden}
              onNavigate={() => setDrawerOpen(false)}
            />
          </nav>

          <div className="flex flex-col gap-3 border-t border-border pt-4">
            <ScopeSelect
              label="Company"
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
          <NavList items={visible} area={area} pathname={pathname} hidden={hidden} />
        </nav>

        <main id="main" tabIndex={-1} className="min-w-0 flex-1 outline-none">
          {children}
        </main>
      </div>
    </div>
  );
}
