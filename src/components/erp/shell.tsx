import { Link, useRouterState } from "@tanstack/react-router";
import { Briefcase, Building2, ChevronDown, Menu, Settings2 } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";

import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
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
import { CommandPalette } from "./command-palette";
import { MainMenu } from "./menu";
import { ServiceBanner } from "./service-banner";
import { ContextHelp } from "./context-help";
import { BrandMark } from "./logo";
import { Breadcrumbs } from "./breadcrumbs";
import { UnsavedChangesProvider } from "./unsaved";
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

/**
 * The section list, in either of the two places it appears: the dark rail on a
 * wide screen and the light drawer on a narrow one. Same list, same order, two
 * palettes — `tone` is the only difference between them.
 */
function NavList({
  items,
  area,
  pathname,
  hidden,
  onNavigate,
  tone = "light",
}: {
  items: NavItem[];
  area: Area;
  pathname: string;
  hidden: number;
  onNavigate?: () => void;
  tone?: "light" | "dark";
}) {
  const { t, ui } = useT();
  const dark = tone === "dark";

  const groupLabel = dark ? "text-sidebar-muted/80" : "text-muted-foreground";
  const quiet = dark ? "text-sidebar-muted" : "text-muted-foreground";

  return (
    <>
      {AREA_GROUPS[area].map((group) => {
        const inGroup = items.filter((i) => i.area === area && i.group === group);
        if (inGroup.length === 0) return null;
        return (
          <div key={group} className="mb-4 last:mb-0">
            {group === "home" ? null : (
              <p
                className={`mb-1 px-3 text-[11px] font-medium uppercase tracking-wide ${groupLabel}`}
              >
                {ui(GROUP_LABELS[group])}
              </p>
            )}
            <ul className="flex flex-col gap-0.5">
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
                          ? dark
                            ? "bg-sidebar-active font-medium text-sidebar-foreground shadow-[inset_3px_0_0_var(--accent)]"
                            : "bg-accent/10 font-medium text-foreground shadow-[inset_3px_0_0_var(--accent)]"
                          : dark
                            ? "text-sidebar-muted hover:bg-sidebar-active/60 hover:text-sidebar-foreground"
                            : "text-muted-foreground hover:bg-muted hover:text-foreground",
                      ].join(" ")}
                    >
                      <Icon
                        className={`size-4 shrink-0 ${active ? "text-accent" : quiet}`}
                        aria-hidden="true"
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
        <p className={`mt-4 px-3 text-xs ${quiet}`}>
          {ui(
            "Some sections are not shown because this account does not hold the permissions they require.",
          )}
        </p>
      ) : null}
    </>
  );
}

/**
 * Where you are working: one control, at every width.
 *
 * This was two labelled selects on desktop and, below md, a chip that opened
 * the navigation drawer because that is where the selects had been moved to.
 * Two problems with that. The selects and their uppercase labels were about
 * 300px of permanent chrome for something most people set once a day, and they
 * sat in a header that also carried a wordmark, a tenant name, a tenant slug,
 * an area switch and three loose icon buttons. And changing where you are
 * working meant opening the *navigation*, which is a different question.
 *
 * So it is a button that reads the current scope and a popover that holds the
 * selects — the same information in about a third of the width, in one place
 * rather than two, and the drawer goes back to being only navigation.
 *
 * "All" is stated rather than left blank: an empty chip reads as a loading
 * state, and the difference between "every site" and "not loaded yet" is
 * exactly the sort of thing this product refuses to leave ambiguous.
 */
function ScopeControl({
  session,
  scope,
  onScopeChange,
  sites,
}: {
  session: ErpSession;
  scope: Scope;
  onScopeChange: (s: Scope) => void;
  sites: { id: string; code: string; name: string }[];
}) {
  const entity = session.entities.find((e) => e.id === scope.entityId);
  const site = session.sites.find((s) => s.id === scope.siteId);
  const label = [entity?.code ?? "All", site?.code ?? "All"].join(" · ");

  return (
    <Popover>
      <PopoverTrigger
        className={`${TOUCH} inline-flex max-w-[7.5rem] shrink-0 items-center gap-1.5 rounded-md border border-input px-2.5 text-sm text-muted-foreground hover:bg-muted hover:text-foreground md:max-w-[11rem] md:px-3`}
      >
        <Building2 className="size-4 shrink-0 max-md:hidden" aria-hidden="true" />
        <span className="truncate font-medium">{label}</span>
        <ChevronDown className="size-3.5 shrink-0 opacity-60" aria-hidden="true" />
      </PopoverTrigger>
      <PopoverContent align="end" className="w-72">
        <p className="text-sm font-medium">Where you are working</p>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Records, totals and the documents you can raise all follow this.
        </p>
        <div className="mt-3 flex flex-col gap-3">
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
        {/* The organisation's code lived in the header, under its name. It is a
            slug: useful when raising a support request and never otherwise, so
            it belongs where the organisation is already the subject rather
            than in permanent chrome. */}
        <p className="mt-3 border-t border-border pt-3 font-mono text-[11px] text-muted-foreground">
          {session.tenant?.code ?? "—"}
          {session.tenant?.status && session.tenant.status !== "active"
            ? ` · ${session.tenant.status}`
            : ""}
        </p>
      </PopoverContent>
    </Popover>
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
    <UnsavedChangesProvider>
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

            {/* The wordmark waits for lg. At md the mark alone says whose product
              this is, and the width is better spent on whose data it is. */}
            <Link to={AREA_HOME[area]} className={`${TOUCH} flex shrink-0 items-center gap-2`}>
              <BrandMark size={28} />
              <span className="hidden font-serif text-base font-semibold tracking-[-0.02em] lg:inline">
                <span style={{ color: brand.ink }}>{brand.prefix}</span>
                <span style={{ color: brand.total }}>{brand.suffix}</span>
              </span>
            </Link>

            <span className="min-w-0 flex-1 truncate text-sm font-medium md:flex-none">
              {session.tenant?.name ?? "No tenant"}
            </span>

            <AreaSwitch area={area} counts={counts} className="hidden md:block" />

            {/*
            Search, the whole-product menu and screen help, as one object.
            They were three loose buttons with the same weight as everything
            else in the row, which is most of why this header read as busy:
            nothing said which controls belonged together. They answer three
            versions of one question — take me to a screen I can name, show me
            what exists, tell me what this screen is for — so they are grouped
            and unlabelled. The words were only carried at lg anyway.
          */}
            <div className="ml-auto flex shrink-0 items-center rounded-md border border-input">
              <CommandPalette />
              <MainMenu />
              <ContextHelp />
            </div>

            <ScopeControl
              session={session}
              scope={scope}
              onScopeChange={onScopeChange}
              sites={sites}
            />

            <div className="hidden shrink-0 md:block">
              <UserMenu session={session} onSignOut={onSignOut} />
            </div>
          </div>
        </header>
        {session.tenant_id ? <ServiceBanner /> : null}

        <Sheet open={drawerOpen} onOpenChange={setDrawerOpen}>
          <SheetContent
            side="left"
            className="flex w-[85vw] max-w-sm flex-col gap-6 overflow-y-auto"
          >
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

            {/* The scope selects used to be down here too, which meant changing
              where you were working started by opening the navigation. They are
              in the header's own control now, at every width, so this drawer is
              navigation and nothing else. */}

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
            <Breadcrumbs />
            {children}
          </main>
        </div>
      </div>
    </UnsavedChangesProvider>
  );
}
