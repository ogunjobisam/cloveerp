import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";

/**
 * Report versions and the runs made against them.
 *
 * §19's rule is that a report is reproducible: the same version with the same
 * parameters over the same data gives the same rows, and every run records
 * which version and which parameters it used. A report with no version cannot
 * be run; a run with no version cannot be reproduced. Both are findings, and
 * the top panel is the same report the build fails on.
 */

export const Route = createFileRoute("/reporting/reproducibility")({
  head: () => ({ meta: [{ title: "Report versions and runs — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Reproducibility />
    </Gate>
  ),
});

type Finding = {
  finding: string;
  reference: string;
  detail: string;
};

/** Shaped by erp_report_versions(), newest version first within a report. */
type Version = {
  id: string;
  report_code: string;
  report_name: string;
  module_code: string | null;
  version: number;
  status: string;
  governed_view: string | null;
  source: string | null;
  columns: string[] | null;
  group_by: string[] | null;
  default_sort: string[] | null;
  output_formats: string[] | null;
  required_permission: string | null;
  time_budget_ms: number | null;
  row_cap: number | null;
  effective_from: string | null;
  effective_to: string | null;
  note: string | null;
  parameters: {
    code: string;
    name_key: string;
    data_type: string;
    is_required: boolean;
    default_value: string | null;
    filters_column: string | null;
  }[];
  runs: number;
};

/** Shaped by erp_report_runs(), newest first. */
type Run = {
  id: string;
  report_code: string;
  version: number;
  parameters: Record<string, unknown> | null;
  run_by: string | null;
  run_at: string;
  row_count: number | null;
  duration_ms: number | null;
  outcome: string;
  extract_reason: string | null;
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

/** From erp.report_run's outcome check: completed, deferred_to_extract, refused.
 *  Deferred is the budget doing its job — the rows were too many for a screen
 *  and went to an extract instead; refused is a permission or a cap. */
function outcomeTone(outcome: string): "ok" | "warn" | "bad" | "muted" {
  switch (outcome) {
    case "completed":
      return "ok";
    case "refused":
      return "bad";
    case "deferred_to_extract":
      return "warn";
    default:
      return "muted";
  }
}

function Reproducibility() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Report versions and runs">
        A report is a definition with versions, and each version names the governed view it reads,
        the columns it shows, the parameters it takes and the budget it may spend. A run records the
        version and the parameters, so that what somebody was shown can be shown again.
      </PageHeader>

      <DataPanel<Finding>
        title="What is wrong"
        description="Read from the same report the build fails on. A report with no version, a version reading a view that is gone, a run that names a version it could not have used — one row here is one failure there."
        fn="erp_report_reproducibility"
        empty="Nothing to report. Every report has a version, every version has its view, and every run can be reproduced."
      >
        {(rows) => (
          <Table columns={["Finding", "Reference", "Detail"]}>
            {rows.map((r, i) => (
              <tr
                key={`${r.finding}-${r.reference}-${i}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4">
                  <Pill tone="bad">{r.finding}</Pill>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.reference}</td>
                <td className="py-2 text-sm text-muted-foreground">{r.detail}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Version>
        title="Versions"
        description="Every version of every report, newest first. The source is the governed view the version reads; a version that names none cannot run. The budget is what a run may spend before it is capped."
        fn="erp_report_versions"
        empty="No report has a version. A report is installed with its definition by a content pack and given a version through a change set; until then it cannot be run."
      >
        {(rows) => (
          <Table columns={["Report", "Version", "Source", "Shape", "Parameters", "Budget", "Runs"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.report_name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.report_code}
                    {r.module_code ? ` · ${r.module_code}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-4">
                  <div className="font-mono text-xs">v{r.version}</div>
                  <div className="mt-0.5">
                    <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                  </div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.source ? (
                    <>
                      {r.governed_view}
                      <div className="mt-0.5 text-muted-foreground">{r.source}</div>
                    </>
                  ) : (
                    <Pill tone="bad">No view</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.columns?.length ?? 0} columns
                  {r.group_by && r.group_by.length > 0 ? ` · by ${r.group_by.join(", ")}` : ""}
                  {r.output_formats && r.output_formats.length > 0 ? (
                    <div className="mt-0.5 font-mono">{r.output_formats.join(", ")}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-xs">
                  {r.parameters.length === 0 ? (
                    <span className="text-muted-foreground">None</span>
                  ) : (
                    <ul className="space-y-0.5">
                      {r.parameters.map((p) => (
                        <li key={p.code} className="font-mono">
                          {p.code}
                          <span className="text-muted-foreground">
                            {" "}
                            {p.data_type}
                            {p.is_required ? " · required" : ""}
                            {p.default_value != null ? ` · default ${p.default_value}` : ""}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground tabular-nums">
                  {r.time_budget_ms != null ? `${r.time_budget_ms.toLocaleString()} ms` : "—"}
                  <div className="mt-0.5">
                    {r.row_cap != null ? `${r.row_cap.toLocaleString()} rows` : "no row cap"}
                  </div>
                </td>
                <td className="py-2 text-sm tabular-nums">{r.runs.toLocaleString()}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Run>
        title="Runs"
        description="The last five hundred runs, newest first, each with the version and parameters it used. An extract — rows leaving the product as a file — carries the reason that was given for it."
        fn="erp_report_runs"
        empty="No report has been run."
      >
        {(rows) => (
          <Table columns={["Run", "Report", "Parameters", "Result", "Outcome"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.run_at)}
                  <div className="mt-0.5">{r.run_by ?? "—"}</div>
                </td>
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.report_code}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">v{r.version}</div>
                </td>
                <td className="py-2 pr-4 font-mono text-xs text-muted-foreground">
                  {r.parameters && Object.keys(r.parameters).length > 0
                    ? Object.entries(r.parameters)
                        .map(([k, v]) => `${k}=${String(v)}`)
                        .join(" ")
                    : "—"}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground tabular-nums">
                  {r.row_count != null ? `${r.row_count.toLocaleString()} rows` : "—"}
                  {r.duration_ms != null ? (
                    <div className="mt-0.5">{r.duration_ms.toLocaleString()} ms</div>
                  ) : null}
                </td>
                <td className="py-2">
                  <Pill tone={outcomeTone(r.outcome)}>{r.outcome}</Pill>
                  {r.extract_reason ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.extract_reason}</div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
