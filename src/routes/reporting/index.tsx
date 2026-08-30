import { Link, createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { ModulePage } from "../../components/erp/module-page";
import { TOUCH } from "../../components/erp/page";
import { useErpSession } from "../../components/erp/session-context";
import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { MODULES, REPORTING } from "../../lib/modules";

const TITLE = "Reporting — ERPWare";
const DESC =
  "The reporting hub: every module report in one index, plus data quality, duplicates and specification coverage.";

export const Route = createFileRoute("/reporting/")({
  head: () => ({
    meta: [
      { title: TITLE },
      { name: "description", content: DESC },
      { property: "og:title", content: TITLE },
      { property: "og:description", content: DESC },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Reporting />
    </Gate>
  ),
});

/**
 * The hub half of "both".
 *
 * Reports live on their module because that is where they have context. This
 * index exists for the other case: knowing a report exists without knowing
 * which module owns it. It is generated from the same registry the module
 * pages render, so a report cannot appear in one and not the other.
 */
function ReportCatalogue() {
  const { session } = useErpSession();
  const { t } = useT();

  const visible = MODULES.filter((m) => !m.permission || hasPermission(session, m.permission));

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">All reports</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Every report this account can reach, by module. Each opens on its module&rsquo;s Reports
          tab.
        </p>
      </header>

      <div className="flex flex-col gap-5 px-4 py-4 sm:px-5">
        {visible.map((m) => (
          <div key={m.key} className="min-w-0">
            <div className="flex items-baseline justify-between gap-3">
              <h3 className="text-sm font-medium">{t(m.titleKey, m.title)}</h3>
              <Link
                to={m.path}
                className={`${TOUCH} inline-flex items-center text-xs font-medium text-muted-foreground underline underline-offset-2 hover:text-foreground`}
              >
                Open module
              </Link>
            </div>
            <ul className="mt-1 flex flex-wrap gap-1.5">
              {m.reports.map((r) => (
                <li key={`${m.key}-${r.title}`}>
                  <Link
                    to={m.path}
                    className="inline-block rounded-full border border-border px-2.5 py-1 text-xs text-muted-foreground transition-colors hover:border-primary/40 hover:text-foreground"
                  >
                    {r.title}
                  </Link>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  );
}

function Reporting() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <ModulePage def={REPORTING} />
      <ReportCatalogue />
    </div>
  );
}
