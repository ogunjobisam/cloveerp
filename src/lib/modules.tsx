import type { ReactNode } from "react";

import type { Column } from "../components/erp/auto";
import { StatusPill, shortDate } from "../components/erp/auto";
import type { InquirySpec } from "../components/erp/inquiry";
import {
  pickFrom,
  pickItem,
  pickLocation,
  pickParty,
  pickSite,
  reason,
  type ActionSpec,
} from "../components/erp/actions-bar";

/**
 * One description of every module, used by every surface that talks about it.
 *
 * The screens were written one at a time and read like it: each module invented
 * its own page shape, its own ordering, and its own idea of what mattered
 * first. This registry is the fix. A module states its identity, the few
 * numbers that summarise it, the worklists a person acts on, and the reports
 * they read — and the launchpad, the module page and the reporting hub all
 * render from the same declaration.
 *
 * The shape follows the pattern ERP suites converged on independently. SAP
 * Fiori calls it a launchpad of KPI tiles leading to object pages with a
 * consistent header and tab strip; Dynamics calls the same thing a role centre
 * over list pages. The common claim is the useful one: a number is only worth
 * showing if it leads somewhere, and every module should lead somewhere the
 * same way.
 *
 * Nothing here queries anything. Every `fn` is an existing `public.erp_*` read,
 * and the KPI values are derived from those same rows in the browser rather
 * than from a second, disagreeing source.
 */

export type Row = Record<string, unknown>;

export type Panel = {
  title: string;
  description?: string;
  fn: string;
  args?: Record<string, unknown>;
  empty: string;
  rowKey: (row: Row, index: number) => string;
  columns: Column<Row>[];
};

export type Kpi = {
  label: string;
  fn: string;
  args?: Record<string, unknown>;
  /** Derived from the rows of `fn`. Returning null means "no basis to state one". */
  compute: (rows: Row[]) => { value: string; hint?: string; tone?: "ok" | "warn" | "bad" } | null;
};

export type Chart = {
  title: string;
  description?: string;
  fn: string;
  args?: Record<string, unknown>;
  empty: string;
  label: (row: Row) => string;
  value: (row: Row) => number;
  /** Suffix shown after each bar's value, e.g. "%". */
  unit?: string;
};

export type ModuleDef = {
  key: string;
  path: string;
  titleKey: string;
  title: string;
  /** One sentence. Shown on the tile and under the page title. */
  blurb: string;
  permission?: string;
  group: "plan" | "source" | "make" | "move" | "sell" | "settle" | "govern" | "administer";
  kpis: Kpi[];
  chart?: Chart;
  worklists: Panel[];
  reports: Panel[];
  /** The verbs. Rendered as a bar above the tabs; absent when unpermitted. */
  actions?: ActionSpec[];
  /** Reads that take arguments, so they cannot be a standing panel. */
  inquiries?: InquirySpec[];
};

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};

const sum = (rows: Row[], field: string) => rows.reduce((a, r) => a + num(r[field]), 0);

const avg = (rows: Row[], field: string) =>
  rows.length === 0 ? 0 : sum(rows, field) / rows.length;

const count = (rows: Row[], predicate: (r: Row) => boolean) => rows.filter(predicate).length;

const isOneOf = (value: unknown, words: string[]) =>
  words.includes(String(value ?? "").toLowerCase());

const money = (minor: number) =>
  (minor / 100).toLocaleString(undefined, { maximumFractionDigits: 0 });

const pill = (field: string): Column<Row> => ({
  header: "Status",
  cell: (r) => <StatusPill value={r[field]} />,
});

const date = (header: string, field: string): Column<Row> => ({
  header,
  cell: (r) => shortDate(r[field]),
});

/** A count, coloured by whether zero is the good answer. */
const zeroIsGood = (n: number, label: string) => ({
  value: String(n),
  hint: label,
  tone: n === 0 ? ("ok" as const) : n > 5 ? ("bad" as const) : ("warn" as const),
});

export const INVENTORY: ModuleDef = {
  inquiries: [
    {
      label: "Available to promise",
      description: "What can still be committed for one item at one site, on a date.",
      permission: "inventory.read",
      fn: "erp_available_to_promise",
      fields: [pickItem(), pickSite(), { kind: "date", name: "p_on", label: "On" }],
    },
    {
      label: "Batch genealogy",
      description: "Everything one batch touched — what it was made from and where it went.",
      permission: "inventory.read",
      fn: "erp_batch_audit",
      fields: [
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
      ],
    },
    {
      label: "Temperature excursion impact",
      description:
        "What stock was standing in a place between two times, so an excursion can be scoped.",
      permission: "inventory.read",
      fn: "erp_excursion_impact",
      fields: [
        pickSite("p_site_id", "Site", false),
        pickLocation("p_location_id", "Location", false),
        {
          kind: "text",
          name: "p_from",
          label: "From",
          hint: "Date and time, e.g. 2026-08-30 06:00",
        },
        { kind: "text", name: "p_to", label: "To", hint: "Date and time, e.g. 2026-08-30 18:00" },
      ],
    },
    {
      label: "Redistribution suggestions",
      description: "Where slow stock at one site would sell at another.",
      permission: "inventory.read",
      fn: "erp_redistribution_suggestions",
      fields: [{ kind: "number", name: "p_days", label: "Days", hint: "Default 60." }],
    },
  ],
  key: "inventory",
  path: "/inventory",
  titleKey: "module.inventory",
  title: "Inventory",
  blurb: "Stock health, valuation, ageing, expiry and counting, all derived from the ledger.",
  permission: "inventory.read",
  group: "move",
  actions: [
    {
      label: "Raise count tasks",
      description: "Ask a counting programme for its next set of tasks.",
      permission: "inventory.count",
      fn: "erp_raise_count_tasks",
      fields: [{ kind: "text", name: "p_programme_code", label: "Programme code", required: true }],
      invalidates: ["erp_count_tasks", "erp_count_accuracy"],
    },
    {
      label: "Record a count",
      permission: "inventory.count",
      fn: "erp_record_count",
      fields: [
        pickFrom(
          "erp_count_tasks",
          "task_id",
          ["item", "location", "status"],
          "p_task_id",
          "Count task",
        ),
        { kind: "number", name: "p_quantity", label: "Counted quantity", required: true },
      ],
      invalidates: ["erp_count_tasks", "erp_count_accuracy", "erp_stock_health"],
    },
    {
      label: "Post a count",
      description: "Turn a counted task into a stock adjustment.",
      permission: "inventory.count",
      fn: "erp_post_count",
      fields: [
        pickFrom(
          "erp_count_tasks",
          "task_id",
          ["item", "location", "status"],
          "p_task_id",
          "Count task",
        ),
      ],
      invalidates: [
        "erp_count_tasks",
        "erp_count_accuracy",
        "erp_stock_health",
        "erp_stock_valuation",
      ],
    },
    {
      label: "Write off stock",
      permission: "inventory.write_off",
      fn: "erp_write_off_stock",
      fields: [
        pickItem(),
        pickSite(),
        pickLocation(),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        reason("p_reason", "Reason", true),
        pickFrom(
          "erp_batches",
          "batch_id",
          ["batch_number", "item"],
          "p_batch_id",
          "Batch (if controlled)",
        ),
      ],
      invalidates: ["erp_stock_health", "erp_stock_valuation", "erp_stock_ageing", "erp_batches"],
    },
    {
      label: "Split a batch",
      permission: "inventory.adjust",
      fn: "erp_split_batch",
      fields: [
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
        { kind: "text", name: "p_new_number", label: "New batch number", required: true },
        { kind: "number", name: "p_quantity", label: "Quantity to split", required: true },
        pickLocation(),
        reason(),
      ],
      invalidates: ["erp_batches", "erp_stock_health"],
    },
    {
      label: "Release a batch",
      permission: "quality.release_batch",
      fn: "erp_release_batch",
      fields: [
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
        pickSite(),
        { kind: "text", name: "p_basis", label: "Basis", required: true },
        { kind: "text", name: "p_signature", label: "Signature", required: true },
      ],
      invalidates: ["erp_batches", "erp_stock_health"],
    },
    {
      label: "Merge two batches",
      description: "Combine one batch into another of the same item and condition.",
      permission: "inventory.adjust",
      fn: "erp_merge_batches",
      fields: [
        pickFrom(
          "erp_batches",
          "batch_id",
          ["batch_number", "item"],
          "p_target_batch_id",
          "Surviving batch",
        ),
        pickFrom(
          "erp_batches",
          "batch_id",
          ["batch_number", "item"],
          "p_source_batch_id",
          "Batch being merged",
        ),
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_batches", "erp_stock_health", "erp_expiry_horizon"],
    },
    {
      label: "Raise putaway tasks",
      description: "Ask the warehouse to move what is standing in goods-in.",
      permission: "inventory.adjust",
      fn: "erp_raise_putaway_tasks",
      fields: [pickSite()],
      invalidates: ["erp_warehouse_tasks"],
    },
    {
      label: "Raise replenishment tasks",
      description: "Top the pick faces up from reserve where demand exceeds what is there.",
      permission: "inventory.adjust",
      fn: "erp_raise_replenishment_tasks",
      fields: [pickSite()],
      invalidates: ["erp_warehouse_tasks"],
    },
    {
      label: "Complete a warehouse task",
      permission: "inventory.adjust",
      fn: "erp_complete_warehouse_task",
      fields: [
        pickFrom(
          "erp_warehouse_tasks",
          "task_id",
          ["kind", "item", "from_location", "to_location"],
          "p_task_id",
          "Task",
        ),
        { kind: "number", name: "p_quantity", label: "Quantity", hint: "Blank means all of it." },
      ],
      invalidates: ["erp_warehouse_tasks", "erp_stock_health"],
    },
    {
      label: "Apply calculated policy",
      description: "Adopt the stocking policy the engine calculates for one item and site.",
      permission: "inventory.adjust",
      fn: "erp_apply_calculated_policy",
      fields: [pickItem(), pickSite()],
      invalidates: ["erp_stock_health"],
    },
  ],

  kpis: [
    {
      label: "Stock lines",
      fn: "erp_stock_health",
      compute: (rows) => ({ value: String(rows.length), hint: "item and site positions" }),
    },
    {
      label: "Below cover",
      fn: "erp_stock_health",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => isOneOf(r["health"] ?? r["status"], ["short", "below", "critical"])),
          "positions under policy",
        ),
    },
    {
      label: "Stock value",
      fn: "erp_stock_valuation",
      compute: (rows) =>
        rows.length === 0
          ? null
          : { value: money(sum(rows, "value_minor")), hint: String(rows[0]?.["currency"] ?? "") },
    },
    {
      label: "Expiring in 30 days",
      fn: "erp_expiry_horizon",
      args: { p_days: 30 },
      compute: (rows) => zeroIsGood(rows.length, "batches on the horizon"),
    },
  ],
  chart: {
    title: "Stock ageing",
    description: "Quantity by age band.",
    fn: "erp_stock_ageing",
    empty: "No aged stock to profile.",
    label: (r) => String(r["age_band"] ?? "—"),
    value: (r) => num(r["quantity"]),
  },
  worklists: [
    {
      title: "Count tasks",
      description: "Raised by the counting programme and waiting on a person.",
      fn: "erp_count_tasks",
      empty: "No count tasks raised.",
      rowKey: (r, i) => String(r["task_id"] ?? i),
      columns: [
        { header: "Item", cell: "item" },
        { header: "Location", cell: "location" },
        { header: "Expected", cell: "expected", numeric: true },
        { header: "Counted", cell: "counted", numeric: true },
        { header: "Variance", cell: "variance", numeric: true },
        pill("status"),
      ],
    },
    {
      title: "Warehouse tasks",
      description: "Putaway and replenishment, raised from the balances and waiting on a truck.",
      fn: "erp_warehouse_tasks",
      empty: "No warehouse tasks outstanding.",
      rowKey: (r, i) => String(r["task_id"] ?? i),
      columns: [
        { header: "Kind", cell: "kind" },
        { header: "Item", cell: "item" },
        { header: "From", cell: "from_location" },
        { header: "To", cell: "to_location" },
        { header: "Quantity", cell: "quantity", numeric: true },
        { header: "Done", cell: "quantity_done", numeric: true },
        pill("status"),
      ],
    },
    {
      title: "Expiry horizon",
      description: "Batches reaching their expiry inside thirty days.",
      fn: "erp_expiry_horizon",
      args: { p_days: 30 },
      empty: "Nothing expires in the next thirty days.",
      rowKey: (r, i) => String(r["batch_id"] ?? i),
      columns: [
        { header: "Batch", cell: "batch_number" },
        { header: "Item", cell: "item_code" },
        date("Expires", "expires_on"),
        { header: "Quantity", cell: "quantity", numeric: true },
        { header: "Days left", cell: "days_remaining", numeric: true },
      ],
    },
  ],
  reports: [
    {
      title: "Stock health",
      description: "Cover against policy, by item and site.",
      fn: "erp_stock_health",
      empty: "No stock positions yet — nothing has moved into this tenant.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["site_code"] ?? i)}`,
      columns: [
        { header: "Item", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "On hand", cell: "on_hand", numeric: true },
        { header: "Available", cell: "available", numeric: true },
        { header: "Allocated", cell: "allocated", numeric: true },
        { header: "Status", cell: (r) => <StatusPill value={r["health"] ?? r["status"]} /> },
      ],
    },
    {
      title: "Valuation",
      description: "Cost basis by item and site, in minor units.",
      fn: "erp_stock_valuation",
      empty: "Nothing to value yet.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["site_code"] ?? i)}`,
      columns: [
        { header: "Item", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "Quantity", cell: "quantity", numeric: true },
        { header: "Value (minor)", cell: "value_minor", numeric: true },
        { header: "Currency", cell: "currency" },
      ],
    },
    {
      title: "Ageing",
      description: "How long stock has been standing still.",
      fn: "erp_stock_ageing",
      empty: "No aged stock.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["age_band"] ?? i)}`,
      columns: [
        { header: "Item", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "Band", cell: "age_band" },
        { header: "Quantity", cell: "quantity", numeric: true },
      ],
    },
    {
      title: "Batches",
      description: "Traceable units, with their genealogy anchors.",
      fn: "erp_batches",
      empty: "No batches yet.",
      rowKey: (r, i) => String(r["batch_id"] ?? i),
      columns: [
        { header: "Batch", cell: "batch_number" },
        { header: "Item", cell: "item" },
        pill("status"),
        date("Made", "manufactured_on"),
        date("Expires", "expires_on"),
        { header: "Supplier lot", cell: "supplier_lot" },
      ],
    },
    {
      title: "Count accuracy",
      description: "How close the counts came, by programme.",
      fn: "erp_count_accuracy",
      empty: "No counts posted yet, so accuracy cannot be stated.",
      rowKey: (r, i) => String(r["programme_code"] ?? i),
      columns: [
        { header: "Programme", cell: "programme_code" },
        { header: "Counted", cell: "tasks_counted", numeric: true },
        { header: "Within tolerance", cell: "within_tolerance", numeric: true },
        { header: "Accuracy %", cell: "accuracy_pct", numeric: true },
      ],
    },
  ],
};

export const FINANCE: ModuleDef = {
  inquiries: [
    {
      label: "Credit position",
      description: "Limit, exposure and what is left for one customer.",
      permission: "finance.read",
      fn: "erp_credit_position",
      fields: [pickParty("customer")],
    },
    {
      label: "Budget position",
      description: "Budget against actual for one budget code.",
      permission: "finance.read",
      fn: "erp_budget_position",
      fields: [{ kind: "text", name: "p_code", label: "Code", required: true }],
    },
  ],
  key: "finance",
  path: "/finance",
  titleKey: "module.finance",
  title: "Finance",
  blurb: "Trial balance, periods, receivables, tax and assets, read from the posted ledger.",
  permission: "finance.read",
  group: "settle",
  actions: [
    {
      label: "Open a period close",
      permission: "finance.close_period",
      fn: "erp_open_period_close",
      fields: [
        pickFrom(
          "erp_fiscal_periods",
          "fiscal_period_id",
          ["code", "status"],
          "p_fiscal_period_id",
          "Period",
        ),
      ],
      invalidates: ["erp_fiscal_periods", "erp_close_status"],
    },
    {
      label: "Complete a close task",
      permission: "finance.close_period",
      fn: "erp_complete_close_task",
      fields: [
        pickFrom(
          "erp_close_tasks",
          "task_id",
          ["period", "code", "status"],
          "p_task_id",
          "Close task",
        ),
        { kind: "text", name: "p_waiver_reason", label: "Waiver reason" },
      ],
      invalidates: ["erp_close_status"],
    },
    {
      label: "Close a period",
      permission: "finance.close_period",
      fn: "erp_close_period",
      fields: [
        pickFrom(
          "erp_fiscal_periods",
          "fiscal_period_id",
          ["code", "status"],
          "p_fiscal_period_id",
          "Period",
        ),
      ],
      invalidates: ["erp_fiscal_periods", "erp_close_status", "erp_trial_balance"],
    },
    {
      label: "Reopen a period",
      permission: "finance.reopen_period",
      fn: "erp_reopen_period",
      fields: [
        pickFrom(
          "erp_fiscal_periods",
          "fiscal_period_id",
          ["code", "status"],
          "p_fiscal_period_id",
          "Period",
        ),
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_fiscal_periods", "erp_close_status"],
    },
    {
      label: "Propose a payment run",
      permission: "finance.approve_payment",
      fn: "erp_propose_payment_run",
      fields: [
        { kind: "date", name: "p_payment_date", label: "Payment date" },
        { kind: "text", name: "p_currency", label: "Currency", hint: "Three-letter code." },
      ],
      invalidates: ["erp_payment_runs", "erp_payables_ageing"],
    },
    {
      label: "Approve a payment run",
      permission: "finance.approve_payment",
      fn: "erp_approve_payment_run",
      fields: [
        pickFrom(
          "erp_payment_proposals",
          "proposal_id",
          ["reference", "payment_date", "status"],
          "p_proposal_id",
          "Payment proposal",
        ),
      ],
      invalidates: ["erp_payment_runs", "erp_payables_ageing"],
    },
    {
      label: "Apply cash",
      permission: "finance.post",
      fn: "erp_apply_cash",
      fields: [
        pickParty("customer"),
        {
          kind: "number",
          name: "p_amount_minor",
          label: "Amount",
          required: true,
          hint: "In minor units — pence, cents.",
        },
        { kind: "text", name: "p_currency", label: "Currency", required: true },
        { kind: "text", name: "p_reference", label: "Reference" },
      ],
      invalidates: ["erp_receivables_ageing", "erp_dunning_worklist", "erp_trial_balance"],
    },
    {
      label: "Invoice a delivery",
      permission: "sales.invoice",
      fn: "erp_invoice_from_delivery",
      fields: [
        pickFrom(
          "erp_documents",
          "document_id",
          ["document_number", "status"],
          "p_delivery_id",
          "Delivery",
          { p_type_code: null, p_limit: 100 },
        ),
        {
          kind: "choice",
          name: "p_allow_self_invoice",
          label: "Allow self-invoice",
          boolean: true,
          choices: [
            { value: "false", label: "No" },
            { value: "true", label: "Yes" },
          ],
        },
      ],
      invalidates: ["erp_receivables_ageing", "erp_trial_balance"],
    },
    {
      label: "Allocate a landed cost",
      permission: "finance.post",
      fn: "erp_allocate_landed_cost",
      fields: [
        pickFrom(
          "erp_landed_costs",
          "landed_cost_id",
          ["charge_code", "description", "receipt"],
          "p_landed_cost_id",
          "Landed cost",
        ),
      ],
      invalidates: ["erp_trial_balance", "erp_stock_valuation"],
    },
  ],

  kpis: [
    {
      label: "Receivables",
      fn: "erp_receivables_ageing",
      compute: (rows) =>
        rows.length === 0
          ? null
          : { value: money(sum(rows, "total_minor")), hint: "outstanding, all customers" },
    },
    {
      label: "Overdue 60+",
      fn: "erp_receivables_ageing",
      compute: (rows) => {
        const v = sum(rows, "days_60_plus_minor");
        return { value: money(v), hint: "past sixty days", tone: v > 0 ? "bad" : "ok" };
      },
    },
    {
      label: "Needs chasing",
      fn: "erp_dunning_worklist",
      compute: (rows) => zeroIsGood(rows.length, "customers in dunning"),
    },
    {
      label: "Open periods",
      fn: "erp_fiscal_periods",
      compute: (rows) => ({
        value: String(count(rows, (r) => isOneOf(r["status"], ["open"]))),
        hint: `of ${rows.length} in the calendar`,
      }),
    },
  ],
  chart: {
    title: "Receivables ageing",
    description: "Outstanding balance by age band.",
    fn: "erp_receivables_ageing",
    empty: "Nothing outstanding to profile.",
    label: (r) => String(r["party"] ?? "—"),
    value: (r) => num(r["total_minor"]) / 100,
  },
  worklists: [
    {
      title: "Dunning worklist",
      description: "Customers overdue enough to contact.",
      fn: "erp_dunning_worklist",
      empty: "Nobody needs chasing.",
      rowKey: (r, i) => String(r["party"] ?? i),
      columns: [
        { header: "Customer", cell: "party" },
        { header: "Overdue", cell: "overdue_minor", numeric: true },
        date("Oldest", "oldest_due_date"),
        { header: "Stage", cell: "dunning_stage" },
      ],
    },
    {
      title: "Goods received not invoiced",
      description: "Received against a purchase order, still awaiting an invoice.",
      fn: "erp_grni",
      empty: "Nothing received awaiting an invoice.",
      rowKey: (r, i) => `${String(r["document_number"] ?? i)}-${i}`,
      columns: [
        { header: "Receipt", cell: "document_number" },
        { header: "Supplier", cell: "party" },
        { header: "Item", cell: "item_code" },
        { header: "Quantity", cell: "quantity_open", numeric: true },
        { header: "Value", cell: "value_minor", numeric: true },
        { header: "Age (days)", cell: "age_days", numeric: true },
      ],
    },
  ],
  reports: [
    {
      title: "Slow-moving stock provision",
      description:
        "One published policy: nothing under ninety days, a quarter to six months, half to a year, all of it beyond.",
      fn: "erp_stock_provision",
      empty: "Nothing is old enough to provide against.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["bucket"] ?? i)}`,
      columns: [
        { header: "Item", cell: "item_code" },
        { header: "Name", cell: "item_name" },
        { header: "Age band", cell: "bucket" },
        { header: "Quantity", cell: "quantity", numeric: true },
        { header: "Value (minor)", cell: "value_minor", numeric: true },
        { header: "Provision %", cell: "provision_pct", numeric: true },
        { header: "Provision (minor)", cell: "provision_minor", numeric: true },
      ],
    },
    {
      title: "Trial balance",
      description: "Every account with a movement, by ledger.",
      fn: "erp_trial_balance",
      empty: "Nothing posted yet.",
      rowKey: (r, i) => `${String(r["ledger"] ?? i)}-${String(r["account"] ?? i)}`,
      columns: [
        { header: "Ledger", cell: "ledger" },
        { header: "Account", cell: "account" },
        { header: "Name", cell: "name" },
        { header: "Type", cell: "account_type" },
        { header: "Debit", cell: "debit_minor", numeric: true },
        { header: "Credit", cell: "credit_minor", numeric: true },
        { header: "Balance", cell: "balance_minor", numeric: true },
      ],
    },
    {
      title: "Receivables ageing",
      description: "What is outstanding, and for how long.",
      fn: "erp_receivables_ageing",
      empty: "Nothing outstanding.",
      rowKey: (r, i) => String(r["party"] ?? i),
      columns: [
        { header: "Customer", cell: "party" },
        { header: "Currency", cell: "currency" },
        { header: "Current", cell: "current_minor", numeric: true },
        { header: "1–30", cell: "days_1_30_minor", numeric: true },
        { header: "31–60", cell: "days_31_60_minor", numeric: true },
        { header: "60+", cell: "days_60_plus_minor", numeric: true },
        { header: "Total", cell: "total_minor", numeric: true },
      ],
    },
    {
      title: "Tax report",
      description: "Net and tax by code for the current period.",
      fn: "erp_tax_report",
      empty: "No taxable transactions in this period.",
      rowKey: (r, i) => String(r["tax_code"] ?? i),
      columns: [
        { header: "Code", cell: "tax_code" },
        { header: "Rate %", cell: "rate_pct", numeric: true },
        { header: "Net", cell: "net_minor", numeric: true },
        { header: "Tax", cell: "tax_minor", numeric: true },
        { header: "Currency", cell: "currency" },
      ],
    },
    {
      title: "Fixed assets",
      description: "The register as at today.",
      fn: "erp_fixed_asset_register",
      empty: "No fixed assets recorded.",
      rowKey: (r, i) => String(r["asset_code"] ?? i),
      columns: [
        { header: "Asset", cell: "asset_code" },
        { header: "Name", cell: "name" },
        { header: "Cost", cell: "cost_minor", numeric: true },
        { header: "Depreciation", cell: "accumulated_depreciation_minor", numeric: true },
        { header: "Net book value", cell: "net_book_value_minor", numeric: true },
      ],
    },
    {
      title: "Intercompany position",
      description: "What each entity owes another, before elimination.",
      fn: "erp_intercompany_position",
      empty: "No intercompany balances.",
      rowKey: (r, i) => `${String(r["from_entity"] ?? i)}-${String(r["to_entity"] ?? i)}-${i}`,
      columns: [
        { header: "From", cell: "from_entity" },
        { header: "To", cell: "to_entity" },
        { header: "Currency", cell: "currency" },
        { header: "Balance", cell: "balance_minor", numeric: true },
        { header: "Matched", cell: "is_matched" },
      ],
    },
    {
      title: "Ledgers",
      description: "The books this tenant keeps.",
      fn: "erp_ledgers",
      empty: "No ledger configured. Installing the finance module is what creates one.",
      rowKey: (r, i) => String(r["code"] ?? i),
      columns: [
        { header: "Code", cell: "code" },
        { header: "Name", cell: "name" },
        { header: "Kind", cell: "kind" },
        { header: "Currency", cell: "currency" },
        { header: "Primary", cell: "is_primary" },
        pill("status"),
      ],
    },
    {
      title: "Periods",
      description: "The fiscal calendar and where it is open.",
      fn: "erp_fiscal_periods",
      empty: "No fiscal calendar yet.",
      rowKey: (r, i) => String(r["code"] ?? i),
      columns: [
        { header: "Period", cell: "code" },
        { header: "Ledger", cell: "ledger" },
        { header: "Year", cell: "fiscal_year", numeric: true },
        date("Starts", "starts_on"),
        date("Ends", "ends_on"),
        pill("status"),
      ],
    },
  ],
};

export const PLANNING: ModuleDef = {
  inquiries: [
    {
      label: "Supply and demand",
      description: "The projected balance for one item and site across the horizon.",
      permission: "planning.read",
      fn: "erp_supply_demand",
      fields: [
        pickItem(),
        pickSite(),
        { kind: "number", name: "p_horizon_days", label: "Horizon (days)", hint: "Default 180." },
      ],
    },
    {
      label: "Calculated stocking policy",
      description: "What the engine would set for one item and site, before adopting it.",
      permission: "planning.read",
      fn: "erp_calculate_policy",
      fields: [pickItem(), pickSite()],
    },
  ],
  key: "planning",
  path: "/planning",
  titleKey: "module.planning",
  title: "Planning",
  blurb: "Planned orders and the exceptions worth acting on before they become shortages.",
  permission: "planning.read",
  group: "plan",
  actions: [
    {
      label: "Run planning",
      description: "Regenerate planned orders and exceptions for one site.",
      permission: "planning.run",
      fn: "erp_run_planning",
      fields: [
        pickSite(),
        { kind: "number", name: "p_horizon_days", label: "Horizon (days)", hint: "Default 180." },
      ],
      invalidates: ["erp_planned_orders", "erp_planner_workbench"],
    },
    {
      label: "Run a forecast",
      permission: "planning.forecast",
      fn: "erp_run_forecast",
      fields: [
        { kind: "text", name: "p_forecast_code", label: "Forecast code", required: true },
        { kind: "number", name: "p_periods", label: "Periods ahead" },
        { kind: "number", name: "p_buckets", label: "History buckets" },
      ],
      invalidates: ["erp_planner_workbench", "erp_planned_orders"],
    },
    {
      label: "Sign off a forecast",
      permission: "planning.forecast",
      fn: "erp_sign_off_forecast",
      fields: [
        pickFrom(
          "erp_forecast_versions",
          "version_id",
          ["forecast", "version", "status"],
          "p_version_id",
          "Forecast version",
        ),
        { kind: "text", name: "p_note", label: "Note" },
      ],
      invalidates: ["erp_planner_workbench"],
    },
  ],

  kpis: [
    {
      label: "Open exceptions",
      fn: "erp_planning_exceptions",
      compute: (rows) => zeroIsGood(rows.length, "raised against the plan"),
    },
    {
      label: "Unacknowledged",
      fn: "erp_planning_exceptions",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => !r["is_acknowledged"]),
          "nobody has looked at these",
        ),
    },
    {
      label: "Planned orders",
      fn: "erp_planned_orders",
      compute: (rows) => ({ value: String(rows.length), hint: "awaiting release" }),
    },
    {
      label: "Planned quantity",
      fn: "erp_planned_orders",
      compute: (rows) =>
        rows.length === 0
          ? null
          : { value: sum(rows, "quantity").toLocaleString(), hint: "across all planned orders" },
    },
  ],
  chart: {
    title: "Exceptions by kind",
    description: "Where the plan is inconsistent.",
    fn: "erp_planning_exceptions",
    empty: "No exceptions to profile.",
    label: (r) => String(r["exception_kind"] ?? "—"),
    value: () => 1,
  },
  worklists: [
    {
      title: "Planning exceptions",
      description: "What the last planning run could not reconcile.",
      fn: "erp_planning_exceptions",
      empty: "No exceptions — the plan is currently consistent.",
      rowKey: (r, i) => String(r["exception_id"] ?? i),
      columns: [
        { header: "Item", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Kind", cell: "exception_kind" },
        { header: "Severity", cell: (r) => <StatusPill value={r["severity"]} /> },
        { header: "Message", cell: "message" },
        { header: "Acknowledged", cell: "is_acknowledged" },
      ],
    },
  ],
  reports: [
    {
      title: "Planned orders",
      description: "Proposed supply, with the date it has to be released to land on time.",
      fn: "erp_planned_orders",
      empty: "No planned orders. Nothing is short against current demand.",
      rowKey: (r, i) => String(r["planned_order_id"] ?? i),
      columns: [
        { header: "Item", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Kind", cell: "order_kind" },
        { header: "Quantity", cell: "quantity", numeric: true },
        date("Required", "required_on"),
        date("Release", "release_on"),
        pill("status"),
      ],
    },
  ],
};

export const PRODUCTION: ModuleDef = {
  inquiries: [
    {
      label: "Component availability",
      description: "Whether one works order can be released against what is on hand.",
      permission: "production.read",
      fn: "erp_works_order_availability",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
      ],
    },
    {
      label: "Works order variance",
      description: "Planned against actual materials and time, once it has run.",
      permission: "production.read",
      fn: "erp_works_order_variance",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
      ],
    },
    {
      label: "Batch record",
      description: "The manufacturing record for one works order, as issued.",
      permission: "production.read",
      fn: "erp_batch_record",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
      ],
    },
  ],
  key: "production",
  path: "/production",
  titleKey: "module.production",
  title: "Production",
  blurb: "Works orders and their progress against plan, quantity by quantity.",
  permission: "production.read",
  group: "make",
  actions: [
    {
      label: "Raise a works order",
      permission: "production.order",
      fn: "erp_raise_works_order",
      fields: [
        pickItem(),
        pickSite(),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        {
          kind: "choice",
          name: "p_kind",
          label: "Kind",
          required: true,
          choices: [
            { value: "assembly", label: "Assembly" },
            { value: "kitting", label: "Kitting" },
            { value: "rework", label: "Rework" },
            { value: "repackaging", label: "Repackaging" },
            { value: "disassembly", label: "Disassembly" },
          ],
        },
        { kind: "date", name: "p_planned_end", label: "Planned finish" },
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor"],
    },
    {
      label: "Release a works order",
      permission: "production.release",
      fn: "erp_release_works_order",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
        {
          kind: "choice",
          name: "p_allow_shortage",
          label: "Release despite shortages",
          boolean: true,
          choices: [
            { value: "false", label: "No" },
            { value: "true", label: "Yes" },
          ],
        },
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor"],
    },
    {
      label: "Issue components",
      permission: "production.execute",
      fn: "erp_issue_to_works_order",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
        pickItem("p_component_item_id", "Component"),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor", "erp_stock_health"],
    },
    {
      label: "Book operation time",
      permission: "production.execute",
      fn: "erp_book_operation_time",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
        { kind: "number", name: "p_operation_seq", label: "Operation", required: true },
        { kind: "number", name: "p_minutes", label: "Minutes", required: true },
        { kind: "number", name: "p_completed", label: "Completed" },
        { kind: "number", name: "p_scrapped", label: "Scrapped" },
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor"],
    },
    {
      label: "Receive output",
      permission: "production.execute",
      fn: "erp_receive_works_order_output",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        { kind: "text", name: "p_batch_number", label: "Batch number" },
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor", "erp_stock_health"],
    },
    {
      label: "Close a works order",
      permission: "production.execute",
      fn: "erp_close_works_order",
      fields: [
        pickFrom(
          "erp_works_orders",
          "works_order_id",
          ["order_number", "status"],
          "p_works_order_id",
          "Works order",
        ),
      ],
      invalidates: ["erp_works_orders", "erp_shop_floor"],
    },
  ],

  kpis: [
    {
      label: "Open works orders",
      fn: "erp_works_orders",
      compute: (rows) => ({
        value: String(count(rows, (r) => !isOneOf(r["status"], ["closed", "completed"]))),
        hint: `of ${rows.length} raised`,
      }),
    },
    {
      label: "Quantity in progress",
      fn: "erp_works_orders",
      compute: (rows) =>
        rows.length === 0
          ? null
          : {
              value: (sum(rows, "quantity") - sum(rows, "quantity_completed")).toLocaleString(),
              hint: "ordered less completed",
            },
    },
    {
      label: "Scrapped",
      fn: "erp_works_orders",
      compute: (rows) => {
        const s = sum(rows, "quantity_scrapped");
        return { value: s.toLocaleString(), hint: "units", tone: s > 0 ? "warn" : "ok" };
      },
    },
    {
      label: "Completion",
      fn: "erp_works_orders",
      compute: (rows) => {
        const ordered = sum(rows, "quantity");
        if (ordered === 0) return null;
        return {
          value: `${Math.round((sum(rows, "quantity_completed") / ordered) * 100)}%`,
          hint: "of ordered quantity",
        };
      },
    },
  ],
  chart: {
    title: "Works orders by status",
    description: "Where the shop floor currently sits.",
    fn: "erp_works_orders",
    empty: "No works orders to profile.",
    label: (r) => String(r["status"] ?? "—"),
    value: () => 1,
  },
  worklists: [
    {
      title: "Works orders",
      description: "Everything raised, with progress against the ordered quantity.",
      fn: "erp_works_orders",
      empty: "No works orders raised.",
      rowKey: (r, i) => String(r["works_order_id"] ?? r["order_number"] ?? i),
      columns: [
        { header: "Number", cell: "order_number" },
        { header: "Item", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Kind", cell: "order_kind" },
        { header: "Ordered", cell: "quantity", numeric: true },
        { header: "Completed", cell: "quantity_completed", numeric: true },
        { header: "Scrapped", cell: "quantity_scrapped", numeric: true },
        date("Due", "planned_end"),
        pill("status"),
      ],
    },
  ],
  reports: [
    {
      title: "Works order register",
      description: "The full register, including closed orders.",
      fn: "erp_works_orders",
      empty: "No works orders raised.",
      rowKey: (r, i) => String(r["works_order_id"] ?? r["order_number"] ?? i),
      columns: [
        { header: "Number", cell: "order_number" },
        { header: "Item", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Ordered", cell: "quantity", numeric: true },
        { header: "Completed", cell: "quantity_completed", numeric: true },
        { header: "Scrapped", cell: "quantity_scrapped", numeric: true },
        date("Start", "planned_start"),
        date("Due", "planned_end"),
        pill("status"),
      ],
    },
  ],
};

export const QUALITY: ModuleDef = {
  inquiries: [
    {
      label: "Recall readiness",
      description: "Whether the trace for a recall can be produced inside the regulatory clock.",
      permission: "quality.read",
      fn: "erp_recall_readiness",
      fields: [pickFrom("erp_recalls", "recall_id", ["title", "status"], "p_recall_id", "Recall")],
    },
    {
      label: "Recall evidence",
      description: "The trace and the actions logged against one recall.",
      permission: "quality.read",
      fn: "erp_recall_evidence",
      fields: [pickFrom("erp_recalls", "recall_id", ["title", "status"], "p_recall_id", "Recall")],
    },
  ],
  key: "quality",
  path: "/quality",
  titleKey: "module.quality",
  title: "Quality and recall",
  blurb: "Events, dispositions, supplier qualification and recall — each with a clock.",
  permission: "quality.read",
  group: "govern",
  actions: [
    {
      label: "Raise a quality event",
      permission: "quality.inspect",
      fn: "erp_raise_quality_event",
      fields: [
        {
          kind: "choice",
          name: "p_kind",
          label: "Kind",
          required: true,
          choices: [
            { value: "deviation", label: "Deviation" },
            { value: "non_conformance", label: "Non-conformance" },
            { value: "complaint", label: "Complaint" },
            { value: "excursion", label: "Excursion" },
            { value: "near_miss", label: "Near miss" },
            { value: "audit_finding", label: "Audit finding" },
          ],
        },
        { kind: "text", name: "p_title", label: "Title", required: true },
        {
          kind: "choice",
          name: "p_severity",
          label: "Severity",
          required: true,
          choices: [
            { value: "low", label: "Low" },
            { value: "medium", label: "Medium" },
            { value: "high", label: "High" },
            { value: "critical", label: "Critical" },
          ],
        },
        pickSite("p_site_id", "Site", false),
        {
          kind: "select",
          name: "p_item_id",
          label: "Item",
          options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
        },
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
      ],
      invalidates: ["erp_quality_events", "erp_open_quality_events"],
    },
    {
      label: "Record an inspection result",
      permission: "quality.inspect",
      fn: "erp_record_inspection_result",
      fields: [
        pickFrom(
          "erp_inspections",
          "inspection_id",
          ["item", "batch", "status"],
          "p_inspection_id",
          "Inspection",
        ),
        { kind: "text", name: "p_characteristic", label: "Characteristic", required: true },
        { kind: "number", name: "p_numeric_value", label: "Measured value" },
        { kind: "text", name: "p_text_value", label: "Observed value" },
        { kind: "text", name: "p_instrument", label: "Instrument" },
      ],
      invalidates: ["erp_open_inspections", "erp_quality_events"],
    },
    {
      label: "Disposition an inspection",
      permission: "quality.disposition",
      fn: "erp_disposition_inspection",
      fields: [
        pickFrom(
          "erp_inspections",
          "inspection_id",
          ["item", "batch", "status"],
          "p_inspection_id",
          "Inspection",
        ),
        {
          kind: "choice",
          name: "p_disposition",
          label: "Disposition",
          required: true,
          choices: [
            { value: "accept", label: "Accept" },
            { value: "accept_with_concession", label: "Accept with concession" },
            { value: "rework", label: "Rework" },
            { value: "reject", label: "Reject" },
            { value: "quarantine", label: "Quarantine" },
            { value: "destroy", label: "Destroy" },
          ],
        },
        { kind: "text", name: "p_note", label: "Note" },
      ],
      invalidates: ["erp_open_inspections", "erp_quality_events", "erp_batches"],
    },
    {
      label: "Raise a recall",
      permission: "quality.recall",
      fn: "erp_raise_recall",
      fields: [
        { kind: "text", name: "p_title", label: "Title", required: true },
        reason("p_reason", "Reason", true),
        { kind: "text", name: "p_classification", label: "Classification", required: true },
        {
          kind: "text",
          name: "p_batch_ids",
          label: "Batch ids",
          required: true,
          hint: "Comma separated.",
        },
      ],
      invalidates: ["erp_recalls"],
      mapArgs: (v) => ({
        p_title: v["p_title"],
        p_reason: v["p_reason"],
        p_classification: v["p_classification"],
        p_batch_ids: String(v["p_batch_ids"] ?? "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      }),
    },
    {
      label: "Log a recall action",
      permission: "quality.recall",
      fn: "erp_log_recall_action",
      fields: [
        pickFrom("erp_recalls", "recall_id", ["title", "status"], "p_recall_id", "Recall"),
        { kind: "text", name: "p_action_kind", label: "Action", required: true },
        { kind: "number", name: "p_quantity_recovered", label: "Quantity recovered" },
        { kind: "text", name: "p_note", label: "Note" },
      ],
      invalidates: ["erp_recalls"],
    },
    {
      label: "Close a quality event",
      permission: "quality.disposition",
      fn: "erp_close_quality_event",
      fields: [
        pickFrom(
          "erp_quality_events",
          "quality_event_id",
          ["title", "status"],
          "p_event_id",
          "Event",
        ),
        { kind: "text", name: "p_root_cause", label: "Root cause", required: true },
        { kind: "text", name: "p_corrective_action", label: "Corrective action", required: true },
        { kind: "text", name: "p_preventive_action", label: "Preventive action", required: true },
      ],
      invalidates: ["erp_quality_events", "erp_open_quality_events"],
    },
  ],

  kpis: [
    {
      label: "Open events",
      fn: "erp_quality_events",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => !isOneOf(r["status"], ["closed", "completed"])),
          "non-conformances and complaints",
        ),
    },
    {
      label: "Critical",
      fn: "erp_quality_events",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => isOneOf(r["severity"], ["critical", "major", "high"])),
          "by severity",
        ),
    },
    {
      label: "Active recalls",
      fn: "erp_recalls",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => !isOneOf(r["status"], ["closed", "completed"])),
          "against a regulatory clock",
        ),
    },
    {
      label: "Qualified suppliers",
      fn: "erp_supplier_qualification",
      compute: (rows) => ({
        value: String(
          count(rows, (r) => isOneOf(r["status"], ["approved", "active", "qualified"])),
        ),
        hint: `of ${rows.length} assessed`,
      }),
    },
  ],
  chart: {
    title: "Events by kind",
    description: "What is being raised against quality.",
    fn: "erp_quality_events",
    empty: "No quality events to profile.",
    label: (r) => String(r["event_kind"] ?? "—"),
    value: () => 1,
  },
  worklists: [
    {
      title: "Quality events",
      description: "Non-conformance, complaint, deviation and their investigations.",
      fn: "erp_quality_events",
      empty: "No quality events open.",
      rowKey: (r, i) => String(r["event_id"] ?? i),
      columns: [
        { header: "Reference", cell: "reference" },
        { header: "Kind", cell: "event_kind" },
        { header: "Severity", cell: (r) => <StatusPill value={r["severity"]} /> },
        { header: "Title", cell: "title" },
        { header: "Item", cell: "item" },
        date("Due", "due_at"),
        pill("status"),
      ],
    },
    {
      title: "Recalls",
      description: "Scope, clock and progress. The deadline is a configured regulatory clock.",
      fn: "erp_recalls",
      empty: "No recalls. This is the panel you want to stay empty.",
      rowKey: (r, i) => String(r["recall_id"] ?? i),
      columns: [
        { header: "Reference", cell: "reference" },
        { header: "Title", cell: "title" },
        { header: "Class", cell: "classification" },
        date("Initiated", "initiated_at"),
        date("Deadline", "regulatory_deadline"),
        pill("status"),
      ],
    },
  ],
  reports: [
    {
      title: "Supplier qualification",
      description: "Who is approved to supply what, and until when.",
      fn: "erp_supplier_qualification",
      empty: "No supplier qualifications recorded.",
      rowKey: (r, i) => `${String(r["party"] ?? i)}-${i}`,
      columns: [
        { header: "Supplier", cell: "party" },
        date("Qualified", "qualified_at"),
        date("Valid to", "valid_to"),
        pill("status"),
      ],
    },
  ],
};

export const LOGISTICS: ModuleDef = {
  key: "logistics",
  path: "/logistics",
  titleKey: "module.logistics",
  title: "Logistics",
  blurb: "Shipments, carrier bookings and delivery performance, with cost landing on stock.",
  permission: "logistics.read",
  group: "move",
  actions: [
    {
      label: "Plan a shipment",
      description: "Group deliveries leaving one site on one day.",
      permission: "logistics.plan",
      fn: "erp_plan_shipment",
      fields: [
        pickSite(),
        {
          kind: "text",
          name: "p_delivery_ids",
          label: "Delivery ids",
          required: true,
          hint: "Comma separated.",
        },
        { kind: "date", name: "p_planned_despatch", label: "Planned despatch", required: true },
      ],
      invalidates: ["erp_shipments", "erp_open_shipments"],
      mapArgs: (v) => ({
        p_site_id: v["p_site_id"],
        p_planned_despatch: v["p_planned_despatch"],
        p_delivery_ids: String(v["p_delivery_ids"] ?? "")
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean),
      }),
    },
    {
      label: "Select a carrier",
      permission: "logistics.plan",
      fn: "erp_select_carrier",
      fields: [
        pickFrom(
          "erp_shipments",
          "shipment_id",
          ["reference", "status"],
          "p_shipment_id",
          "Shipment",
        ),
        { kind: "date", name: "p_required_by", label: "Required by", required: false },
      ],
      invalidates: ["erp_shipments", "erp_open_shipments"],
    },
    {
      label: "Book a shipment",
      permission: "logistics.despatch",
      fn: "erp_book_shipment",
      fields: [
        pickFrom(
          "erp_shipments",
          "shipment_id",
          ["reference", "status"],
          "p_shipment_id",
          "Shipment",
        ),
        { kind: "text", name: "p_carrier_code", label: "Carrier code", required: true },
        { kind: "text", name: "p_service_code", label: "Service code", required: true },
        {
          kind: "number",
          name: "p_cost_minor",
          label: "Cost",
          required: true,
          hint: "In minor units — pence, cents.",
        },
      ],
      invalidates: ["erp_shipments", "erp_open_shipments", "erp_delivery_performance"],
    },
    {
      label: "Record proof of delivery",
      permission: "logistics.despatch",
      fn: "erp_record_proof_of_delivery",
      fields: [
        pickFrom(
          "erp_shipments",
          "shipment_id",
          ["reference", "status"],
          "p_shipment_id",
          "Shipment",
        ),
        { kind: "date", name: "p_arrived_at", label: "Arrived on", required: true },
        { kind: "text", name: "p_signed_by", label: "Signed by", required: true },
        { kind: "text", name: "p_reference", label: "Reference", required: false },
      ],

      invalidates: ["erp_shipments", "erp_delivery_performance"],
    },
  ],

  kpis: [
    {
      label: "Open shipments",
      fn: "erp_shipments",
      compute: (rows) => ({
        value: String(count(rows, (r) => !isOneOf(r["status"], ["delivered", "closed"]))),
        hint: `of ${rows.length} planned`,
      }),
    },
    {
      label: "Awaiting despatch",
      fn: "erp_shipments",
      compute: (rows) =>
        zeroIsGood(
          count(rows, (r) => !r["actual_despatch"]),
          "not yet left site",
        ),
    },
    {
      label: "OTIF",
      fn: "erp_delivery_performance",
      args: { p_days: 90 },
      compute: (rows) => {
        if (rows.length === 0) return null;
        const pct = Math.round(avg(rows, "otif_pct"));
        return {
          value: `${pct}%`,
          hint: "on time in full, ninety days",
          tone: pct >= 95 ? "ok" : pct >= 85 ? "warn" : "bad",
        };
      },
    },
    {
      label: "Deliveries",
      fn: "erp_delivery_performance",
      args: { p_days: 90 },
      compute: (rows) =>
        rows.length === 0
          ? null
          : { value: String(sum(rows, "deliveries")), hint: "in the last ninety days" },
    },
  ],
  chart: {
    title: "OTIF by customer",
    description: "On time in full, last ninety days.",
    fn: "erp_delivery_performance",
    args: { p_days: 90 },
    empty: "No deliveries in the window.",
    label: (r) => String(r["party"] ?? r["site"] ?? "—"),
    value: (r) => num(r["otif_pct"]),
    unit: "%",
  },
  worklists: [
    {
      title: "Shipments",
      description: "Planned and despatched loads.",
      fn: "erp_shipments",
      empty: "No shipments planned.",
      rowKey: (r, i) => String(r["shipment_id"] ?? i),
      columns: [
        { header: "Reference", cell: "reference" },
        { header: "Carrier", cell: "carrier" },
        { header: "Service", cell: "service_code" },
        date("Planned", "planned_despatch"),
        date("Actual", "actual_despatch"),
        { header: "Tracking", cell: "tracking_reference" },
        pill("status"),
      ],
    },
  ],
  reports: [
    {
      title: "Delivery performance",
      description: "On time, in full, over the last ninety days.",
      fn: "erp_delivery_performance",
      args: { p_days: 90 },
      empty: "No deliveries in the window.",
      rowKey: (r, i) => `${String(r["party"] ?? r["site"] ?? i)}-${i}`,
      columns: [
        { header: "Customer", cell: "party" },
        { header: "Deliveries", cell: "deliveries", numeric: true },
        { header: "On time", cell: "on_time", numeric: true },
        { header: "In full", cell: "in_full", numeric: true },
        { header: "OTIF %", cell: "otif_pct", numeric: true },
      ],
    },
  ],
};

export const REPORTING: ModuleDef = {
  key: "reporting",
  path: "/reporting",
  titleKey: "module.reporting",
  title: "Reporting",
  blurb: "Data quality, duplicates and specification coverage, read from operational tables.",
  permission: "reporting.read",
  group: "govern",
  kpis: [
    {
      label: "Party data quality",
      fn: "erp_data_quality",
      args: { p_object_type: "party" },
      compute: (rows) => {
        if (rows.length === 0) return null;
        const pct = Math.round(avg(rows, "score"));
        return {
          value: `${pct}%`,
          hint: "average party record score",
          tone: pct >= 95 ? "ok" : pct >= 80 ? "warn" : "bad",
        };
      },
    },
    {
      label: "Records with errors",
      fn: "erp_data_quality",
      args: { p_object_type: "party" },
      compute: (rows) =>
        zeroIsGood(rows.filter((r) => num(r["errors"]) > 0).length, "parties failing a rule"),
    },

    {
      label: "Duplicate candidates",
      fn: "erp_duplicate_candidates",
      args: { p_object_type: "party" },
      compute: (rows) => zeroIsGood(rows.length, "parties likely to be the same"),
    },
    {
      label: "Specification coverage",
      fn: "erp_part5_summary",
      compute: (rows) => {
        if (rows.length === 0) return null;
        const pct = Math.round(avg(rows, "coverage_pct"));
        return { value: `${pct}%`, hint: "of Part 5, measured", tone: pct >= 90 ? "ok" : "warn" };
      },
    },
  ],
  chart: {
    title: "Coverage by section",
    description: "Part 5 of the foundation specification, measured against the database.",
    fn: "erp_part5_summary",
    empty: "Coverage could not be measured.",
    label: (r) => String(r["section"] ?? "—"),
    value: (r) => num(r["coverage_pct"]),
    unit: "%",
  },
  worklists: [
    {
      title: "Duplicate candidates",
      description: "Likely duplicate parties, for merge with a survivor and a reason.",
      fn: "erp_duplicate_candidates",
      args: { p_object_type: "party" },
      empty: "No likely duplicates.",
      rowKey: (r, i) => `${String(r["left_code"] ?? i)}-${String(r["right_code"] ?? i)}`,
      columns: [
        { header: "Record", cell: "left_code" },
        { header: "Candidate", cell: "right_code" },
        { header: "Score", cell: "similarity", numeric: true },
        { header: "Basis", cell: "basis" },
      ],
    },
  ],
  reports: [
    {
      title: "Party data quality",
      description: "Completeness and validity of party master records.",
      fn: "erp_data_quality",
      args: { p_object_type: "party" },
      empty: "No party master data to assess yet.",
      rowKey: (r, i) => `${String(r["object_id"] ?? i)}`,
      columns: [
        { header: "Code", cell: "code" },
        { header: "Name", cell: "name" },
        { header: "Score", cell: "score", numeric: true },
        { header: "Errors", cell: "errors", numeric: true },
        { header: "Warnings", cell: "warnings", numeric: true },
      ],
    },

    {
      title: "Specification coverage",
      description: "Part 5, section by section, measured against the database.",
      fn: "erp_part5_summary",
      empty: "Coverage could not be measured.",
      rowKey: (r, i) => `${String(r["section"] ?? i)}-${i}`,
      columns: [
        { header: "Section", cell: "section" },
        { header: "Title", cell: "title" },
        { header: "Present", cell: "present", numeric: true },
        { header: "Expected", cell: "expected", numeric: true },
        { header: "Coverage %", cell: "coverage_pct", numeric: true },
        { header: "State", cell: (r) => <StatusPill value={r["state"]} /> },
      ],
    },
  ],
};

/** Every module that renders from the registry. */
export const MODULES: ModuleDef[] = [
  INVENTORY,
  PRODUCTION,
  PLANNING,
  QUALITY,
  LOGISTICS,
  FINANCE,
  REPORTING,
];

export function moduleByKey(key: string): ModuleDef | undefined {
  return MODULES.find((m) => m.key === key);
}

/**
 * The screens that are not registry-driven, so the launchpad can still offer
 * them beside the ones that are. They have bespoke interactions — dialogs,
 * approvals, editors — and forcing them into a declarative shape would cost
 * more than it saved.
 */
export type TileDef = {
  path: string;
  titleKey: string;
  title: string;
  blurb: string;
  permission?: string;
  group: "plan" | "source" | "make" | "move" | "sell" | "settle" | "govern" | "administer";
};

export const EXTRA_TILES: TileDef[] = [
  {
    path: "/sales",
    titleKey: "nav.sales",
    title: "Sales",
    blurb: "Quotations, orders and deliveries.",
    permission: "sales.read",
    group: "sell",
  },
  {
    path: "/procurement",
    titleKey: "nav.procurement",
    title: "Procurement",
    blurb: "Requisitions, purchase orders and goods receipts.",
    permission: "procurement.read",
    group: "source",
  },
  {
    path: "/master-data",
    titleKey: "nav.master_data",
    title: "Master data",
    blurb: "The items and parties every document depends on.",
    permission: "master_data.read",
    group: "govern",
  },
  {
    path: "/governance",
    titleKey: "nav.governance",
    title: "Change requests",
    blurb: "Proposed master data changes and the approvals on them.",
    permission: "master_data.read",
    group: "govern",
  },
  {
    path: "/master-data/imports",
    titleKey: "nav.imports",
    title: "Imports",
    blurb: "Staged batches, preview, validation, load and rollback.",
    permission: "master_data.import",
    group: "govern",
  },
  {
    path: "/reporting/reproducibility",
    titleKey: "nav.reporting_reproducibility",
    title: "Report versions and runs",
    blurb:
      "Every report version, the governed view it reads, and each run with the parameters it used — so what was shown can be shown again.",
    permission: "reporting.read",
    group: "govern",
  },
  {
    path: "/operations/jobs",
    titleKey: "nav.operations_jobs",
    title: "Scheduled jobs",
    blurb: "What is running, what failed, and what has stopped running.",
    permission: "administration.jobs",
    group: "administer",
  },
  {
    path: "/operations/integrations",
    titleKey: "nav.operations_integrations",
    title: "Integrations",
    blurb: "Outbound gateway health and the queue that needs a decision.",
    permission: "administration.integrate",
    group: "administer",
  },
  {
    path: "/operations/assurance",
    titleKey: "nav.operations_assurance",
    title: "Assurance",
    blurb: "The structural checks the build runs on every push.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/operations/continuity",
    titleKey: "nav.operations_continuity",
    title: "Continuity and incidents",
    blurb:
      "What was promised about staying up, whether a drill has proved it, and what happened when it did not.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/operations/devices",
    titleKey: "nav.operations_devices",
    title: "Devices and scanning",
    blurb:
      "Registered scanners and terminals, what each may do, the rules a scan is judged by, and the actions waiting to be applied.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/operations/cutover",
    titleKey: "nav.operations_cutover",
    title: "Migration and cutover",
    blurb:
      "Opening balances loaded as at a date, whether each load reconciles, the parallel-run figures, and which domains are cut over on that evidence.",
    permission: "master_data.read",
    group: "administer",
  },
  {
    path: "/operations/output",
    titleKey: "nav.operations_output",
    title: "Output and printing",
    blurb:
      "Template versions, printers, every request with its render and delivery, and the addresses mail may not go to.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/administration/erasure",
    titleKey: "nav.administration_erasure",
    title: "Personal data and erasure",
    blurb:
      "Which columns hold a person's data and what erasure does to each; requests to erase a principal or contact, executed by a second person, with the certificate.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/administration/accessibility",
    titleKey: "nav.administration_accessibility",
    title: "Accessibility",
    blurb:
      "The accessibility statement: each WCAG 2.2 criterion, whether the product meets it, how, and the known exceptions.",
    group: "administer",
  },
  {
    path: "/administration/commercial",
    titleKey: "nav.administration_commercial",
    title: "Plan and usage",
    blurb:
      "The plan this organisation is on, what it entitles, how much of each limit is used, and the meters behind the figures.",
    permission: "administration.read",
    group: "administer",
  },
  {
    path: "/administration/configuration",
    titleKey: "nav.administration_configuration",
    title: "Configuration",
    blurb: "Install modules and promote the change sets that put them in force.",
    permission: "administration.configure",
    group: "administer",
  },
  {
    path: "/administration/packs",
    titleKey: "nav.administration_packs",
    title: "Features and content",
    blurb:
      "Switch product features on and off, apply starter content packs, and see what this organisation cannot yet do.",
    permission: "administration.configure",
    group: "administer",
  },
  {
    path: "/administration/onboarding",
    titleKey: "nav.administration_onboarding",
    title: "Onboarding interview",
    blurb:
      "Questions about how this organisation works, turned into a change set per configuration surface.",
    permission: "administration.configure",
    group: "administer",
  },
  {
    path: "/administration/organisation",
    titleKey: "nav.administration_organisation",
    title: "Organisation and approval routing",
    blurb: "Departments, membership, value bands and named approvers — who approves what, and why.",
    permission: "administration.configure",
    group: "administer",
  },
  {
    path: "/master-data/classification",
    titleKey: "nav.master_data_classification",
    title: "Classification and coding",
    blurb:
      "Classification axes and values, code templates composed from them, completeness gaps and divergences.",
    permission: "master_data.write",
    group: "administer",
  },
  {
    path: "/master-data/item-supply",
    titleKey: "nav.master_data_item_supply",
    title: "Item supply",
    blurb: "Default suppliers, preference ranks, sourcing splits and approved-for-use status.",
    permission: "master_data.write",
    group: "administer",
  },
  {
    path: "/logistics/release-areas",
    titleKey: "nav.logistics_release_areas",
    title: "Release areas and waves",
    blurb:
      "Allocated stock scopes, pull and push replenishment, ageing back to bulk, and print gating.",
    permission: "logistics.plan",
    group: "administer",
  },
  {
    path: "/finance/account-determination",
    titleKey: "nav.finance_account_determination",
    title: "Account determination",
    blurb:
      "Posting classes and the matrix that decides the account and analysis — with a gap report and no suspense fallback.",
    permission: "finance.configure",
    group: "administer",
  },
  {
    path: "/administration/permissions",
    titleKey: "nav.administration_permissions",
    title: "Permissions",
    blurb: "Principals, roles, and the grants between them.",
    permission: "administration.roles",
    group: "administer",
  },
  {
    path: "/administration/terminology",
    titleKey: "nav.terminology",
    title: "Terminology",
    blurb: "The wording of every label, per tenant.",
    permission: "administration.configure",
    group: "administer",
  },
  {
    path: "/administration/audit",
    titleKey: "nav.audit",
    title: "Audit log",
    blurb:
      "Who did what, to which object, and when — filterable by action, object, actor and date.",
    permission: "administration.audit_read",
    group: "administer",
  },
  {
    path: "/administration/tenant",
    titleKey: "nav.tenant",
    title: "Organisation lifecycle",
    blurb: "Go-live, export and portability, and deletion that deletes.",
    permission: "administration.configure",
    group: "administer",
  },
];

export const GROUP_LABELS: Record<TileDef["group"], string> = {
  plan: "Plan",
  source: "Source",
  make: "Make",
  move: "Move",
  sell: "Sell",
  settle: "Settle",
  govern: "Govern & assure",
  administer: "Administration",
};

/** The order the journey reads in, followed by the two supporting sections. */
export const GROUP_ORDER: TileDef["group"][] = [
  "plan",
  "source",
  "make",
  "move",
  "sell",
  "settle",
  "govern",
  "administer",
];

/** Registry modules and bespoke screens, as one list of tiles. */
export function allTiles(): TileDef[] {
  const fromModules: TileDef[] = MODULES.map((m) => ({
    path: m.path,
    titleKey: m.titleKey,
    title: m.title,
    blurb: m.blurb,
    ...(m.permission ? { permission: m.permission } : {}),
    group: m.group,
  }));
  return [...fromModules, ...EXTRA_TILES];
}
