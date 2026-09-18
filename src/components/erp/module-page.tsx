import { useState, type ReactNode } from "react";

import { unstagedActions } from "../../lib/flow-actions";
import { useT } from "../../lib/i18n";
import { type ModuleDef, type Panel } from "../../lib/modules";
import { ActionBar, HeaderActions } from "./actions-bar";
import { AutoPanel } from "./auto";
import { InquiryBoard } from "./inquiry";
import { KpiRow, MiniBars } from "./kpi";
import { HowItWorksLink, RefreshButton, TOUCH, useHowItWorks } from "./page";
import { useScope } from "./session-context";
import { ProcessFlow } from "./process-flow";

/**
 * The object page every module shares.
 *
 * ERP suites converged on the same shape for a reason: a header that says
 * where you are and what the object is, a tab strip that separates the summary
 * from the work from the reading, and a content area with one column of
 * consistent panels. Fiori calls it an object page; Dynamics calls it a role
 * centre over list pages. Before this, each module here was a stack of panels
 * in whatever order it was written, and moving between two of them felt like
 * moving between two products.
 *
 * The tabs are three questions rather than three feature areas:
 *   Dashboard — how is this module doing?
 *   Work      — what needs me?
 *   Reports   — what do I need to read?
 */

type Tab = "dashboard" | "reports";

/**
 * A read, with the site the header names filled in.
 *
 * The header said MAIN · LND-HO while the stock tables listed LEE-WH, because
 * nothing on those screens had ever read the choice — three doors had taken a
 * site since 20260910182034 and no screen passed one. A read that declares
 * which argument the site fills now gets it here, and a read that declares none
 * is about the whole organisation, which the header's popover says.
 *
 * An empty choice sends null, which every one of those doors reads as "every
 * site". So "All" still means all.
 */
function withSite<T extends { args?: Record<string, unknown>; siteArg?: string }>(
  read: T,
  siteId: string,
): T {
  if (!read.siteArg) return read;
  return { ...read, args: { ...(read.args ?? {}), [read.siteArg]: siteId || null } };
}

function panelOf(p: Panel) {
  return (
    <AutoPanel
      key={`${p.fn}-${p.title}`}
      title={p.title}
      {...(p.description ? { description: p.description } : {})}
      fn={p.fn}
      {...(p.args ? { args: p.args } : {})}
      empty={p.empty}
      {...(p.emptyAction ? { emptyAction: p.emptyAction } : {})}
      rowKey={p.rowKey}
      columns={p.columns}
    />
  );
}

export function ModulePage({ def, actions }: { def: ModuleDef; actions?: ReactNode }) {
  const { t, ui } = useT();
  const [tab, setTab] = useState<Tab>("dashboard");
  const title = t(def.titleKey, def.title);
  const unstaged = unstagedActions(def.flow, def.actions ?? []);
  const openHelp = useHowItWorks(def.howItWorks ? ui(def.howItWorks) : undefined);

  // Whether anything on this screen is about one place. Asked before the scope
  // is registered, so a module whose reads are organisation-wide does not claim
  // to follow a choice it ignores.
  const readsSite =
    def.kpis.some((k) => k.siteArg) ||
    def.worklists.some((p) => p.siteArg) ||
    def.reports.some((r) => r.siteArg) ||
    Boolean(def.chart?.siteArg);
  const { siteId } = useScope(readsSite);

  const tabs: { id: Tab; label: string; badge?: number }[] = [
    { id: "dashboard", label: ui("Dashboard") },
    { id: "reports", label: ui("Reports"), badge: def.reports.length },
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <header className="min-w-0 rounded-xl border border-border bg-card">
        <div className="flex flex-wrap items-start justify-between gap-3 px-4 pt-4 sm:px-5">
          <div className="min-w-0 flex-1">
            {/* The trail is the shell's, above this card, and it carries the
                group this used to add (breadcrumbs.tsx). Two trails — Home >
                Stock over Home / Move / Stock — was one too many. */}
            <h1 className="truncate text-xl font-semibold">{title}</h1>
            <p className="mt-1 text-sm text-muted-foreground">{ui(def.blurb)}</p>
            <HowItWorksLink open={openHelp} />
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {actions}
            {/* "What you can do here" was fifteen equal buttons in the middle of
                the page — the least-used controls on it and the loudest. Every
                one is still here, one press away. */}
            {unstaged.length > 0 ? (
              <HeaderActions>
                <ActionBar actions={unstaged} title="What you can do here" />
              </HeaderActions>
            ) : null}
            <RefreshButton />
          </div>
        </div>

        {/* The tab strip. Overflows by scrolling rather than wrapping, so the
            header keeps a predictable height on a phone. */}
        <div className="mt-3 overflow-x-auto border-t border-border px-2 sm:px-3">
          <div role="tablist" aria-label={`${title} views`} className="flex gap-1">
            {tabs.map((x) => {
              const active = tab === x.id;
              return (
                <button
                  key={x.id}
                  role="tab"
                  type="button"
                  aria-selected={active}
                  onClick={() => setTab(x.id)}
                  className={[
                    TOUCH,
                    "relative shrink-0 px-3 text-sm font-medium transition-colors",
                    active
                      ? "text-foreground after:absolute after:inset-x-2 after:bottom-0 after:h-0.5 after:rounded-full after:bg-primary"
                      : "text-muted-foreground hover:text-foreground",
                  ].join(" ")}
                >
                  {x.label}
                  {x.badge ? (
                    <span className="ml-1.5 rounded-full bg-muted px-1.5 py-0.5 text-[11px] tabular-nums text-muted-foreground">
                      {x.badge}
                    </span>
                  ) : null}
                </button>
              );
            })}
          </div>
        </div>
      </header>

      {tab === "dashboard" ? (
        <div className="flex min-w-0 flex-col gap-4">
          {/* The figures first, then the work. The strip counts what is
              waiting, so it is empty most of the time by design: a manager
              opening Stock saw a row of noughts while the real position — the
              lines on hand, their value — sat below the fold. */}
          <KpiRow kpis={def.kpis.map((k) => withSite(k, siteId))} />
          {/* Inside the tab, not above both. On the Reports tab the whole
              pipeline — search, list, pagination, buttons — stood between the
              tab strip and the first report. */}
          {def.flow ? <ProcessFlow flow={def.flow} actions={def.actions ?? []} /> : null}
          {/* The verbs no step names are in the header's Actions panel. They
              used to be switched off whenever there was a strip, which left
              every one of them declared, permitted and unreachable; they are
              not switched off now, only moved out of the way. */}
          {def.worklists.map((p) => panelOf(withSite(p, siteId)))}
        </div>
      ) : null}

      {tab === "reports" ? (
        <div className="flex min-w-0 flex-col gap-5">
          {def.chart ? <MiniBars chart={withSite(def.chart, siteId)} /> : null}
          {def.reports.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui("This module has no reports of its own yet.")}
            </p>
          ) : (
            <div className="grid min-w-0 grid-cols-1 gap-4 xl:grid-cols-2">
              {def.reports.map((r) => (
                <div key={`${r.fn}-${r.title}`} className="min-w-0">
                  {panelOf(withSite(r, siteId))}
                </div>
              ))}
            </div>
          )}
          <InquiryBoard inquiries={def.inquiries ?? []} />
        </div>
      ) : null}
    </div>
  );
}
