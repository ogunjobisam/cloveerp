import { createFileRoute } from "@tanstack/react-router";

import { ActionBar } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";
import { RpcButton } from "../../components/erp/rpc-button";

export const Route = createFileRoute("/operations/cutover")({
  head: () => ({ meta: [{ title: "Migration and cutover — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Cutover />
    </Gate>
  ),
});

/** Shaped by erp_migration_domains(): the register row for each of the four
 *  domains, joined to erp.migration_reconciliation_report() for this
 *  organisation. `finding` is the one sentence between the domain and its
 *  cutover, null when there is none. */
type Domain = {
  domain_code: string;
  name: string;
  module_code: string;
  object_type: string;
  loader_function: string;
  figure_function: string;
  figure_name: string;
  control_purpose: string | null;
  row_keys: { key: string; type: string; required: boolean }[];
  description: string;
  batches_loaded: number;
  rows_loaded: number;
  control_total_minor: number;
  loaded_total_minor: number;
  reconciles: boolean;
  latest_as_at: string | null;
  figure_within_tolerance: boolean | null;
  cutover_status: "pending" | "cut_over" | "reverted";
  finding: string | null;
};

/** Shaped by erp_opening_batches(): every batch of opening balances, newest
 *  first, with the reconciliation after load once it is loaded. */
type Batch = {
  batch_id: string;
  code: string;
  domain_code: string;
  domain: string;
  status: string;
  as_at: string;
  currency: string;
  row_count: number;
  error_count: number;
  control_total_minor: number;
  loaded_total_minor: number | null;
  control_quantity: number | null;
  loaded_quantity: number | null;
  loaded_at: string | null;
  rolled_back_at: string | null;
  reversal_reason: string | null;
  created_at: string;
  checks: {
    check_code: string;
    expected: number;
    actual: number;
    difference: number;
    passes: boolean;
    detail: string;
  }[];
  findings: { row_no: number; findings: { severity: string; message: string }[] }[];
};

/** Shaped by erp_parallel_run_figures(). */
type Figure = {
  figure_id: string;
  domain_code: string;
  domain: string;
  figure_name: string;
  as_at: string;
  legacy_value_minor: number;
  our_value_minor: number;
  difference_minor: number;
  tolerance_minor: number;
  within_tolerance: boolean;
  note: string | null;
  recorded_at: string;
};

/** Shaped by erp_domain_cutovers(): the decision and the evidence it rested on. */
type CutoverRow = {
  domain_code: string;
  domain: string;
  status: "cut_over" | "reverted";
  cut_over_at: string;
  cut_over_by: string | null;
  note: string | null;
  evidence: {
    batches?: { code: string; as_at: string; loaded_total_minor: number }[];
    figure?: {
      as_at: string | null;
      legacy_value_minor: number | null;
      our_value_minor: number | null;
    };
    clearing_balance_minor?: number;
  };
  reverted_at: string | null;
  revert_reason: string | null;
};

const DOMAINS = [
  { value: "stock", label: "Stock" },
  { value: "sales_ledger", label: "Sales ledger" },
  { value: "purchase_ledger", label: "Purchase ledger" },
  { value: "nominal", label: "Nominal ledger" },
];

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function minor(value: number | null | undefined) {
  if (value === null || value === undefined) return "—";
  return value.toLocaleString();
}

function statusTone(status: string): "ok" | "warn" | "bad" | "muted" {
  switch (status) {
    case "loaded":
    case "cut_over":
      return "ok";
    case "rolled_back":
    case "reverted":
    case "rejected":
      return "bad";
    case "validated":
    case "previewed":
      return "warn";
    default:
      return "muted";
  }
}

function Cutover() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Migration and cutover">
        Opening balances arrive as a batch with the control total the legacy extract was taken with,
        dated as at one day, and load through the same movement and journal tables everything else
        posts to. After loading, the product says per check what it expected and what it found. A
        parallel run records what the old system said against what this one computes. A domain is
        cut over only on that evidence, by somebody other than the person who loaded it.
      </PageHeader>

      <ActionBar
        note="Stage a batch from a legacy extract, record the legacy figure against ours, then cut the domain over. A load is reversed from the batch itself, below."
        actions={[
          {
            label: "Stage opening balances",
            permission: "master_data.import",
            fn: "erp_stage_opening_balances",
            fields: [
              {
                kind: "choice",
                name: "p_domain_code",
                label: "Domain",
                required: true,
                choices: DOMAINS,
              },
              {
                kind: "date",
                name: "p_as_at",
                label: "As at",
                required: true,
                hint: "The date the balances stand at. Every movement and journal is dated here.",
              },
              {
                kind: "text",
                name: "p_rows",
                label: "Rows",
                required: true,
                hint: 'A JSON list of rows. Stock: item, site, location, quantity, unit_cost_minor, batch. Ledgers: party, reference, amount_minor, due_date. Nominal: account, debit_minor, credit_minor. For example [{"item":"WID","site":"MAIN","location":"BULK-01","quantity":100,"unit_cost_minor":250}].',
              },
              {
                kind: "number",
                name: "p_control_total_minor",
                label: "Control total, minor units",
                required: true,
                hint: "From the legacy report as at the same date: stock value, open balances, or trial balance debits.",
              },
              {
                kind: "number",
                name: "p_control_quantity",
                label: "Control quantity",
                hint: "Stock only: total units on the legacy report.",
              },
              { kind: "text", name: "p_code", label: "Batch code" },
            ],
            mapArgs: (v) => ({
              p_domain_code: v["p_domain_code"],
              p_as_at: v["p_as_at"],
              p_rows: JSON.parse(v["p_rows"] ?? "[]"),
              p_control_total_minor: Number(v["p_control_total_minor"]),
              p_control_quantity: v["p_control_quantity"] ? Number(v["p_control_quantity"]) : null,
              p_code: v["p_code"] ? v["p_code"] : null,
            }),
            invalidates: ["erp_opening_batches", "erp_migration_domains"],
          },
          {
            label: "Record a parallel-run figure",
            permission: "master_data.import",
            fn: "erp_record_parallel_run_figure",
            fields: [
              {
                kind: "choice",
                name: "p_domain_code",
                label: "Domain",
                required: true,
                choices: DOMAINS,
              },
              { kind: "date", name: "p_as_at", label: "As at", required: true },
              {
                kind: "number",
                name: "p_legacy_value_minor",
                label: "Legacy figure, minor units",
                required: true,
                hint: "What the old system reports for this domain as at the date. Ours is computed when you record it.",
              },
              {
                kind: "number",
                name: "p_tolerance_minor",
                label: "Tolerance, minor units",
                hint: "How far apart the two may be and still agree. Zero when blank.",
              },
              { kind: "text", name: "p_note", label: "Note" },
            ],
            mapArgs: (v) => ({
              p_domain_code: v["p_domain_code"],
              p_as_at: v["p_as_at"],
              p_legacy_value_minor: Number(v["p_legacy_value_minor"]),
              p_tolerance_minor: v["p_tolerance_minor"] ? Number(v["p_tolerance_minor"]) : 0,
              p_note: v["p_note"] ? v["p_note"] : null,
            }),
            invalidates: ["erp_parallel_run_figures", "erp_migration_domains"],
          },
          {
            label: "Cut a domain over",
            permission: "administration.configure",
            fn: "erp_cut_over_domain",
            description:
              "Refused unless every load of the domain reconciles, a parallel-run figure on or after the latest load is within tolerance, and you are not the person who loaded it. The nominal ledger also needs migration clearing at zero.",
            fields: [
              {
                kind: "choice",
                name: "p_domain_code",
                label: "Domain",
                required: true,
                choices: DOMAINS,
              },
              { kind: "text", name: "p_note", label: "Note" },
            ],
            invalidates: ["erp_domain_cutovers", "erp_migration_domains"],
          },
          {
            label: "Revert a cutover",
            permission: "administration.configure",
            fn: "erp_revert_cutover",
            fields: [
              {
                kind: "choice",
                name: "p_domain_code",
                label: "Domain",
                required: true,
                choices: DOMAINS,
              },
              {
                kind: "text",
                name: "p_reason",
                label: "Reason",
                required: true,
                hint: "Kept with the decision. Reverting reopens the domain to loads and reversals.",
              },
            ],
            invalidates: ["erp_domain_cutovers", "erp_migration_domains"],
          },
        ]}
      />

      <DataPanel<Domain>
        title="Where each domain stands"
        description="One row per domain the product migrates: what is loaded, whether it reconciles, whether the latest parallel-run figure agrees, and whether it is cut over. The finding is the one sentence between the domain and its cutover."
        fn="erp_migration_domains"
        empty="No migration domain is registered, which is itself unexpected."
      >
        {(rows) => (
          <Table
            columns={[
              "Domain",
              "Loaded",
              "Reconciles",
              "Parallel run",
              "Cutover",
              "What is missing",
            ]}
          >
            {rows.map((r) => (
              <tr key={r.domain_code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.domain_code} · {r.figure_name}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.batches_loaded > 0 ? (
                    <>
                      {r.batches_loaded} batch{r.batches_loaded === 1 ? "" : "es"}, {r.rows_loaded}{" "}
                      rows
                      <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                        {minor(r.loaded_total_minor)} as at {r.latest_as_at}
                      </div>
                    </>
                  ) : (
                    <span className="text-muted-foreground">Nothing yet</span>
                  )}
                </td>
                <td className="py-2 pr-4">
                  {r.batches_loaded === 0 ? (
                    <Pill tone="muted">—</Pill>
                  ) : r.reconciles ? (
                    <Pill tone="ok">Yes</Pill>
                  ) : (
                    <Pill tone="bad">No</Pill>
                  )}
                </td>
                <td className="py-2 pr-4">
                  {r.figure_within_tolerance === null ? (
                    <Pill tone="muted">Not recorded</Pill>
                  ) : r.figure_within_tolerance ? (
                    <Pill tone="ok">Within tolerance</Pill>
                  ) : (
                    <Pill tone="bad">Out of tolerance</Pill>
                  )}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={statusTone(r.cutover_status)}>
                    {r.cutover_status.replace("_", " ")}
                  </Pill>
                </td>
                <td className="py-2 text-xs text-muted-foreground">{r.finding ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Batch>
        title="Opening balance loads"
        description="Every batch of opening balances, newest first. Validate, preview and load in that order; once loaded, each check shows what the batch expected and what the product found. Reversing posts a reversing journal and reversing movements — the load and its journal stay, marked."
        fn="erp_opening_batches"
        empty="No opening balances have been staged. Stage a batch above from a legacy extract."
      >
        {(rows) => (
          <Table
            columns={["Batch", "As at", "Rows", "Control", "Loaded", "State", "Checks", "Actions"]}
          >
            {rows.map((r) => (
              <tr key={r.batch_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="font-mono text-xs">{r.code}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">{r.domain}</div>
                </td>
                <td className="py-2 pr-4 text-sm">{r.as_at}</td>
                <td className="py-2 pr-4 text-sm">
                  {r.row_count}
                  {r.error_count > 0 ? (
                    <div className="mt-0.5 text-xs text-destructive">{r.error_count} rejected</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {minor(r.control_total_minor)} {r.currency}
                  {r.control_quantity !== null ? (
                    <div className="mt-0.5 text-muted-foreground">{r.control_quantity} units</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {minor(r.loaded_total_minor)}
                  {r.loaded_quantity !== null ? (
                    <div className="mt-0.5 text-muted-foreground">{r.loaded_quantity} units</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={statusTone(r.status)}>{r.status.replace("_", " ")}</Pill>
                  {r.reversal_reason ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.reversal_reason}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-xs">
                  {r.checks.length > 0 ? (
                    <ul className="flex flex-col gap-1">
                      {r.checks.map((c) => (
                        <li key={c.check_code} className="flex items-start gap-2">
                          <Pill tone={c.passes ? "ok" : "bad"}>
                            {c.check_code.replace(/_/g, " ")}
                          </Pill>
                          <span className="text-muted-foreground">{c.detail}</span>
                        </li>
                      ))}
                    </ul>
                  ) : r.findings.length > 0 ? (
                    <ul className="flex flex-col gap-1 text-muted-foreground">
                      {r.findings.map((f) => (
                        <li key={f.row_no}>
                          row {f.row_no}: {f.findings.map((x) => x.message).join("; ")}
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <span className="text-muted-foreground">—</span>
                  )}
                </td>
                <td className="py-2">
                  <span className="flex flex-wrap gap-2">
                    {r.status === "received" || r.status === "validated" ? (
                      <RpcButton
                        label="Validate"
                        fn="erp_validate_import"
                        args={{ p_batch_id: r.batch_id }}
                        permission="master_data.import"
                        invalidates={["erp_opening_batches", "erp_import_batches"]}
                      />
                    ) : null}
                    {r.status === "validated" ? (
                      <RpcButton
                        label="Preview"
                        fn="erp_preview_import"
                        args={{ p_batch_id: r.batch_id }}
                        permission="master_data.import"
                        invalidates={["erp_opening_batches", "erp_import_batches"]}
                      />
                    ) : null}
                    {r.status === "previewed" ? (
                      <RpcButton
                        label="Load"
                        fn="erp_load_import"
                        args={{ p_batch_id: r.batch_id }}
                        permission="master_data.import"
                        invalidates={[
                          "erp_opening_batches",
                          "erp_migration_domains",
                          "erp_import_batches",
                        ]}
                      />
                    ) : null}
                    {r.status === "loaded" ? (
                      <RpcButton
                        label="Reverse"
                        fn="erp_rollback_import"
                        args={{ p_batch_id: r.batch_id }}
                        permission="master_data.import"
                        confirm="Reverse this load? A reversing journal and reversing movements are posted; the load stays as history. Refused once the domain is cut over on it, once the stock has moved, or once a business partner has had ledger activity."
                        invalidates={[
                          "erp_opening_batches",
                          "erp_migration_domains",
                          "erp_import_batches",
                        ]}
                      />
                    ) : null}
                  </span>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Figure>
        title="Parallel-run figures"
        description="For a domain and a date, what the legacy system said and what this product computes from its own ledgers. One figure per domain and date; recording again replaces it. A cutover needs the latest figure on or after the last load to be within tolerance."
        fn="erp_parallel_run_figures"
        empty="No parallel-run figure is recorded. Record one above once the legacy report for the same date is in hand."
      >
        {(rows) => (
          <Table
            columns={[
              "Domain",
              "As at",
              "Legacy",
              "Ours",
              "Difference",
              "Tolerance",
              "Agrees",
              "Note",
            ]}
          >
            {rows.map((r) => (
              <tr key={r.figure_id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.domain}</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">{r.figure_name}</div>
                </td>
                <td className="py-2 pr-4 text-sm">{r.as_at}</td>
                <td className="py-2 pr-4 font-mono text-xs">{minor(r.legacy_value_minor)}</td>
                <td className="py-2 pr-4 font-mono text-xs">{minor(r.our_value_minor)}</td>
                <td className="py-2 pr-4 font-mono text-xs">{minor(r.difference_minor)}</td>
                <td className="py-2 pr-4 font-mono text-xs">{minor(r.tolerance_minor)}</td>
                <td className="py-2 pr-4">
                  {r.within_tolerance ? <Pill tone="ok">Yes</Pill> : <Pill tone="bad">No</Pill>}
                </td>
                <td className="py-2 text-xs text-muted-foreground">
                  {r.note ?? "—"}
                  <div className="mt-0.5">{when(r.recorded_at)}</div>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<CutoverRow>
        title="Cutovers"
        description="Each domain that has been cut over, by whom, and the evidence the decision rested on as it stood at the time — the batches and their checks, the figure, and the balance on migration clearing. A reverted cutover keeps its reason."
        fn="erp_domain_cutovers"
        empty="No domain is cut over yet. The legacy system remains the record for all four."
      >
        {(rows) => (
          <Table columns={["Domain", "State", "Declared", "Evidence", "Note"]}>
            {rows.map((r) => (
              <tr key={r.domain_code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">{r.domain}</td>
                <td className="py-2 pr-4">
                  <Pill tone={statusTone(r.status)}>{r.status.replace("_", " ")}</Pill>
                  {r.reverted_at ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">
                      reverted {when(r.reverted_at)}: {r.revert_reason}
                    </div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.cut_over_at)}
                  <div className="mt-0.5">{r.cut_over_by ?? "—"}</div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {(r.evidence.batches ?? []).map((b) => (
                    <div key={b.code} className="font-mono">
                      {b.code} · {b.as_at} · {minor(b.loaded_total_minor)}
                    </div>
                  ))}
                  {r.evidence.figure?.as_at ? (
                    <div className="mt-0.5">
                      figure as at {r.evidence.figure.as_at}: legacy{" "}
                      {minor(r.evidence.figure.legacy_value_minor)}, ours{" "}
                      {minor(r.evidence.figure.our_value_minor)}
                    </div>
                  ) : null}
                  {r.evidence.clearing_balance_minor !== undefined ? (
                    <div className="mt-0.5">
                      clearing {minor(r.evidence.clearing_balance_minor)}
                    </div>
                  ) : null}
                </td>
                <td className="py-2 text-xs text-muted-foreground">{r.note ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
