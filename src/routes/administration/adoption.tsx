import { createFileRoute, Link } from "@tanstack/react-router";

import { GoTo } from "../../components/erp/action";
import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { RpcButton } from "../../components/erp/rpc-button";
import { useErpSession } from "../../components/erp/session-context";

export const Route = createFileRoute("/administration/adoption")({
  head: () => ({
    meta: [
      { title: "Guidance and adoption — Clove ERP" },
      {
        name: "description",
        content:
          "Guidance, training scenarios and adoption tracking for teams rolling out Clove ERP.",
      },
      { property: "og:title", content: "Guidance and adoption — Clove ERP" },
      {
        property: "og:description",
        content:
          "Guidance, training scenarios and adoption tracking for teams rolling out Clove ERP.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Adoption />
    </Gate>
  ),
});

/** Shaped by erp_adoption_signals(): what is ageing, counted, never named. */
type Signal = { signal: string; count: number; oldest_days: number | null; guidance: string };

/** Shaped by erp_training_scenarios(): the product's five and the organisation's own. */
type Scenario = {
  code: string;
  source: "product" | "organisation";
  seq: number;
  module_code: string | null;
  title: string;
  starting_state: string;
  task: string;
  completion_code: string;
  completion: string;
  permission_code: string;
  may_start: boolean;
};

/** Shaped by erp_training_runs(): every run in the organisation, newest first. */
type Run = {
  run_id: string;
  scenario_code: string;
  scenario_source: string;
  mine: boolean;
  started_at: string;
  checked_at: string | null;
  completed_at: string | null;
};

/** Shaped by erp_help_topics(): the product's guidance, one row per screen. */
type Topic = {
  screen_path: string;
  nav_key: string;
  title: string;
  module_code: string;
  summary: string;
  steps: string[];
  next_action: string | null;
  actions: string[];
};

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function Adoption() {
  const { session } = useErpSession();
  const isDemo = session.tenant?.code.startsWith("demo-") ?? false;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Guidance and adoption">
        Refusals teach, help sits beside every screen, and first steps are offered per role from
        Home. This screen holds the rest of Part 22: the signals that say where adoption is
        stalling, training scenarios practised where nothing is real, and the product&apos;s
        guidance in one place so an administrator can see what a new person will be told.
      </PageHeader>

      <DataPanel<Signal>
        title="Adoption signals"
        description="Counts of what is ageing, and what to do about it. The report never names a person: adoption is a property of the organisation, not a mark against anyone."
        fn="erp_adoption_signals"
        empty="No signals. Nothing in this organisation is ageing in a way that suggests adoption has stalled."
      >
        {(rows) => (
          <Table columns={["Signal", "Count", "Oldest", "What to do"]}>
            {rows.map((r) => (
              <tr key={r.signal} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">{r.signal}</td>
                <td className="py-2 pr-4">
                  <Pill tone={r.count === 0 ? "ok" : r.count > 4 ? "bad" : "warn"}>{r.count}</Pill>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.oldest_days === null ? "—" : `${r.oldest_days} day(s)`}
                </td>
                <td className="py-2 text-xs text-muted-foreground">{r.guidance}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
        <h2 className="text-sm font-semibold">Training scenarios</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          A scenario is a starting state, a task, and a completion check the database evaluates
          against what actually happened. It is started in a demo organisation; a live one refuses
          it, because practice belongs where nothing is real.
        </Prose>
        {!isDemo ? (
          <p className="mt-3 rounded-lg border border-warn/40 bg-warn/5 px-3 py-2 text-xs">
            This organisation is not a demo. Starting a scenario here is refused once it is live;{" "}
            <Link to="/" className="underline">
              seed a demo organisation from Home
            </Link>{" "}
            and practise there.
          </p>
        ) : null}
      </section>

      <DataPanel<Scenario>
        title="Scenarios"
        description="The product's, in the order they are best taken, then this organisation's own. Start is offered only where the caller holds the scenario's permission."
        fn="erp_training_scenarios"
        empty="No scenarios. The product's own are installed with the base content pack, and an organisation can add its own on top."
        emptyAction={<GoTo to="/administration/packs">Open Packs</GoTo>}
      >
        {(rows) => (
          <Table columns={["Scenario", "Starting state", "Task", "Complete when", "Actions"]}>
            {rows.map((s) => (
              <tr
                key={`${s.source}-${s.code}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4">
                  <div className="text-sm">{s.title}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {s.code} · {s.source}
                    {s.module_code ? ` · ${s.module_code}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{s.starting_state}</td>
                <td className="py-2 pr-4 text-sm">{s.task}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {s.completion}
                  <div className="mt-0.5 font-mono">{s.completion_code}</div>
                </td>
                <td className="py-2">
                  {s.may_start ? (
                    <RpcButton
                      label="Start"
                      fn="erp_start_training_scenario"
                      args={{ p_code: s.code }}
                      permission={s.permission_code}
                      invalidates={["erp_training_runs", "erp_adoption_signals"]}
                    />
                  ) : (
                    <span className="text-xs text-muted-foreground">needs {s.permission_code}</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Run>
        title="Runs"
        description="Every run in the organisation, newest first. Check evaluates the completion against what has happened since the run started; only the person practising may check their own."
        fn="erp_training_runs"
        empty="Nobody has started a scenario. Start is offered on each scenario above, to whoever holds its permission."
      >
        {(rows) => (
          <Table columns={["Scenario", "Started", "Last checked", "State", "Actions"]}>
            {rows.map((r) => (
              <tr key={r.run_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="font-mono text-xs">{r.scenario_code}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {r.mine ? "yours" : "somebody else's"} · {r.scenario_source}
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{when(r.started_at)}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{when(r.checked_at)}</td>
                <td className="py-2 pr-4">
                  <Pill tone={r.completed_at ? "ok" : "warn"}>
                    {r.completed_at ? "complete" : "in progress"}
                  </Pill>
                </td>
                <td className="py-2">
                  {r.mine && !r.completed_at ? (
                    <RpcButton
                      label="Check"
                      fn="erp_check_training_run"
                      args={{ p_run_id: r.run_id }}
                      invalidates={["erp_training_runs", "erp_adoption_signals"]}
                    />
                  ) : (
                    <span className="text-xs text-muted-foreground">—</span>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <ActionBar
        title="Your own adoption scenario"
        note="Build a scenario of this organisation's own from the completion checks the product has. It is offered to whoever holds the permission it names."
        actions={[
          {
            label: "Add a scenario",
            permission: "administration.configure",
            fn: "erp_upsert_training_scenario",
            description:
              "The same code again replaces the scenario. A completion check the product does not have is refused.",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_title", label: "Title", required: true },
              {
                kind: "text",
                name: "p_starting_state",
                label: "Starting state",
                required: true,
                hint: "What the person is given before they begin.",
              },
              {
                kind: "text",
                name: "p_task",
                label: "Task",
                required: true,
                hint: "What they are asked to do, in the organisation's own words.",
              },
              pickFrom(
                "erp_scenario_completions",
                "code",
                ["code", "description"],
                "p_completion_code",
                "Complete when",
              ),
              {
                kind: "text",
                name: "p_permission_code",
                label: "Permission",
                required: true,
                hint: "Who may practise it: procurement.receive, inventory.count, and so on.",
              },
            ],
            invalidates: ["erp_training_scenarios"],
          },
        ]}
      />

      <DataPanel<Topic>
        title="Help topics"
        description="The product's guidance, one topic per screen, as the help button shows it. The build fails when a screen has none. Your organisation's own notes sit beside these through the terminology overrides, under help.local."
        fn="erp_help_topics"
        empty="No help topics. Guidance is installed with the base content pack, and every screen's help comes from it."
        emptyAction={<GoTo to="/administration/packs">Open Packs</GoTo>}
      >
        {(rows) => (
          <Table columns={["Screen", "Summary", "Steps", "Next"]}>
            {rows.map((t) => (
              <tr key={t.screen_path} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <Link to={t.screen_path} className="text-sm underline-offset-2 hover:underline">
                    {t.title}
                  </Link>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {t.screen_path}
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{t.summary}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  <ol className="list-decimal pl-4">
                    {t.steps.map((s, i) => (
                      <li key={i}>{s}</li>
                    ))}
                  </ol>
                </td>
                <td className="py-2 text-xs text-muted-foreground">{t.next_action ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
