import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { SeedDemoAction } from "../../components/erp/seed";

/** The things a kill switch can point at, from `erp.kill_target_kind`. */
const KILL_TARGETS = [
  { value: "rule_set", label: "Rule set" },
  { value: "rule", label: "Rule" },
  { value: "state_machine", label: "State machine" },
  { value: "approval_chain", label: "Approval chain" },
  { value: "job", label: "Job" },
  { value: "command_class", label: "Command class" },
  { value: "integration", label: "Integration" },
  { value: "event_consumer", label: "Event consumer" },
];

export const Route = createFileRoute("/operations/jobs")({
  head: () => ({
    meta: [
      { title: "Scheduled jobs — Clove ERP" },
      { name: "description", content: "Scheduled jobs, run history and failure diagnostics." },
      { property: "og:title", content: "Scheduled jobs — Clove ERP" },
      {
        property: "og:description",
        content: "Scheduled jobs, run history and failure diagnostics.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Jobs />
    </Gate>
  ),
});

type Silent = {
  job_code: string;
  schedule: string;
  last_success_at: string | null;
  silent_for: string;
  tolerance: string;
  finding: string;
};

type Health = {
  job_code: string;
  is_enabled: boolean;
  is_failing: boolean;
  is_killed: boolean;
  in_outage: boolean;
  next_run_at: string | null;
  running: number;
  last_outcome: string | null;
  runs_24h: number;
  failures_24h: number;
  skips_24h: number;
};

function Jobs() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Scheduled jobs">
        A job that fails is loud. A job that stops being scheduled is silent, and silence looks
        exactly like success — so it is reported first.
      </PageHeader>

      <ActionBar
        note="Running a job by hand, and the kill switches that stop one from running at all."
        actions={[
          {
            // The screen had panels, a trigger and two kill switches, and no way
            // to bring a job into existence — so it had never shown a row and
            // "Trigger a job" could only ever fail.
            label: "Define a job",
            permission: "administration.jobs",
            fn: "erp_upsert_job",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              pickFrom("erp_job_handlers", "code", ["code"], "p_handler_code", "Handler"),
              {
                kind: "choice",
                name: "p_schedule_kind",
                label: "Runs",
                required: true,
                choices: [
                  { value: "interval", label: "Every N seconds" },
                  { value: "daily", label: "Daily at a time" },
                  { value: "weekly", label: "Weekly" },
                  { value: "monthly", label: "Monthly" },
                  { value: "manual", label: "Only when triggered" },
                ],
              },
              {
                kind: "number",
                name: "p_interval_seconds",
                label: "Interval (seconds)",
                hint: "For an interval schedule. At least 30.",
              },
              {
                kind: "text",
                name: "p_at_time",
                label: "At (HH:MM)",
                hint: "Daily, weekly or monthly.",
              },
              {
                kind: "text",
                name: "p_days_of_week",
                label: "Days of week",
                hint: "Weekly only. ISO numbers, 1 = Monday, comma separated.",
              },
              { kind: "number", name: "p_day_of_month", label: "Day of month" },
              { kind: "text", name: "p_timezone", label: "Timezone", hint: "Defaults to UTC." },
            ],
            invalidates: ["erp_silent_jobs", "erp_job_health", "erp_job_handlers"],
          },
          {
            label: "Trigger a job",
            permission: "administration.jobs",
            fn: "erp_trigger_job",
            fields: [
              { kind: "text", name: "p_job_code", label: "Job code", required: true },
              { kind: "text", name: "p_reason", label: "Reason" },
            ],
            invalidates: ["erp_silent_jobs", "erp_job_health"],
          },
          {
            label: "Set a kill switch",
            permission: "administration.jobs",
            fn: "erp_set_kill_switch",
            fields: [
              {
                kind: "choice",
                name: "p_kind",
                label: "Target",
                required: true,
                choices: KILL_TARGETS,
              },
              { kind: "text", name: "p_key", label: "Key", required: true },
              { kind: "text", name: "p_reason", label: "Reason", required: true },
            ],
            invalidates: ["erp_job_health", "erp_silent_jobs"],
          },
          {
            label: "Clear a kill switch",
            permission: "administration.jobs",
            fn: "erp_clear_kill_switch",
            fields: [
              {
                kind: "choice",
                name: "p_kind",
                label: "Target",
                required: true,
                choices: KILL_TARGETS,
              },
              { kind: "text", name: "p_key", label: "Key", required: true },
            ],
            invalidates: ["erp_job_health", "erp_silent_jobs"],
          },
        ]}
      />

      <DataPanel<Silent>
        title="Jobs that have stopped running"
        description="Overdue against their own schedule. Suppressed during a planned outage."
        fn="erp_silent_jobs"
        empty="Nothing is overdue. Every enabled job has run within its own tolerance."
      >
        {(rows) => (
          <Table columns={["Job", "Schedule", "Silent for", "Tolerance", "Finding"]}>
            {rows.map((r) => (
              <tr key={r.job_code} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.job_code}</td>
                <td className="py-2 pr-4 text-muted-foreground">{r.schedule}</td>
                <td className="py-2 pr-4">
                  <Pill tone="bad">{r.silent_for}</Pill>
                </td>
                <td className="py-2 pr-4 text-muted-foreground">{r.tolerance}</td>
                <td className="py-2 pr-4 text-muted-foreground">{r.finding}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Health>
        title="All jobs"
        description="State, next run, and the last 24 hours."
        fn="erp_job_health"
        empty="No jobs are configured for this tenant yet."
        emptyAction={<SeedDemoAction />}
      >
        {(rows) => (
          <Table columns={["Job", "State", "Next run", "Running", "24h runs", "Failed", "Skipped"]}>
            {rows.map((r) => (
              <tr key={r.job_code} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.job_code}</td>
                <td className="py-2 pr-4">
                  {!r.is_enabled ? (
                    <Pill tone="muted">Disabled</Pill>
                  ) : r.is_killed ? (
                    <Pill tone="bad">Kill switch</Pill>
                  ) : r.in_outage ? (
                    <Pill tone="muted">Outage window</Pill>
                  ) : r.is_failing ? (
                    <Pill tone="bad">Failing</Pill>
                  ) : (
                    <Pill tone="ok">Scheduled</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.next_run_at ? new Date(r.next_run_at).toLocaleString() : "—"}
                </td>
                <td className="py-2 pr-4">{r.running}</td>
                <td className="py-2 pr-4">{r.runs_24h}</td>
                <td className="py-2 pr-4">
                  {r.failures_24h > 0 ? <Pill tone="warn">{r.failures_24h}</Pill> : "0"}
                </td>
                <td className="py-2 pr-4 text-muted-foreground">{r.skips_24h}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
