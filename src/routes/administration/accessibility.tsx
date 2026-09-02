import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { friendlyError } from "@/lib/errors";

import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp } from "../../lib/erp";

export const Route = createFileRoute("/administration/accessibility")({
  head: () => ({
    meta: [
      { title: "Accessibility — Clove ERP" },
      {
        name: "description",
        content:
          "Accessibility statement, conformance checks and assistive-technology settings for Clove ERP.",
      },
      { property: "og:title", content: "Accessibility — Clove ERP" },
      {
        property: "og:description",
        content:
          "Accessibility statement, conformance checks and assistive-technology settings for Clove ERP.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <AccessibilityStatement />
    </Gate>
  ),
});

/** Shaped by erp_accessibility_statement(): the statement generated from
 *  erp_ref.accessibility_criterion, so it cannot claim what the register does
 *  not. Conformance is computed: partial while any A or AA criterion is short
 *  of met. */
type Statement = {
  product: string;
  standard: string;
  level_claimed: string;
  conformance: "conforms" | "partially conforms";
  reviewed_on: string;
  counts: {
    met: number;
    partially_met: number;
    not_met: number;
    not_applicable: number;
    total: number;
  };
  checked_by: { automated: string; manual: string; register: string };
  exceptions: {
    criterion: string;
    name: string;
    level: string;
    status: string;
    exception: string;
  }[];
  criteria: {
    criterion: string;
    name: string;
    level: string;
    principle: string;
    status: "met" | "partially_met" | "not_met" | "not_applicable";
    how_met: string | null;
    known_exception: string | null;
    checked_by: string;
    reviewed_on: string;
  }[];
  feedback: string;
};

const PRINCIPLES = ["perceivable", "operable", "understandable", "robust"] as const;

function statusTone(
  status: Statement["criteria"][number]["status"],
): "ok" | "warn" | "bad" | "muted" {
  switch (status) {
    case "met":
      return "ok";
    case "partially_met":
      return "warn";
    case "not_met":
      return "bad";
    default:
      return "muted";
  }
}

function statusWord(status: string): string {
  return status.replace(/_/g, " ");
}

function AccessibilityStatement() {
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_accessibility_statement", {}],
    queryFn: () => callErp<Statement>("erp_accessibility_statement", {}),
  });

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Accessibility">
        The statement is generated from a register of every WCAG 2.2 Level A and AA success
        criterion, with what in the product meets each one, what does not, and which kind of
        checking stands behind the answer. The register is checked on every build, so the statement
        stays true on the day it is read rather than the day it was written.
      </PageHeader>

      {isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      ) : error ? (
        <div role="alert">
          <p className="text-sm font-medium text-destructive">This did not load.</p>
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
        </div>
      ) : data ? (
        <>
          <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
            <h2 className="text-sm font-semibold">Statement</h2>
            <p className="mt-2 text-sm">
              {data.product} {data.conformance} with {data.standard} at Level {data.level_claimed}.
              Of {data.counts.total} success criteria, {data.counts.met} are met,{" "}
              {data.counts.partially_met} partially met, {data.counts.not_met} not met and{" "}
              {data.counts.not_applicable} do not apply. Last reviewed {data.reviewed_on}.
            </p>
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-3">
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  Checked on every build
                </dt>
                <dd className="mt-1 text-muted-foreground">{data.checked_by.automated}</dd>
              </div>
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  Checked by hand
                </dt>
                <dd className="mt-1 text-muted-foreground">{data.checked_by.manual}</dd>
              </div>
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  The register itself
                </dt>
                <dd className="mt-1 text-muted-foreground">{data.checked_by.register}</dd>
              </div>
            </dl>
            <h3 className="mt-5 text-sm font-semibold">Reporting a barrier</h3>
            <p className="mt-1 text-sm text-muted-foreground">{data.feedback}</p>
          </section>

          <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
            <h2 className="text-sm font-semibold">Known exceptions</h2>
            {data.exceptions.length === 0 ? (
              <p className="mt-2 text-sm text-muted-foreground">
                None. Every applicable criterion is met.
              </p>
            ) : (
              <ul className="mt-2 flex flex-col gap-2">
                {data.exceptions.map((e) => (
                  <li key={e.criterion} className="text-sm">
                    <span className="font-mono text-xs">{e.criterion}</span> {e.name} (Level{" "}
                    {e.level}){" "}
                    <Pill tone={statusTone(e.status as never)}>{statusWord(e.status)}</Pill>
                    <div className="mt-0.5 text-xs text-muted-foreground">{e.exception}</div>
                  </li>
                ))}
              </ul>
            )}
          </section>

          {PRINCIPLES.map((principle) => {
            const rows = data.criteria.filter((c) => c.principle === principle);
            return (
              <section
                key={principle}
                className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5"
              >
                <h2 className="text-sm font-semibold capitalize">{principle}</h2>
                <Prose className="mt-0.5 text-xs text-muted-foreground">
                  {rows.length} criteria. Status, how it is met or why it does not apply, and what
                  checks it.
                </Prose>
                <div className="mt-3">
                  <Table
                    columns={[
                      "Criterion",
                      "Level",
                      "Status",
                      "How it is met, or the exception",
                      "Checked by",
                    ]}
                  >
                    {rows.map((c) => (
                      <tr
                        key={c.criterion}
                        className="border-b border-border/50 align-top last:border-0"
                      >
                        <td className="py-2 pr-4">
                          <div className="text-sm">{c.name}</div>
                          <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                            {c.criterion}
                          </div>
                        </td>
                        <td className="py-2 pr-4 text-sm">{c.level}</td>
                        <td className="py-2 pr-4">
                          <Pill tone={statusTone(c.status)}>{statusWord(c.status)}</Pill>
                        </td>
                        <td className="py-2 pr-4 text-xs text-muted-foreground">
                          {c.how_met ? <p>{c.how_met}</p> : null}
                          {c.known_exception ? (
                            <p className={c.how_met ? "mt-1" : ""}>{c.known_exception}</p>
                          ) : null}
                        </td>
                        <td className="py-2 text-xs text-muted-foreground">
                          {c.checked_by}
                          <div className="mt-0.5">{c.reviewed_on}</div>
                        </td>
                      </tr>
                    ))}
                  </Table>
                </div>
              </section>
            );
          })}
        </>
      ) : null}
    </div>
  );
}
