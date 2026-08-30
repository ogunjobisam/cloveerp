import type { ReactNode } from "react";

import type { Column } from "../components/erp/auto";
import { StatusPill, shortDate } from "../components/erp/auto";
import {
  pickFrom,
  pickItem,
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
  key: "inventory",
  path: "/inventory",
  titleKey: "module.inventory",
  title: "Inventory",
  blurb: "Stock health, valuation, ageing, expiry and counting, all derived from the ledger.",
  permission: "inventory.read",
  group: "move",
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
  key: "finance",
  path: "/finance",
  titleKey: "module.finance",
  title: "Finance",
  blurb: "Trial balance, periods, receivables, tax and assets, read from the posted ledger.",
  permission: "finance.read",
  group: "settle",
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
  key: "planning",
  path: "/planning",
  titleKey: "module.planning",
  title: "Planning",
  blurb: "Planned orders and the exceptions worth acting on before they become shortages.",
  permission: "planning.read",
  group: "plan",
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
  key: "production",
  path: "/production",
  titleKey: "module.production",
  title: "Production",
  blurb: "Works orders and their progress against plan, quantity by quantity.",
  permission: "production.read",
  group: "make",
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
  key: "quality",
  path: "/quality",
  titleKey: "module.quality",
  title: "Quality and recall",
  blurb: "Events, dispositions, supplier qualification and recall — each with a clock.",
  permission: "quality.read",
  group: "govern",
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
    path: "/administration/configuration",
    titleKey: "nav.administration_configuration",
    title: "Configuration",
    blurb: "Install modules and promote the change sets that put them in force.",
    permission: "administration.configure",
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
    title: "Tenant lifecycle",
    blurb: "Go-live, export and portability, deletion.",
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
