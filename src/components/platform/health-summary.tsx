import { useQuery } from "@tanstack/react-query";
import { AlertTriangle, CheckCircle2 } from "lucide-react";
import { Fragment, type ReactNode } from "react";

import { Pill } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { Card, ConsoleLink, Fail, OrganisationName } from "./kit";
import type { CheckResult, TenantConfiguration, MyTenancy } from "../../lib/platform";

/**
 * The deployment's health at a glance: the assurance detail that used to sit
 * on the console's Overview, now the first tab under Platform.
 *
 * Today says whether anything needs doing; this says how things stand. Every
 * number comes from a read another tab already uses, and every line links to
 * the exact place that deals with it — an organisation's own page where the
 * thing to fix is inside one organisation.
 */

function Signal({
  tone,
  title,
  children,
}: {
  tone: "ok" | "warn" | "bad";
  title: string;
  children: ReactNode;
}) {
  return (
    <li className="flex items-start gap-3 border-b border-border/60 py-3 last:border-0">
      {tone === "ok" ? (
        <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-emerald-600 dark:text-emerald-400" />
      ) : (
        <AlertTriangle
          className={`mt-0.5 size-4 shrink-0 ${tone === "bad" ? "text-destructive" : "text-amber-600"}`}
        />
      )}
      <div className="min-w-0">
        <div className="text-sm font-medium">{title}</div>
        <div className="mt-0.5 text-xs text-muted-foreground">{children}</div>
      </div>
    </li>
  );
}

/** Organisations named in a sentence, each a link to its own page. */
function Organisations({
  orgs,
  count,
}: {
  orgs: { code: string; name: string }[];
  count?: (code: string) => number;
}) {
  return (
    <>
      {orgs.map((o, i) => (
        <Fragment key={o.code}>
          {i > 0 ? ", " : null}
          <ConsoleLink
            section="customers"
            view="organisations"
            org={o.code}
            className="underline underline-offset-2"
          >
            {o.name}
          </ConsoleLink>
          {count ? ` (${count(o.code)})` : null}
        </Fragment>
      ))}
    </>
  );
}

function plural(n: number, one: string, many: string) {
  return `${n} ${n === 1 ? one : many}`;
}

export function HealthSummary() {
  const assurance = useQuery({
    queryKey: ["erp_platform_assurance"],
    queryFn: () => callErp<CheckResult[]>("erp_platform_assurance"),
  });

  const config = useQuery({
    queryKey: ["erp_platform_tenant_configuration"],
    queryFn: () => callErp<TenantConfiguration[]>("erp_platform_tenant_configuration"),
  });

  const mine = useQuery({
    queryKey: ["erp_platform_my_tenancies"],
    queryFn: () => callErp<MyTenancy[]>("erp_platform_my_tenancies"),
  });

  const checks = assurance.data ?? [];
  const failing = checks.filter((c) => c.ok === false);
  const orgs = config.data ?? [];
  const unconfigured = orgs.filter(
    (o) => o.status === "active" && o.modules_installed.length === 0,
  );
  const awaiting = orgs.filter((o) => o.change_sets_awaiting > 0);
  const determination = orgs.filter((o) => o.determination_findings > 0);
  const inside = (mine.data ?? []).filter((t) => t.is_active);

  const anyError = assurance.error ?? config.error ?? mine.error;
  const loading = assurance.isPending || config.isPending || mine.isPending;

  return (
    <div className="flex flex-col gap-5">
      <Card
        title="How the deployment stands"
        description="Read across every organisation. Each line links to the place that deals with it."
      >
        {anyError ? (
          <Fail error={anyError} />
        ) : loading ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (
          <ul className="flex flex-col">
            {failing.length > 0 ? (
              <Signal tone="bad" title={`${plural(failing.length, "check", "checks")} failing`}>
                {failing.map((c) => c.title ?? c.code).join(", ")}.{" "}
                <ConsoleLink
                  section="platform"
                  view="diagnostics"
                  className="underline underline-offset-2"
                >
                  See what they found in Diagnostics
                </ConsoleLink>
              </Signal>
            ) : (
              <Signal tone="ok" title="Every check holds">
                {plural(checks.filter((c) => c.ok === true).length, "check passes", "checks pass")},
                and {checks.filter((c) => c.ok === null).length} more run inside each organisation.
              </Signal>
            )}

            {unconfigured.length > 0 ? (
              <Signal
                tone="warn"
                title={`${plural(unconfigured.length, "organisation", "organisations")} with nothing installed`}
              >
                <Organisations orgs={unconfigured} /> — no module has been installed, so there is
                nothing for anybody to use yet.
              </Signal>
            ) : null}

            {awaiting.length > 0 ? (
              <Signal
                tone="warn"
                title={`${plural(awaiting.length, "organisation", "organisations")} with changes waiting`}
              >
                <Organisations
                  orgs={awaiting}
                  count={(code) => awaiting.find((o) => o.code === code)?.change_sets_awaiting ?? 0}
                />{" "}
                — configuration approved or ready, and not yet applied. It is applied from
                Configuration inside the organisation.
              </Signal>
            ) : null}

            {determination.length > 0 ? (
              <Signal tone="bad" title="Postings that would be refused">
                <Organisations
                  orgs={determination}
                  count={(code) =>
                    determination.find((o) => o.code === code)?.determination_findings ?? 0
                  }
                />{" "}
                — a posting with no account rule is refused rather than parked in a suspense
                account, so each of these will stop somebody working until its rule is added.
              </Signal>
            ) : null}

            {inside.length > 0 ? (
              <Signal
                tone="warn"
                title={`You are inside ${plural(inside.length, "organisation", "organisations")}`}
              >
                <Organisations orgs={inside} /> — you hold a role there until you leave, which you
                can do from the organisation&rsquo;s page.
              </Signal>
            ) : null}

            {failing.length === 0 &&
            unconfigured.length === 0 &&
            awaiting.length === 0 &&
            determination.length === 0 &&
            inside.length === 0 ? (
              <Signal tone="ok" title="Nothing is waiting on you">
                Every organisation has something installed, no check is failing, and you are not
                inside anybody&rsquo;s organisation.
              </Signal>
            ) : null}
          </ul>
        )}
      </Card>

      <Card title="Organisations at a glance">
        {config.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : config.error ? (
          <Fail error={config.error} />
        ) : orgs.length === 0 ? (
          <p className="text-sm text-muted-foreground">No organisations yet.</p>
        ) : (
          <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {orgs.map((o) => (
              <li key={o.tenant_id} className="rounded-lg border border-border p-3">
                <div className="flex items-start justify-between gap-2">
                  <OrganisationName name={o.name} code={o.code}>
                    <ConsoleLink
                      section="customers"
                      view="organisations"
                      org={o.code}
                      className="underline-offset-2 hover:underline"
                    >
                      {o.name}
                    </ConsoleLink>
                  </OrganisationName>
                  <Pill tone={o.is_live ? "ok" : "warn"}>{o.is_live ? "Live" : "In setup"}</Pill>
                </div>
                <div className="mt-2 text-xs text-muted-foreground">
                  {plural(o.modules_installed.length, "module", "modules")} ·{" "}
                  {plural(o.accounts, "account", "accounts")} ·{" "}
                  {plural(o.document_types, "document type", "document types")} ·{" "}
                  {plural(o.jobs, "job", "jobs")}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
