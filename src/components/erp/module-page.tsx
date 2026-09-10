import { Link } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";

import { useT } from "../../lib/i18n";
import { AREA_HOME, GROUP_LABELS, areaOf, type ModuleDef, type Panel } from "../../lib/modules";
import { ActionBar } from "./actions-bar";
import { AutoPanel } from "./auto";
import { InquiryBoard } from "./inquiry";
import { KpiRow, MiniBars } from "./kpi";
import { RefreshButton, TOUCH } from "./page";
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

type Tab = "dashboard" | "work" | "reports";

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

  const tabs: { id: Tab; label: string; badge?: number }[] = [
    { id: "dashboard", label: ui("Dashboard") },
    { id: "work", label: ui("Work"), badge: def.worklists.length },
    { id: "reports", label: ui("Reports"), badge: def.reports.length },
  ];

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <header className="min-w-0 rounded-xl border border-border bg-card">
        <div className="flex flex-wrap items-start justify-between gap-3 px-4 pt-4 sm:px-5">
          <div className="min-w-0 flex-1">
            <nav aria-label="Breadcrumb" className="text-xs text-muted-foreground">
              <Link
                to={AREA_HOME[areaOf(def.group)]}
                className="hover:text-foreground hover:underline"
              >
                {areaOf(def.group) === "settings" ? t("nav.settings", "Settings") : ui("Home")}
              </Link>
              <span className="px-1.5">/</span>
              <span>{ui(GROUP_LABELS[def.group])}</span>
              <span className="px-1.5">/</span>
              <span className="text-foreground">{title}</span>
            </nav>
            <h1 className="mt-1 truncate text-xl font-semibold">{title}</h1>
            <p className="mt-1 text-sm text-muted-foreground">{ui(def.blurb)}</p>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {actions}
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
          <KpiRow kpis={def.kpis} />
          {def.chart ? <MiniBars chart={def.chart} /> : null}
          {def.worklists.slice(0, 1).map(panelOf)}
          {def.worklists.length > 1 ? (
            <button
              type="button"
              onClick={() => setTab("work")}
              className={`${TOUCH} self-start rounded-md border border-input px-4 text-sm font-medium`}
            >
              See all {def.worklists.length} worklists
            </button>
          ) : null}
        </div>
      ) : null}

      {tab === "work" ? (
        <div className="flex min-w-0 flex-col gap-4">
          {def.actions && def.actions.length > 0 ? (
            <ActionBar
              actions={def.actions}
              title="What you can do here"
              note="The database authorises every one of these; you only see the ones you hold."
            />
          ) : null}
          {def.worklists.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              This module has no worklist of its own. Its reports are under Reports.
            </p>
          ) : (
            def.worklists.map(panelOf)
          )}
        </div>
      ) : null}

      {tab === "reports" ? (
        <div className="flex min-w-0 flex-col gap-4">
          {def.reports.map(panelOf)}
          <InquiryBoard inquiries={def.inquiries ?? []} />
        </div>
      ) : null}
    </div>
  );
}
