import type { ReactNode } from "react";

import type { Field } from "../components/erp/action";
import type { Column } from "../components/erp/auto";
import { StatusPill, moneyCell, shortDate } from "../components/erp/auto";
import type { InquirySpec } from "../components/erp/inquiry";
import {
  codeField,
  pickBatch,
  pickChangeSet,
  pickCurrency,
  pickFrom,
  pickItem,
  pickLocation,
  pickParty,
  pickSite,
  reason,
  type ActionSpec,
} from "../components/erp/actions-bar";
import type { FlowSpec, StageList } from "../components/erp/process-flow";

/** Works orders, listed the same way at every step of making. */
const WORKS_ORDER_LIST: StageList = {
  fn: "erp_works_orders",
  args: { p_limit: 200 },
  id: "works_order_id",
  title: ["order_number"],
  subtitle: ["item", "site", "quantity"],
  status: "status",
  noun: "works order",
  nounPlural: "works orders",
};

/** Quality events, listed the same way at every step of quality. */
const QUALITY_EVENT_LIST: StageList = {
  fn: "erp_quality_events",
  args: { p_limit: 200 },
  id: "quality_event_id",
  title: ["reference"],
  subtitle: ["title", "kind", "severity"],
  status: "status",
  noun: "event",
  nounPlural: "events",
};

/** Shipments, listed the same way at every step of despatch. */
const SHIPMENT_LIST: StageList = {
  fn: "erp_shipments",
  args: { p_limit: 200 },
  id: "shipment_id",
  title: ["reference"],
  subtitle: ["destination", "carrier"],
  status: "status",
  noun: "shipment",
  nounPlural: "shipments",
};

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
  /**
   * Where the emptiness is fixed, when it is fixed somewhere else.
   *
   * A panel is empty for one of two reasons, and they want opposite treatment.
   * Either nothing is wrong — no recalls, no match exceptions — and the right
   * answer is the sentence alone; or something has not been set up, and the
   * right answer is the sentence and the way to the screen that sets it up.
   * Leaving somebody to find that screen themselves is the specific tax an ERP
   * charges for its own breadth, and it is the one this product exists to not
   * charge.
   */
  emptyAction?: { label: string; to: string };
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

/**
 * Where a screen lives.
 *
 * Two areas, because two different people open the product for two different
 * reasons. Work is the operating flow — plan, source, make, move, sell,
 * settle — and the records it runs on. Settings is everything that shapes the
 * organisation rather than runs it: who is in it, how it is configured, the
 * plumbing underneath, and the assurance over all of it. A person doing the
 * day's work never sees a configuration screen in their way, and an
 * administrator setting the organisation up is not wading through worklists.
 */
export type TileGroup =
  | "plan"
  | "source"
  | "make"
  | "move"
  | "sell"
  | "settle"
  | "records"
  | "organisation"
  | "configure"
  | "operate"
  | "assure";

export type Area = "work" | "settings";

export const WORK_GROUPS: TileGroup[] = [
  "plan",
  "source",
  "make",
  "move",
  "sell",
  "settle",
  "records",
];
export const SETTINGS_GROUPS: TileGroup[] = ["organisation", "configure", "operate", "assure"];

export function areaOf(group: TileGroup): Area {
  return SETTINGS_GROUPS.includes(group) ? "settings" : "work";
}

/** Where an area starts: its home screen. */
export const AREA_HOME: Record<Area, string> = { work: "/", settings: "/settings" };

export type ModuleDef = {
  key: string;
  path: string;
  titleKey: string;
  title: string;
  /** One sentence. Shown on the tile and under the page title. */
  blurb: string;
  permission?: string;
  group: TileGroup;
  kpis: Kpi[];
  chart?: Chart;
  worklists: Panel[];
  reports: Panel[];
  /** The verbs. Rendered as a bar above the tabs; absent when unpermitted. */
  actions?: ActionSpec[];
  /** The chain of steps this module moves work along, drawn across the top. */
  flow?: FlowSpec;
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

/** A yes/no the form sends as a boolean, never as the words. */
const yesNo = (name: string, label: string, hint?: string): Field => ({
  kind: "choice",
  name,
  label,
  required: true,
  boolean: true,
  choices: [
    { value: "false", label: "No" },
    { value: "true", label: "Yes" },
  ],
  ...(hint ? { hint } : {}),
});

/** A company, chosen from the organisation's own. */
const pickEntity = (name = "p_entity_id", label = "Company", required = true): Field => ({
  kind: "select",
  name,
  label,
  required,
  options: { fn: "erp_entities", value: "entity_id", label: ["code", "name"] },
});

/**
 * The form sends every field as text. Most doors take text; some take a JSON
 * object or a number, and this rebuilds the arguments with those parsed, so a
 * door that wants {"demand_multiplier": 2} is not handed the six characters.
 * An empty field is left out, so the door's own default applies.
 */
const argsWith =
  (spec: { json?: string[]; numbers?: string[]; arrays?: string[] }) =>
  (values: Record<string, string>): Record<string, unknown> => {
    const args: Record<string, unknown> = {};
    for (const [name, raw] of Object.entries(values)) {
      if (raw === "") continue;
      if (spec.json?.includes(name)) args[name] = JSON.parse(raw);
      else if (spec.numbers?.includes(name)) args[name] = Number(raw);
      else if (spec.arrays?.includes(name))
        args[name] = raw
          .split(",")
          .map((x) => x.trim())
          .filter(Boolean);
      else args[name] = raw;
    }
    return args;
  };

/** A count, coloured by whether zero is the good answer. */
const zeroIsGood = (n: number, label: string) => ({
  value: String(n),
  hint: label,
  tone: n === 0 ? ("ok" as const) : n > 5 ? ("bad" as const) : ("warn" as const),
});

export const INVENTORY: ModuleDef = {
  flow: {
    title: "Stock, step by step",
    note: "Goods arrive, are put away, are counted, and are corrected or handed on. Each box is where work waits; the button is what moves it.",
    stages: [
      {
        label: "Goods in",
        hint: "Receipts posted against a purchase order. Stock lands in goods-in before it has a home.",
        fedBy: "Receipts appear here once a purchase order is received and posted.",

        typeCode: "goods_receipt",
        partyRole: "provider",
        createFn: "erp_raise_putaway_tasks",
      },
      {
        label: "Put away",
        hint: "A task per pallet, from goods-in to the location it belongs in.",
        fedBy:
          "Work appears here once goods are received into goods-in and put-away tasks are raised.",

        list: {
          fn: "erp_warehouse_tasks",
          args: { p_limit: 200 },
          id: "task_id",
          title: ["item", "kind"],
          subtitle: ["from_location", "to_location", "quantity"],
          status: "status",
          noun: "task",
          nounPlural: "tasks",
        },
        recordArg: "p_task_id",
        actionFn: "erp_complete_warehouse_task",
      },
      {
        label: "Count",
        hint: "Counting a location, recording what was found, and posting the difference.",
        fedBy: "Counts appear here once count tasks are raised for a site.",

        list: {
          fn: "erp_count_tasks",
          args: { p_limit: 200 },
          id: "task_id",
          title: ["item", "location"],
          subtitle: ["expected", "counted", "variance"],
          status: "status",
          noun: "count",
          nounPlural: "counts",
        },
        recordArg: "p_task_id",
        actionFn: "erp_record_count",
        actionFns: ["erp_post_count"],
      },
      {
        label: "Correct",
        hint: "What the count found, or damage: a write-off leaves a movement and a reason.",
        createFn: "erp_write_off_stock",
      },
      {
        label: "Hand on",
        hint: "Stock that leaves your custody without being sold — a keeper, a contract manufacturer.",
        createFn: "erp_hand_over_custody",
      },
    ],
  },
  inquiries: [
    {
      label: "Stock policies",
      description:
        "How a handling unit is identified and counted, by product class, by site or by the step it is built at.",
      permission: "inventory.read",
      fn: "erp_container_identity_policies",
      fields: [],
    },
    {
      label: "Available to promise",
      description: "What can still be committed for one product at one site, on a date.",
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
  title: "Stock",
  blurb: "Stock health, valuation, ageing, expiry and counting, all derived from the ledger.",
  permission: "inventory.read",
  group: "move",
  actions: [
    {
      label: "Consume consigned stock",
      description:
        "Take a supplier's consigned stock into the company's ownership where it stands. Costed at the consigned price and posted against goods received not invoiced, because the supplier will invoice what was used.",
      permission: "inventory.adjust",
      fn: "erp_consume_consignment",
      fields: [
        pickItem(),
        pickSite(),
        pickLocation(),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        pickParty("supplier", "p_supplier_party_id", "Supplier who owns it", true),
        pickBatch("p_batch_id", "Batch (if controlled)"),
        reason("p_reason", "What it was used for", false),
      ],
      invalidates: ["erp_stock_health", "erp_stock_valuation", "erp_batches"],
    },
    {
      label: "Hand stock to another keeper",
      description:
        "Give stock the company keeps into someone else's keeping — a third-party warehouse, a contract manufacturer — where it stands. The owner and the valuation do not move.",
      permission: "inventory.adjust",
      fn: "erp_hand_over_custody",
      fields: [
        pickItem(),
        pickSite(),
        pickLocation(),
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        pickParty(undefined, "p_keeper_party_id", "Who takes it into their keeping", true),
        pickBatch("p_batch_id", "Batch (if controlled)"),
        reason("p_reason", "Why", false),
      ],
      invalidates: ["erp_stock_health", "erp_count_tasks"],
    },
    {
      label: "Propose an identity policy",
      description:
        "How handling units are identified and counted, for a product class or a site. Proposed as a change, so it is approved and promoted like any other configuration.",
      permission: "administration.configure",
      fn: "erp_propose_identity_policy",
      fields: [
        codeField("p_code", "Code", "PALLET-GS1", {
          fn: "erp_container_identity_policies",
          value: "code",
          label: ["code", "name"],
        }),
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          required: true,
          placeholder: "Pallets identified by licence plate",
        },
        pickItemClass(
          "p_item_class",
          "Product class",
          false,
          "Limits the policy to one class of product. Blank applies it to all.",
        ),
        {
          kind: "select",
          name: "p_site_code",
          label: "Site",
          options: { fn: "erp_sites", value: "code", label: ["code", "name"] },
          hint: "Leave unchosen to apply the policy at every site.",
        },
        {
          kind: "text",
          name: "p_device_task_code",
          label: "Device step",
          placeholder: "Leave blank for all steps",
          hint: "Limits the policy to one handheld step, such as picking or goods-in.",
        },
        {
          kind: "choice",
          name: "p_identity_level",
          label: "Identified at",
          required: true,
          choices: ["none", "unit", "case", "carton", "pallet", "master_pallet"].map((v) => ({
            value: v,
            label: v,
          })),
        },
        {
          kind: "choice",
          name: "p_count_method",
          label: "Counted",
          required: true,
          choices: [
            { value: "by_unit", label: "By unit" },
            { value: "by_container", label: "By container" },
            { value: "hybrid", label: "By container where one exists, else by unit" },
          ],
        },
        { kind: "date", name: "p_effective_from", label: "In force from" },
        {
          ...pickChangeSet("p_change_set_id", "Add to change set", false),
          hint: "Leave unchosen to start a new change set for this proposal.",
        },
      ],
      invalidates: ["erp_container_identity_policies", "erp_change_sets"],
    },
    {
      label: "Propose how stock is chosen",
      description:
        "The allocation policy for a company or one of its sites: which stock a promise takes first. Proposed as a change like any other configuration.",
      permission: "administration.configure",
      fn: "erp_propose_allocation_policy",
      mapArgs: argsWith({ json: ["p_value"] }),
      fields: [
        {
          kind: "select",
          name: "p_entity_code",
          label: "Company",
          required: true,
          options: { fn: "erp_entities", value: "code", label: ["code", "name"] },
        },
        {
          kind: "select",
          name: "p_site_code",
          label: "Site",
          options: { fn: "erp_sites", value: "code", label: ["code", "name"] },
          hint: "Leave unchosen to apply the policy across the whole company.",
        },
        {
          kind: "text",
          name: "p_value",
          label: 'The policy, as configuration — {"default": "fifo"}',
          required: true,
        },
        {
          ...pickChangeSet("p_change_set_id", "Add to change set", false),
          hint: "Leave unchosen to start a new change set for this proposal.",
        },
      ],
      invalidates: ["erp_change_sets"],
    },
    {
      label: "Commit an allocation",
      description:
        "Turn a reservation into a pick from one location and batch, under the site's allocation policy.",
      fn: "erp_commit_allocation",
      fields: [
        {
          kind: "text",
          name: "p_allocation_id",
          label: "Allocation id",
          required: true,
          hint: "The reservation the sales line holds; leave location and batch empty to let the policy choose.",
        },
        pickLocation("p_location_id", "Location", false),
        pickBatch("p_batch_id", "Batch", false),
      ],
      invalidates: ["erp_stock_health", "erp_release_sequence"],
    },
    {
      label: "Amend a batch",
      description: "Change one controlled field of a batch. The old value and the reason are kept.",
      fn: "erp_amend_batch",
      fields: [
        pickBatch("p_batch_id", "Batch", true),
        {
          kind: "choice",
          name: "p_field",
          label: "Field",
          required: true,
          choices: [
            { value: "expires_on", label: "Expiry date" },
            { value: "retest_on", label: "Retest date" },
            { value: "best_before_on", label: "Best before" },
            { value: "status", label: "Status" },
            { value: "supplier_lot", label: "Supplier lot" },
            { value: "origin_country", label: "Country of origin" },
          ],
        },
        {
          kind: "text",
          name: "p_value",
          label: "New value",
          required: true,
          hint: "A date as YYYY-MM-DD; a status as its code.",
        },
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_batches", "erp_expiry_horizon"],
    },
    {
      label: "Create a batch",
      description: "A batch of a product, with the dates the label carries.",
      fn: "erp_create_batch",
      fields: [
        pickItem(),
        {
          kind: "text",
          name: "p_batch_number",
          label: "Batch number",
          required: true,
          placeholder: "B-2026-0142",
          hint: "The number written on the goods, or the one you are giving them now.",
        },
        { kind: "date", name: "p_expires_on", label: "Expires on" },
        { kind: "date", name: "p_manufactured_on", label: "Manufactured on" },
        pickParty("supplier", "p_supplier_party_id", "Supplier", false),
      ],
      invalidates: ["erp_batches"],
    },
    {
      label: "Build a handling unit",
      description: "A case, carton or pallet at a location, within the site's identity policy.",
      fn: "erp_create_handling_unit",
      fields: [
        pickSite(),
        pickLocation("p_location_id", "Location", true),
        {
          kind: "choice",
          name: "p_container_type",
          label: "Kind",
          required: true,
          choices: [
            { value: "case", label: "Case" },
            { value: "carton", label: "Carton" },
            { value: "pallet", label: "Pallet" },
            { value: "master_pallet", label: "Master pallet" },
          ],
        },
        {
          kind: "text",
          name: "p_parent_container_id",
          label: "Inside handling unit",
          hint: "The id of the coarser unit this one goes into, if any.",
        },
        { kind: "text", name: "p_code", label: "Code", hint: "Left empty, one is generated." },
        {
          kind: "select",
          name: "p_item_id",
          label: "Product",
          required: false,
          options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
        },
      ],
      invalidates: ["erp_stock_health"],
    },
    {
      label: "Set product controls",
      description:
        "Batch and serial control, shelf life and quarantine on receipt, for one product.",
      permission: "master_data.write",
      fn: "erp_set_item_controls",
      fields: [
        pickItem(),
        yesNo("p_is_batch_controlled", "Batch controlled"),
        yesNo("p_has_expiry", "Has an expiry date"),
        { kind: "number", name: "p_shelf_life_days", label: "Shelf life (days)" },
        {
          kind: "number",
          name: "p_min_remaining_shelf_life_days",
          label: "Minimum remaining shelf life (days)",
        },
        yesNo("p_quarantine_on_receipt", "Quarantine on receipt"),
        yesNo("p_is_serial_controlled", "Serial controlled"),
      ],
      invalidates: ["erp_items"],
    },
    {
      label: "Set a standard cost",
      description: "The standard a product is valued at, at one site, under standard costing.",
      fn: "erp_set_standard_cost",
      fields: [
        pickItem(),
        pickSite(),
        {
          kind: "money",
          name: "p_unit_cost_minor",
          label: "Unit cost",
          currency: "GBP",
          required: true,
        },
        pickCurrency(),
      ],
      invalidates: ["erp_stock_valuation"],
    },
    {
      label: "Raise count tasks",
      description: "Ask a counting programme for its next set of tasks.",
      permission: "inventory.count",
      fn: "erp_raise_count_tasks",
      fields: [codeField("p_programme_code", "Programme", "COUNT-A")],
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
        pickBatch("p_batch_id", "Batch (if controlled)"),
        // Blank means the company's own stock. A supplier's consigned position
        // is written off as the supplier's: no cost, no journal.
        pickParty(undefined, "p_owner_party_id", "Owner (blank for the company)", false),
      ],
      invalidates: ["erp_stock_health", "erp_stock_valuation", "erp_stock_ageing", "erp_batches"],
    },
    {
      label: "Split a batch",
      permission: "inventory.adjust",
      fn: "erp_split_batch",
      fields: [
        pickFrom("erp_batches", "batch_id", ["batch_number", "item"], "p_batch_id", "Batch"),
        {
          kind: "text",
          name: "p_new_number",
          label: "New batch number",
          required: true,
          placeholder: "B-2026-0142A",
          hint: "What the batch should be called from now on.",
        },
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
        {
          kind: "text",
          name: "p_basis",
          label: "Basis",
          required: true,
          placeholder: "Certificate of analysis 4471 reviewed",
          hint: "What you relied on to decide.",
        },
        {
          kind: "text",
          name: "p_signature",
          label: "Signature",
          required: true,
          placeholder: "Your full name",
          hint: "Typed in full. It is kept against the release.",
        },
      ],
      invalidates: ["erp_batches", "erp_stock_health"],
    },
    {
      label: "Merge two batches",
      description: "Combine one batch into another of the same product and condition.",
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
      description:
        "Ask the warehouse to move what is standing in goods-in. A task is raised for each pallet sitting in a receiving location at that site; if nothing is standing there, nothing is raised.",
      permission: "inventory.adjust",
      fields: [pickSite()],
      fn: "erp_raise_putaway_tasks",
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
      description: "Adopt the stocking policy the engine calculates for one product and site.",
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
      compute: (rows) => ({ value: String(rows.length), hint: "product and site positions" }),
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
    empty:
      "No aged stock to profile. Stock is banded by age here once anything has been on hand long enough to band.",
    label: (r) => String(r["age_band"] ?? "—"),
    value: (r) => num(r["quantity"]),
  },
  worklists: [
    {
      title: "Count tasks",
      description: "Raised by the counting programme and waiting on a person.",
      fn: "erp_count_tasks",
      empty:
        "No count tasks raised. Raise a counting programme under Actions and its tasks appear here.",
      rowKey: (r, i) => String(r["task_id"] ?? i),
      columns: [
        { header: "Product", cell: "item" },
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
      empty:
        "No warehouse tasks outstanding. Picks, putaways and replenishments are raised by the work, not from this screen.",
      rowKey: (r, i) => String(r["task_id"] ?? i),
      columns: [
        { header: "Kind", cell: "kind" },
        { header: "Product", cell: "item" },
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
      empty:
        "Nothing expires in the next thirty days. Only batch-controlled stock with an expiry date appears here.",
      rowKey: (r, i) => String(r["batch_id"] ?? i),
      columns: [
        { header: "Batch", cell: "batch_number" },
        { header: "Product", cell: "item_code" },
        date("Expires", "expires_on"),
        { header: "Quantity", cell: "quantity", numeric: true },
        { header: "Days left", cell: "days_remaining", numeric: true },
      ],
    },
  ],
  reports: [
    {
      title: "Stock health",
      description: "Cover against policy, by product and site.",
      fn: "erp_stock_health",
      empty:
        "Nothing is on hand yet. Receipting a purchase order is what first puts stock into an organisation.",
      emptyAction: { label: "Open Purchasing", to: "/procurement" },
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["site_code"] ?? i)}`,
      columns: [
        { header: "Product", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "On hand", cell: "on_hand", numeric: true },
        { header: "Available", cell: "available", numeric: true },
        { header: "Allocated", cell: "allocated", numeric: true },
        { header: "Status", cell: (r) => <StatusPill value={r["health"] ?? r["status"]} /> },
      ],
    },
    {
      title: "Valuation",
      description: "Cost basis by product and site, in minor units.",
      fn: "erp_stock_valuation",
      empty: "Nothing to value yet. Stock is valued from the moment it is received.",
      emptyAction: { label: "Open Purchasing", to: "/procurement" },
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["site_code"] ?? i)}`,
      columns: [
        { header: "Product", cell: "item_code" },
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
      empty: "No aged stock. Nothing has been on hand long enough to fall into an age band.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["age_band"] ?? i)}`,
      columns: [
        { header: "Product", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "Band", cell: "age_band" },
        { header: "Quantity", cell: "quantity", numeric: true },
      ],
    },
    {
      title: "Batches",
      description: "Traceable units, with their genealogy anchors.",
      fn: "erp_batches",
      empty:
        "No batches yet. A batch is created when stock of a batch-controlled product is received, so a product has to be marked batch controlled first.",
      emptyAction: { label: "Open Common data", to: "/master-data" },
      rowKey: (r, i) => String(r["batch_id"] ?? i),
      columns: [
        { header: "Batch", cell: "batch_number" },
        { header: "Product", cell: "item" },
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
  flow: {
    title: "Money, step by step",
    note: "Bill what was delivered, take the cash in, pay what is owed out, then close the period.",
    stages: [
      {
        label: "Invoice",
        hint: "The customer's bill, raised from a posted delivery so the quantities are what left.",
        fedBy: "Invoices appear here once a delivery has been despatched and invoiced.",

        typeCode: "sales_invoice",
        partyRole: "customer",
        recordArg: "p_invoice_id",
        createFn: "erp_invoice_from_delivery",
      },
      {
        label: "Cash in",
        hint: "Money received, applied against the invoices it settles.",
        createFn: "erp_apply_cash",
      },
      {
        label: "Payment run",
        hint: "What is due to suppliers, gathered into one proposal.",
        fedBy: "A run appears here once supplier bills are approved and a payment run is proposed.",

        list: {
          fn: "erp_payment_proposals",
          args: { p_limit: 200 },
          id: "proposal_id",
          title: ["reference"],
          subtitle: ["payment_date", "currency"],
          status: "status",
          noun: "payment run",
          nounPlural: "payment runs",
        },
        recordArg: "p_proposal_id",
        createFn: "erp_propose_payment_run",
      },
      {
        label: "Approve",
        hint: "A second pair of eyes. The proposer cannot approve their own run.",
        fedBy: "Runs appear here once one has been proposed at the payment run step.",

        list: {
          fn: "erp_payment_proposals",
          args: { p_limit: 200 },
          id: "proposal_id",
          title: ["reference"],
          subtitle: ["payment_date", "currency"],
          status: "status",
          noun: "payment run",
          nounPlural: "payment runs",
        },
        recordArg: "p_proposal_id",
        actionFn: "erp_approve_payment_run",
      },
      {
        label: "Pay",
        hint: "Paying an approved run clears the payable and credits the bank.",
        fedBy: "Runs appear here once a second approver has approved them.",

        list: {
          fn: "erp_payment_proposals",
          args: { p_limit: 200 },
          id: "proposal_id",
          title: ["reference"],
          subtitle: ["payment_date", "currency"],
          status: "status",
          noun: "payment run",
          nounPlural: "payment runs",
        },
        recordArg: "p_proposal_id",
        actionFn: "erp_pay_payment_run",
      },
      {
        label: "Close",
        hint: "Period close: the task list, then the close itself.",
        createFn: "erp_close_period",
      },
    ],
  },
  inquiries: [
    {
      label: "Consolidated trial balance",
      description:
        "The worksheet for a group: what the companies hold per account, what the group ledger eliminates, and the consolidated figure.",
      permission: "finance.read",
      fn: "erp_consolidated_trial_balance",
      fields: [
        pickEntity("p_parent_entity_id", "Parent company"),
        { kind: "date", name: "p_as_at", label: "As at" },
      ],
    },
    {
      label: "Eliminations",
      description: "What has been eliminated in a group ledger, when, why and by which journal.",
      permission: "finance.read",
      fn: "erp_eliminations",
      fields: [pickEntity("p_parent_entity_id", "Parent company")],
    },
    {
      label: "Settlement statement",
      description:
        "One provider statement line by line: what each line settled, how it was matched, and the candidates for a line nobody could place.",
      permission: "finance.read",
      fn: "erp_settlement_statement",
      fields: [
        pickFrom(
          "erp_settlement_statements",
          "statement_id",
          ["provider", "statement_ref", "status"],
          "p_statement_id",
          "Statement",
        ),
      ],
    },
    {
      label: "Preview a document's dimensions",
      description:
        "What each journal line would be stamped with when this document posts, and whether the combination rules let it through.",
      permission: "finance.read",
      fn: "erp_preview_dimensions",
      fields: [
        pickFrom(
          "erp_documents",
          "document_id",
          ["document_number", "document_type", "state"],
          "p_document_id",
          "Document",
        ),
      ],
    },
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
      fields: [codeField("p_code", "Budget code", "OPEX-2026")],
    },
  ],
  key: "finance",
  path: "/finance",
  titleKey: "module.finance",
  title: "Financials",
  blurb: "Trial balance, periods, receivables, tax and assets, read from the posted ledger.",
  permission: "finance.read",
  group: "settle",
  actions: [
    {
      label: "Add a company to a group",
      description:
        "Puts a subsidiary under its parent, installs the parent's group ledger and promotes the elimination rule.",
      permission: "finance.configure",
      fn: "erp_configure_consolidation",
      fields: [
        pickEntity("p_parent_entity_id", "Parent company"),
        pickEntity("p_member", "Subsidiary"),
      ],
      mapArgs: (v) => ({
        p_parent_entity_id: v["p_parent_entity_id"],
        p_member_entity_ids: [v["p_member"]],
      }),
      invalidates: ["erp_entities", "erp_ledgers"],
    },
    {
      label: "Eliminate intercompany balances",
      description:
        "Posts what the group's companies owe each other into the group ledger as at a date. Refused while any pair disagrees.",
      permission: "finance.post",
      fn: "erp_post_intercompany_elimination",
      fields: [
        pickEntity("p_parent_entity_id", "Parent company"),
        { kind: "date", name: "p_as_at", label: "As at", required: true },
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_trial_balance", "erp_intercompany_position"],
    },
    {
      label: "Set an exchange rate",
      description: "A rate from one currency to another from a date, with where it came from.",
      permission: "finance.configure",
      fn: "erp_set_exchange_rate",
      fields: [
        pickCurrency("p_from", "From currency"),
        pickCurrency("p_to", "To currency"),
        { kind: "number", name: "p_rate", label: "Rate", required: true },
        { kind: "date", name: "p_valid_from", label: "Valid from", required: true },
        {
          kind: "choice",
          name: "p_type",
          label: "Kind of rate",
          required: true,
          choices: [
            { value: "spot", label: "Spot" },
            { value: "average", label: "Average" },
            { value: "closing", label: "Closing" },
          ],
        },
        {
          kind: "text",
          name: "p_source",
          label: "Source",
          required: true,
          hint: "Who published it.",
        },
      ],
      invalidates: ["erp_trial_balance"],
    },
    {
      label: "Reconcile a settlement statement",
      description:
        "Matches each line to an open receivable by the invoice it names, else by an amount only one item has.",
      permission: "finance.post",
      fn: "erp_reconcile_settlement_statement",
      fields: [
        pickFrom(
          "erp_settlement_statements",
          "statement_id",
          ["provider", "statement_ref", "status"],
          "p_statement_id",
          "Statement",
        ),
      ],
      invalidates: ["erp_settlement_statements"],
    },
    {
      label: "Match a settlement line",
      description:
        "A person's match of one line to one open receivable, with a note that says why.",
      permission: "finance.post",
      fn: "erp_match_settlement_line",
      fields: [
        {
          kind: "text",
          name: "p_line_id",
          label: "Statement line id",
          required: true,
          hint: "From the Settlement statement question below.",
        },
        {
          kind: "text",
          name: "p_subledger_item_id",
          label: "Receivable item id",
          required: true,
          hint: "One of the candidates the same question lists.",
        },
        {
          kind: "text",
          name: "p_note",
          label: "Note",
          required: true,
          placeholder: "Why this is being done",
          hint: "Kept with the record for whoever reads it later.",
        },
      ],
      invalidates: ["erp_settlement_statements"],
    },
    {
      label: "Apply a settlement statement",
      description:
        "Settles every matched line's receivable as cash. Refused while a line is unmatched.",
      permission: "finance.post",
      fn: "erp_apply_settlement_statement",
      fields: [
        pickFrom(
          "erp_settlement_statements",
          "statement_id",
          ["provider", "statement_ref", "status"],
          "p_statement_id",
          "Statement",
        ),
      ],
      invalidates: ["erp_settlement_statements", "erp_receivables_ageing", "erp_trial_balance"],
    },
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
        {
          kind: "text",
          name: "p_waiver_reason",
          label: "Waiver reason",
          placeholder: "Why the task is being passed without being done",
          hint: "Only needed when skipping the task rather than completing it.",
        },
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
      invalidates: ["erp_payment_proposals"],
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
      invalidates: ["erp_payment_proposals"],
    },
    {
      label: "Apply cash",
      permission: "finance.post",
      fn: "erp_apply_cash",
      fields: [
        pickParty("customer"),
        // Money is entered the way it is written on the remittance advice.
        // Asking for pence was an invitation to apply a hundredth of the
        // receipt and wonder why the invoice stayed open.
        {
          kind: "money",
          name: "p_amount_minor",
          label: "Amount",
          currency: "GBP",
          required: true,
        },
        {
          kind: "choice",
          name: "p_currency",
          label: "Currency",
          required: true,
          choices: [
            { value: "GBP", label: "GBP — pound sterling" },
            { value: "EUR", label: "EUR — euro" },
            { value: "USD", label: "USD — US dollar" },
          ],
        },
        {
          kind: "text",
          name: "p_reference",
          label: "Reference",
          placeholder: "BACS-001",
          hint: "Your own reference for this, such as the bank payment reference.",
        },
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
          // Only deliveries can be invoiced; offering every document invites
          // the failure rather than preventing it.
          { p_type_code: "delivery", p_limit: 100 },
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
      // Approving a run used to be the end of it: the proposal said approved
      // and nothing left the bank. This is the step that moves the money.
      label: "Pay an approved run",
      permission: "finance.post",
      fn: "erp_pay_payment_run",
      fields: [
        pickFrom(
          "erp_payment_proposals",
          "proposal_id",
          ["reference", "payment_date", "status"],
          "p_proposal_id",
          "Payment proposal",
        ),
      ],
      invalidates: [
        "erp_payment_proposals",
        "erp_supplier_balances",
        "erp_payables_ageing",
        "erp_trial_balance",
        "erp_documents",
      ],
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
    empty:
      "Nothing outstanding to profile. Customer invoices land here as they are posted, banded by how overdue they are.",
    label: (r) => String(r["party"] ?? "—"),
    value: (r) => num(r["total_minor"]) / 100,
  },
  worklists: [
    {
      title: "Supplier balances",
      description:
        "What is owed to each supplier, what is overdue, what has been paid, and what a match exception is holding back.",
      fn: "erp_supplier_balances",
      empty:
        "Nothing is owed to a supplier. Registering a supplier bill puts a balance here; paying an approved run clears it.",
      rowKey: (r, i) => String(r["party_id"] ?? i),
      columns: [
        { header: "Supplier", cell: "party" },
        { header: "Owed", cell: moneyCell("owing_minor"), numeric: true },
        { header: "Overdue", cell: moneyCell("overdue_minor"), numeric: true },
        { header: "Paid", cell: moneyCell("paid_minor"), numeric: true },
        { header: "Held", cell: moneyCell("held_minor"), numeric: true },
        date("Oldest due", "oldest_due_date"),
        { header: "Open bills", cell: "open_documents", numeric: true },
      ],
    },

    {
      title: "Dunning worklist",
      description: "Customers overdue enough to contact.",
      fn: "erp_dunning_worklist",
      empty:
        "Nobody needs chasing. Every customer is inside their terms, or has nothing outstanding at all.",
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
      empty:
        "Nothing received awaiting an invoice. A goods receipt accrues here until the supplier invoice matches it.",
      rowKey: (r, i) => `${String(r["order_line_id"] ?? i)}-${i}`,
      columns: [
        { header: "Order", cell: "order_number" },
        { header: "Supplier", cell: "party_name" },
        { header: "Product", cell: "item_code" },
        { header: "Quantity", cell: "open_quantity", numeric: true },
        { header: "Value", cell: moneyCell("open_value_minor"), numeric: true },
        { header: "Age (days)", cell: "age_days", numeric: true },
      ],
    },
  ],
  reports: [
    {
      title: "Payables ageing",
      description: "What is owed to suppliers, banded by how overdue it is.",
      fn: "erp_payables_ageing",
      empty:
        "Nothing outstanding to suppliers. A registered supplier bill appears here, banded by how close its due date is.",
      rowKey: (r, i) => String(r["party_id"] ?? i),
      columns: [
        { header: "Supplier", cell: "party" },
        { header: "Currency", cell: "currency" },
        { header: "Not due", cell: moneyCell("not_due_minor"), numeric: true },
        { header: "1–30", cell: moneyCell("days_1_30_minor"), numeric: true },
        { header: "31–60", cell: moneyCell("days_31_60_minor"), numeric: true },
        { header: "61–90", cell: moneyCell("days_61_90_minor"), numeric: true },
        { header: "90+", cell: moneyCell("days_90_plus_minor"), numeric: true },
        { header: "Total", cell: moneyCell("total_minor"), numeric: true },
      ],
    },

    {
      title: "Slow-moving stock provision",
      description:
        "One published policy: nothing under ninety days, a quarter to six months, half to a year, all of it beyond.",
      fn: "erp_stock_provision",
      empty:
        "Nothing is old enough to provide against. Stock appears here once it has passed the slow-moving threshold this organisation set.",
      rowKey: (r, i) => `${String(r["item_code"] ?? i)}-${String(r["bucket"] ?? i)}`,
      columns: [
        { header: "Product", cell: "item_code" },
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
      description: "Every nominal account with a movement, by ledger.",
      fn: "erp_trial_balance",
      empty: "Nothing posted yet. A trial balance is built from documents that have been posted.",
      rowKey: (r, i) => `${String(r["ledger"] ?? i)}-${String(r["account"] ?? i)}`,
      columns: [
        { header: "Ledger", cell: "ledger" },
        { header: "Nominal account", cell: "account" },
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
      empty: "Nothing outstanding. Every customer invoice posted so far has been settled.",
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
      empty:
        "No taxable transactions in this period. Change the period, or post a document that carries tax.",
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
      empty: "No fixed assets recorded. An asset is capitalised from a posted purchase invoice.",
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
      title: "Settlement statements",
      description:
        "Provider statements imported, reconciled and applied, with what is still unmatched.",
      fn: "erp_settlement_statements",
      empty:
        "No settlement statement imported. Stage one on the Imports screen as a settlement_statement batch and load it.",
      emptyAction: { label: "Open Imports", to: "/master-data/imports" },
      rowKey: (r, i) => String(r["statement_id"] ?? i),
      columns: [
        { header: "Provider", cell: "provider" },
        { header: "Statement", cell: "statement_ref" },
        date("Date", "statement_date"),
        { header: "Gross", cell: "gross_minor", numeric: true },
        { header: "Fees", cell: "fee_minor", numeric: true },
        { header: "Net", cell: "net_minor", numeric: true },
        { header: "Lines", cell: "lines", numeric: true },
        { header: "Unmatched", cell: "unmatched", numeric: true },
        pill("status"),
      ],
    },
    {
      title: "Intercompany position",
      description: "What each company owes another, before elimination.",
      fn: "erp_intercompany_position",
      empty:
        "No intercompany balances. This appears once two companies in the organisation trade with each other.",
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
      description: "The books this organisation keeps.",
      fn: "erp_ledgers",
      empty: "No ledger configured. Installing Financials is what creates one.",
      emptyAction: { label: "Open Configuration", to: "/administration/configuration" },
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
      empty:
        "No fiscal calendar yet. Installing Financials creates one, and nothing can be posted to a period until it exists.",
      emptyAction: { label: "Open Configuration", to: "/administration/configuration" },
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
  flow: {
    title: "Plan, step by step",
    note: "Forecast the demand, sign it off, run the requirements, then firm what the run suggests.",
    stages: [
      {
        label: "Forecast",
        hint: "Demand per period, from history and from what you know that history does not.",
        fedBy: "Forecasts appear here once one has been run for a period.",

        list: {
          fn: "erp_forecast_versions",
          args: { p_limit: 200 },
          id: "version_id",
          title: ["code", "version"],
          subtitle: ["name", "method"],
          status: "status",
          noun: "forecast",
          nounPlural: "forecasts",
        },
        createFn: "erp_run_forecast",
      },
      {
        label: "Sign off",
        hint: "A forecast nobody has agreed to is a spreadsheet. Signing it off is what plans use it.",
        fedBy: "Forecasts appear here once one has been run at the forecast step.",

        list: {
          fn: "erp_forecast_versions",
          args: { p_limit: 200 },
          id: "version_id",
          title: ["code", "version"],
          subtitle: ["name", "method"],
          status: "status",
          noun: "forecast",
          nounPlural: "forecasts",
        },
        recordArg: "p_version_id",
        actionFn: "erp_sign_off_forecast",
      },
      {
        label: "Requirements run",
        hint: "Demand against supply, netted, exploded through the bills of material.",
        createFn: "erp_run_planning",
      },
      {
        label: "Planned order",
        hint: "What the run says to buy or make, before anyone has committed to it.",
        fedBy: "Orders appear here once a requirements run has been made.",

        list: {
          fn: "erp_planned_orders",
          args: { p_limit: 200 },
          id: "planned_order_id",
          title: ["item", "kind"],
          subtitle: ["site", "quantity", "required_by"],
          status: "status",
          noun: "planned order",
          nounPlural: "planned orders",
        },
        recordArg: "p_planned_order_id",
        actionFn: "erp_firm_planned_order",
      },

      {
        label: "Firm",
        hint: "A firmed order becomes a purchase order or a works order and leaves planning.",
        to: "/procurement",
        toLabel: "Open purchasing",
      },
    ],
  },
  inquiries: [
    {
      label: "Supply and demand",
      description: "The projected balance for one product and site across the horizon.",
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
      description: "What the engine would set for one product and site, before adopting it.",
      permission: "planning.read",
      fn: "erp_calculate_policy",
      fields: [pickItem(), pickSite()],
    },
    {
      label: "Why this planned order",
      description:
        "The demand behind a planned order, and the component orders it caused: forecast, sales order or a parent order above it.",
      permission: "planning.read",
      fn: "erp_planned_order_pegging",
      fields: [
        pickFrom(
          "erp_planned_orders",
          "planned_order_id",
          ["item", "kind", "quantity", "required_by"],
          "p_planned_order_id",
          "Planned order",
        ),
      ],
    },
    {
      label: "Dependent demand of a run",
      description: "What the production orders a run raised ask of their components, by date.",
      permission: "planning.read",
      fn: "erp_dependent_demand",
      fields: [
        pickFrom(
          "erp_planning_runs",
          "run_id",
          ["site_code", "started_at", "scenario_code"],
          "p_planning_run_id",
          "Planning run",
        ),
      ],
    },
    {
      label: "Compare two runs",
      description:
        "Per product, what each run planned and the difference — a baseline against a scenario, or two baselines.",
      permission: "planning.read",
      fn: "erp_compare_planning_runs",
      fields: [
        pickFrom(
          "erp_planning_runs",
          "run_id",
          ["site_code", "started_at", "scenario_code"],
          "p_run_a",
          "First run",
        ),
        pickFrom(
          "erp_planning_runs",
          "run_id",
          ["site_code", "started_at", "scenario_code"],
          "p_run_b",
          "Second run",
        ),
      ],
    },
    {
      label: "Forecast lines",
      description:
        "Every bucket of one forecast version, with the statistical figure beside any adjustment.",
      permission: "planning.read",
      fn: "erp_forecast_lines",
      fields: [
        pickFrom(
          "erp_forecast_versions",
          "version_id",
          ["forecast", "version", "status"],
          "p_version_id",
          "Forecast version",
        ),
      ],
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
      invalidates: ["erp_planned_orders", "erp_planner_workbench", "erp_planning_runs"],
    },
    {
      label: "Run a scenario",
      description:
        "Plan one site under assumptions, beside the baseline. A scenario's orders are never supply and cannot be firmed; compare it with the baseline instead.",
      permission: "planning.run",
      fn: "erp_run_planning",
      fields: [
        pickSite(),
        { kind: "number", name: "p_horizon_days", label: "Horizon (days)", hint: "Default 180." },
        codeField("p_scenario_code", "Scenario", "BASE-2026"),
        {
          kind: "text",
          name: "p_assumptions",
          label: "Assumptions",
          hint: 'JSON: demand_multiplier, lead_time_days_delta, reorder_point_multiplier — for example {"demand_multiplier": 1.5}.',
        },
        {
          kind: "text",
          name: "p_label",
          label: "Label",
          placeholder: "Autumn plan",
          hint: "A short name so you can recognise this later.",
        },
      ],
      mapArgs: argsWith({ json: ["p_assumptions"], numbers: ["p_horizon_days"] }),
      invalidates: ["erp_planning_runs"],
    },
    {
      label: "Firm a planned order",
      description:
        "A bought item becomes a purchase order of the type you name; a made item becomes a works order.",
      permission: "planning.firm",
      fn: "erp_firm_planned_order",
      fields: [
        pickFrom(
          "erp_planned_orders",
          "planned_order_id",
          ["item", "kind", "quantity", "required_by"],
          "p_planned_order_id",
          "Planned order",
        ),
        {
          kind: "text",
          name: "p_document_type_code",
          label: "Purchase order type",
          hint: "For a bought item, for example purchase_order. Leave empty for a made item.",
        },
      ],
      invalidates: ["erp_planned_orders", "erp_documents", "erp_works_orders"],
    },
    {
      label: "Adjust a forecast bucket",
      description: "Change one bucket of a draft forecast. The statistical figure stays beside it.",
      permission: "planning.forecast",
      fn: "erp_adjust_forecast_line",
      fields: [
        {
          kind: "text",
          name: "p_line_id",
          label: "Forecast line id",
          required: true,
          hint: "From the Forecast lines question below.",
        },
        { kind: "number", name: "p_quantity", label: "Quantity", required: true },
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_forecast_lines"],
    },
    {
      label: "Record a forecast event",
      description:
        "A promotion, a launch or a closure the statistics cannot know about: a window and a multiplier the next run applies.",
      permission: "planning.forecast",
      fn: "erp_upsert_forecast_event",
      fields: [
        codeField("p_code", "Event code", "PROMO-EASTER"),
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          required: true,
          placeholder: "Easter promotion",
        },
        { kind: "date", name: "p_starts_on", label: "Starts on", required: true },
        { kind: "date", name: "p_ends_on", label: "Ends on", required: true },
        {
          kind: "number",
          name: "p_multiplier",
          label: "Multiplier",
          required: true,
          hint: "2 doubles demand in the window; 0.5 halves it.",
        },
        reason("p_reason", "Reason", true),
        pickSite("p_site_id", "Site", false),
        {
          kind: "select",
          name: "p_item_id",
          label: "Product",
          required: false,
          options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
        },
      ],
      invalidates: ["erp_forecast_events"],
    },
    {
      label: "Run a forecast",
      permission: "planning.forecast",
      fn: "erp_run_forecast",
      fields: [
        codeField("p_forecast_code", "Forecast", "FCST-2026H1", {
          fn: "erp_forecast_versions",
          value: "code",
          label: ["code", "name"],
        }),
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
        {
          kind: "text",
          name: "p_note",
          label: "Note",
          placeholder: "Anything worth recording",
          hint: "Optional. Kept with the record.",
        },
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
    empty: "No exceptions to profile. The plan is currently consistent with demand and supply.",
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
        { header: "Product", cell: "item" },
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
        { header: "Product", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Kind", cell: "order_kind" },
        { header: "Quantity", cell: "quantity", numeric: true },
        date("Required", "required_by"),
        date("Release", "release_on"),
        { header: "Pegged to", cell: "pegged_to" },
        pill("status"),
      ],
    },
    {
      title: "Planning runs",
      description:
        "Every run kept: baselines, the runs they superseded, and scenarios beside them.",
      fn: "erp_planning_runs",
      empty: "No planning run yet. Run planning for a site and the run is kept here.",
      rowKey: (r, i) => String(r["run_id"] ?? i),
      columns: [
        { header: "Site", cell: "site_code" },
        date("Started", "started_at"),
        { header: "Scenario", cell: "scenario_code" },
        { header: "Label", cell: "label" },
        { header: "Orders", cell: "orders_raised", numeric: true },
        { header: "Exceptions", cell: "exceptions_raised", numeric: true },
        { header: "Current baseline", cell: "is_current_baseline" },
      ],
    },
    {
      title: "Forecast events",
      description: "The windows and multipliers the forecast applies, with their reasons.",
      fn: "erp_forecast_events",
      empty: "No forecast events. Record one when something the statistics cannot know is coming.",
      rowKey: (r, i) => String(r["id"] ?? i),
      columns: [
        { header: "Code", cell: "code" },
        { header: "Name", cell: "name" },
        date("From", "starts_on"),
        date("To", "ends_on"),
        { header: "Multiplier", cell: "multiplier", numeric: true },
        { header: "Product", cell: "item_code" },
        { header: "Site", cell: "site_code" },
        { header: "Reason", cell: "reason" },
        pill("status"),
      ],
    },
  ],
};

export const PRODUCTION: ModuleDef = {
  flow: {
    title: "Making, step by step",
    note: "Raise the order, release it to the floor, issue the components, book the time, receive the output and close it.",
    stages: [
      {
        label: "Works order",
        hint: "What is to be made, how much, and by when.",
        fedBy:
          "Orders appear here once one is raised, or once a planned order is firmed in planning.",

        list: WORKS_ORDER_LIST,
        createFn: "erp_raise_works_order",
      },
      {
        label: "Release",
        hint: "Releasing an order is what makes it work the floor can start.",
        fedBy: "Orders appear here once one has been raised at the works order step.",

        list: WORKS_ORDER_LIST,
        recordArg: "p_works_order_id",
        actionFn: "erp_release_works_order",
      },
      {
        label: "Issue components",
        hint: "Stock leaves the store and joins the order's cost.",
        list: WORKS_ORDER_LIST,
        recordArg: "p_works_order_id",
        actionFn: "erp_issue_to_works_order",
      },
      {
        label: "Book time",
        hint: "Operation time against the route, so the variance means something.",
        list: WORKS_ORDER_LIST,
        recordArg: "p_works_order_id",
        actionFn: "erp_book_operation_time",
      },
      {
        label: "Receive output",
        hint: "Finished quantity, and scrap, back into stock.",
        list: WORKS_ORDER_LIST,
        recordArg: "p_works_order_id",
        actionFn: "erp_receive_works_order_output",
      },
      {
        label: "Close",
        hint: "Closing an order settles its variance and stops further booking.",
        list: WORKS_ORDER_LIST,
        recordArg: "p_works_order_id",
        actionFn: "erp_close_works_order",
      },
    ],
  },
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
  title: "Manufacturing",
  blurb: "Works orders and their progress against plan, quantity by quantity.",
  permission: "production.read",
  group: "make",
  actions: [
    {
      label: "Define a bill of materials",
      permission: "production.order",
      fn: "erp_create_bom",
      fields: [
        pickItem(),
        pickSite("p_site_id", "Site — leave blank for every site", false),
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          placeholder: "Standard recipe",
          hint: "Optional. Useful when a product has more than one way of being made.",
        },
        {
          kind: "number",
          name: "p_output_quantity",
          label: "One run makes",
          hint: "The quantity of the product one run of this bill produces. Usually 1.",
        },
        { kind: "date", name: "p_effective_from", label: "Effective from" },
        {
          kind: "rows",
          name: "p_lines",
          label: "Components",
          addLabel: "Add a component",
          hint: "Everything one run is made of, with the quantity of each it uses.",
          columns: [
            {
              name: "component_item_id",
              label: "Component",
              kind: "select",
              options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
            },
            { name: "quantity", label: "Quantity", kind: "number", placeholder: "2" },
            { name: "scrap_factor", label: "Scrap factor", kind: "number", placeholder: "0" },
          ],
        },
      ],
      invalidates: ["erp_boms", "erp_works_orders"],
    },
    {
      label: "Withdraw a bill of materials",
      permission: "production.order",
      fn: "erp_withdraw_bom",
      fields: [
        pickFrom("erp_boms", "bom_id", ["code", "item", "status"], "p_bom_id", "Bill of materials"),
      ],
      invalidates: ["erp_boms"],
    },
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
      invalidates: ["erp_works_orders"],
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
      invalidates: ["erp_works_orders"],
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
        pickBatch(),
      ],
      invalidates: ["erp_works_orders", "erp_stock_health"],
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
      invalidates: ["erp_works_orders"],
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
        {
          kind: "text",
          name: "p_batch_number",
          label: "Batch number",
          placeholder: "B-2026-0142",
          hint: "Leave blank to let the system number it.",
        },
      ],
      invalidates: ["erp_works_orders", "erp_stock_health"],
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
      invalidates: ["erp_works_orders"],
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
    empty: "No works orders to profile. Raise one under Work and it is counted here by status.",
    label: (r) => String(r["status"] ?? "—"),
    value: () => 1,
  },
  worklists: [
    {
      title: "Bills of materials",
      description: "What each made product is made of, version by version.",
      fn: "erp_boms",
      empty:
        "No bills of materials yet. Define one with the action above before raising a works order for a made product.",
      rowKey: (r, i) => String(r["bom_id"] ?? i),
      columns: [
        { header: "Bill", cell: "code" },
        { header: "Product", cell: "item" },
        { header: "Site", cell: "site" },
        { header: "Components", cell: "components" },
        { header: "Makes", cell: "output_quantity", numeric: true },
        date("Effective", "effective_from"),
        pill("status"),
      ],
    },
    {
      title: "Works orders",
      description: "Everything raised, with progress against the ordered quantity.",
      fn: "erp_works_orders",
      empty: "No works orders raised. Raise one under Actions above.",
      rowKey: (r, i) => String(r["works_order_id"] ?? r["order_number"] ?? i),
      columns: [
        { header: "Number", cell: "order_number" },
        { header: "Product", cell: "item" },
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
      // No "under Actions above" here: the actions bar is on Work, and this
      // panel is on Reports. An instruction pointing at a control the reader
      // cannot see is worse than none.
      empty: "No works orders raised, so the register is empty. Raising one is done under Work.",
      rowKey: (r, i) => String(r["works_order_id"] ?? r["order_number"] ?? i),
      columns: [
        { header: "Number", cell: "order_number" },
        { header: "Product", cell: "item" },
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
  flow: {
    title: "Quality, step by step",
    note: "Something is found, it is inspected, it is dispositioned, and if it has left the building there is a recall.",
    stages: [
      {
        label: "Event",
        hint: "A complaint, a deviation, an excursion — anything that needs answering.",
        fedBy: "Events appear here once one is raised, here or from the floor.",

        list: QUALITY_EVENT_LIST,
        createFn: "erp_raise_quality_event",
      },
      {
        label: "Inspect",
        hint: "The result against the specification, recorded against the batch.",
        fedBy: "Inspections appear here once an event is raised or a receipt requires inspection.",

        list: QUALITY_EVENT_LIST,
        createFn: "erp_record_inspection_result",
      },
      {
        label: "Disposition",
        hint: "Release, reject, rework or scrap. This is the decision the audit reads.",
        list: QUALITY_EVENT_LIST,
        createFn: "erp_disposition_inspection",
      },
      {
        label: "Close",
        hint: "An event closes when the disposition is made and the actions are logged.",
        list: QUALITY_EVENT_LIST,
        recordArg: "p_event_id",
        actionFn: "erp_close_quality_event",
      },
      {
        label: "Recall",
        hint: "Affected stock has shipped: raise a recall and log every action against the clock.",
        createFn: "erp_raise_recall",
      },
    ],
  },
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
  title: "Quality control",
  blurb: "Events, dispositions, supplier qualification and recall — each with a clock.",
  permission: "quality.read",
  group: "make",
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
        {
          kind: "text",
          name: "p_title",
          label: "Title",
          required: true,
          placeholder: "Seal failure on line 2",
          hint: "A short line describing it, as it will appear in lists.",
        },
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
          label: "Product",
          options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
        },
        pickBatch(),
      ],
      invalidates: ["erp_quality_events"],
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
        {
          kind: "text",
          name: "p_characteristic",
          label: "Characteristic",
          required: true,
          placeholder: "Moisture content",
          hint: "What was measured or checked.",
        },
        { kind: "number", name: "p_numeric_value", label: "Measured value" },
        {
          kind: "text",
          name: "p_text_value",
          label: "Observed value",
          placeholder: "Pass",
          hint: "Use this for results in words. Numbers go in the value box.",
        },
        {
          kind: "text",
          name: "p_instrument",
          label: "Instrument",
          placeholder: "Moisture meter MM-4",
          hint: "What the reading was taken with, if it matters.",
        },
      ],
      invalidates: ["erp_inspections", "erp_quality_events"],
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
        {
          kind: "text",
          name: "p_note",
          label: "Note",
          placeholder: "Anything worth recording",
          hint: "Optional. Kept with the record.",
        },
      ],
      invalidates: ["erp_inspections", "erp_quality_events", "erp_batches"],
    },
    {
      label: "Raise a recall",
      permission: "quality.recall",
      fn: "erp_raise_recall",
      fields: [
        {
          kind: "text",
          name: "p_title",
          label: "Title",
          required: true,
          placeholder: "Suspected contamination, batch B-2026-0142",
          hint: "A short line describing it, as it will appear in lists.",
        },
        reason("p_reason", "Reason", true),
        {
          kind: "text",
          name: "p_classification",
          label: "Classification",
          required: true,
          placeholder: "Class II",
          hint: "How serious this is, in your own scheme.",
        },
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
        {
          kind: "text",
          name: "p_action_kind",
          label: "Action",
          required: true,
          placeholder: "Customer notified",
          hint: "What was done — a notification, a quarantine, a return.",
        },
        { kind: "number", name: "p_quantity_recovered", label: "Quantity recovered" },
        {
          kind: "text",
          name: "p_note",
          label: "Note",
          placeholder: "Anything worth recording",
          hint: "Optional. Kept with the record.",
        },
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
        {
          kind: "text",
          name: "p_root_cause",
          label: "Root cause",
          required: true,
          placeholder: "Sealing head out of calibration",
          hint: "Why it happened, not what happened.",
        },
        {
          kind: "text",
          name: "p_corrective_action",
          label: "Corrective action",
          required: true,
          placeholder: "Head recalibrated and affected stock quarantined",
          hint: "What was done to put this occurrence right.",
        },
        {
          kind: "text",
          name: "p_preventive_action",
          label: "Preventive action",
          required: true,
          placeholder: "Calibration check added to weekly maintenance",
          hint: "What will stop it happening again.",
        },
      ],
      invalidates: ["erp_quality_events"],
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
    empty:
      "No quality events to profile. Deviations, complaints and non-conformances are counted here by kind.",
    label: (r) => String(r["event_kind"] ?? "—"),
    value: () => 1,
  },
  worklists: [
    {
      title: "Quality events",
      description: "Non-conformance, complaint, deviation and their investigations.",
      fn: "erp_quality_events",
      empty:
        "No quality events open. Raise one under Actions above when something needs investigating.",
      rowKey: (r, i) => String(r["event_id"] ?? i),
      columns: [
        { header: "Reference", cell: "reference" },
        { header: "Kind", cell: "event_kind" },
        { header: "Severity", cell: (r) => <StatusPill value={r["severity"]} /> },
        { header: "Title", cell: "title" },
        { header: "Product", cell: "item" },
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
      empty:
        "No supplier is qualified yet. Qualification is recorded against a business partner holding the supplier role.",
      emptyAction: { label: "Open Common data", to: "/master-data" },
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
  flow: {
    title: "Despatch, step by step",
    note: "Plan the shipment, choose the carrier, book it, then confirm what arrived.",
    stages: [
      {
        label: "Delivery",
        hint: "Picked goods waiting to leave. A delivery is what a shipment carries.",
        fedBy: "Deliveries appear here once a sales order has been picked and a delivery raised.",

        typeCode: "delivery",
        partyRole: "customer",
        recordArg: "p_delivery_id",
        actionFn: "erp_confirm_delivery",
        createFn: "erp_plan_shipment",
      },
      {
        label: "Carrier",
        hint: "Who is taking it, at what rate, against which service.",
        fedBy: "Shipments appear here once deliveries are gathered into one at the delivery step.",

        list: SHIPMENT_LIST,
        recordArg: "p_shipment_id",
        actionFn: "erp_select_carrier",
      },
      {
        label: "Book",
        hint: "Booking a shipment is the commitment the carrier sees.",
        fedBy: "Shipments appear here once a carrier has been chosen.",

        list: SHIPMENT_LIST,
        recordArg: "p_shipment_id",
        actionFn: "erp_book_shipment",
      },
      {
        label: "Confirm",
        hint: "Delivered, or failed with a reason. Both are facts the customer will ask about.",
        typeCode: "delivery",
        partyRole: "customer",
        recordArg: "p_delivery_id",
        actionFn: "erp_confirm_delivery",
      },
      {
        label: "Proof",
        hint: "The signature or the photograph, attached to the shipment.",
        list: SHIPMENT_LIST,
        recordArg: "p_shipment_id",
        actionFn: "erp_record_proof_of_delivery",
      },
    ],
  },
  key: "logistics",
  path: "/logistics",
  titleKey: "module.logistics",
  title: "Despatch",
  blurb: "Shipments, carrier bookings and delivery performance, with cost landing on stock.",
  permission: "logistics.read",
  group: "move",
  actions: [
    {
      label: "Confirm a delivery",
      description:
        "The customer has it. Confirming is what closes the delivery and starts the clock on the invoice.",
      permission: "logistics.plan",
      fn: "erp_confirm_delivery",
      fields: [
        pickFrom(
          "erp_documents",
          "document_id",
          ["document_number", "state"],
          "p_delivery_id",
          "Delivery",
          { p_type_code: "delivery", p_limit: 100 },
        ),
      ],
      invalidates: ["erp_documents", "erp_delivery_performance"],
    },
    {
      label: "Record a failed delivery",
      description: "It did not arrive, and why. The reason is what the carrier review reads.",
      permission: "logistics.plan",
      fn: "erp_fail_delivery",
      fields: [
        pickFrom(
          "erp_documents",
          "document_id",
          ["document_number", "state"],
          "p_delivery_id",
          "Delivery",
          { p_type_code: "delivery", p_limit: 100 },
        ),
        reason("p_reason", "Reason", true),
      ],
      invalidates: ["erp_documents", "erp_delivery_performance"],
    },
    {
      label: "Plan a shipment",
      description: "Group deliveries leaving one site on one day.",
      permission: "logistics.plan",
      fn: "erp_plan_shipment",
      fields: [
        pickSite(),
        {
          // Nothing that names an existing record is typed. Deliveries are
          // ticked from the list of deliveries, not copied in as identifiers.
          kind: "multi",
          name: "p_delivery_ids",
          label: "Deliveries",
          required: true,
          hint: "Tick every delivery travelling on this shipment.",
          options: {
            fn: "erp_documents",
            args: { p_type_code: "delivery", p_limit: 200 },
            value: "document_id",
            label: ["document_number", "document_date", "party"],
          },
        },
        { kind: "date", name: "p_planned_despatch", label: "Planned despatch", required: true },
      ],
      invalidates: ["erp_shipments"],
      mapArgs: (v, picked) => ({
        p_site_id: v["p_site_id"],
        p_planned_despatch: v["p_planned_despatch"],
        p_delivery_ids: picked?.lists["p_delivery_ids"] ?? [],
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
      invalidates: ["erp_shipments"],
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
        {
          kind: "select",
          name: "p_carrier_code",
          label: "Carrier",
          required: true,
          options: {
            fn: "erp_parties",
            args: { p_role_kind: "carrier" },
            value: "code",
            label: ["code", "name"],
          },
        },
        {
          kind: "text",
          name: "p_service_code",
          label: "Service",
          required: true,
          placeholder: "NEXT-DAY",
          hint: "The carrier's own service code, from their rate card.",
        },
        {
          kind: "number",
          name: "p_cost_minor",
          label: "Cost",
          required: true,
          hint: "In minor units — pence, cents.",
        },
      ],
      invalidates: ["erp_shipments", "erp_delivery_performance"],
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
        {
          kind: "text",
          name: "p_signed_by",
          label: "Signed by",
          required: true,
          placeholder: "A. Patel",
          hint: "The name of whoever signed for the goods.",
        },
        {
          kind: "text",
          name: "p_reference",
          label: "Reference",
          required: false,
          placeholder: "POD-88213",
          hint: "The carrier's proof-of-delivery reference, if they gave one.",
        },
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
    empty:
      "No deliveries in the window. On-time-in-full is measured from confirmed deliveries, so this fills once goods start leaving.",
    label: (r) => String(r["party"] ?? r["site"] ?? "—"),
    value: (r) => num(r["otif_pct"]),
    unit: "%",
  },
  worklists: [
    {
      title: "Shipments",
      description: "Planned and despatched loads.",
      fn: "erp_shipments",
      empty:
        "No shipments planned. A shipment is planned against confirmed sales deliveries, so there has to be a sales order first.",
      emptyAction: { label: "Open Sales", to: "/sales" },
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
      empty:
        "No deliveries in the window. On-time-in-full is measured from confirmed deliveries, so this fills once goods start leaving.",
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
  title: "Reports and inquiries",
  blurb: "Data quality, duplicates and specification coverage, read from operational tables.",
  permission: "reporting.read",
  group: "records",
  kpis: [
    {
      label: "Business partner data quality",
      fn: "erp_data_quality",
      args: { p_object_type: "party" },
      compute: (rows) => {
        if (rows.length === 0) return null;
        const pct = Math.round(avg(rows, "score"));
        return {
          value: `${pct}%`,
          hint: "average business partner record score",
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
    empty:
      "Coverage could not be measured. The report itself returned nothing, which is not the same as full coverage.",
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
      empty:
        "No likely duplicates. Nothing in the common data scores closely enough to another record to be worth merging.",
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
      title: "Business partner data quality",
      description: "Completeness and validity of business partner master records.",
      fn: "erp_data_quality",
      args: { p_object_type: "party" },
      empty: "No business partner exists yet, so there is nothing to score.",
      emptyAction: { label: "Open Common data", to: "/master-data" },
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
      empty:
        "Coverage could not be measured. The report itself returned nothing, which is not the same as full coverage.",
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
/**
 * The numbers Sales and Purchasing lead with.
 *
 * Both screens are bespoke rather than registry modules, because their content
 * is document lists and a document list needs the organisation's own type code
 * — which a registry panel, whose `fn` and `args` are fixed at build time,
 * cannot name. That is a good reason for the tables to stay where they are and
 * a bad reason for the two busiest screens in the product to be the only ones
 * that open on a wall of rows with no figure at the top.
 *
 * So the tiles come here, beside the modules that have them, and the screens
 * import them. Same `Kpi` type, same `KpiRow`, same rule as everywhere else:
 * every figure is derived in the browser from a read the screen already makes,
 * so a headline can never disagree with the list under it.
 */
export const SALES_KPIS: Kpi[] = [
  {
    label: "Open order lines",
    fn: "erp_release_sequence",
    compute: (rows) =>
      rows.length === 0
        ? { value: "0", hint: "nothing waiting to be released", tone: "ok" }
        : { value: String(rows.length), hint: "awaiting release" },
  },
  {
    label: "Short",
    fn: "erp_release_sequence",
    // The line cannot go out complete on today's availability. Zero is the
    // good answer, which is what zeroIsGood is for.
    compute: (rows) =>
      zeroIsGood(
        count(rows, (r) => r["can_ship_in_full"] === false),
        "cannot ship in full",
      ),
  },
  {
    label: "On credit hold",
    fn: "erp_release_sequence",
    compute: (rows) =>
      zeroIsGood(
        count(rows, (r) => !isOneOf(r["credit_status"], ["ok"])),
        "lines held on credit",
      ),
  },
  {
    label: "Customers overdue",
    fn: "erp_dunning_worklist",
    compute: (rows) => {
      if (rows.length === 0) return { value: "0", hint: "nothing overdue", tone: "ok" };
      const oldest = Math.max(...rows.map((r) => num(r["oldest_days"])));
      // Blocking trading is a different order of problem from being late.
      const blocking = count(rows, (r) => r["blocks_trading"] === true);
      return {
        value: String(rows.length),
        hint: blocking > 0 ? `${blocking} blocking trading` : `oldest ${oldest} days`,
        tone: blocking > 0 ? "bad" : "warn",
      };
    },
  },
];

export const PURCHASING_KPIS: Kpi[] = [
  {
    label: "Received not invoiced",
    fn: "erp_grni",
    compute: (rows) => {
      if (rows.length === 0) return { value: "0", hint: "nothing awaiting an invoice", tone: "ok" };
      const oldest = Math.max(...rows.map((r) => num(r["age_days"])));
      return {
        value: String(rows.length),
        hint: `oldest ${oldest} days`,
        tone: oldest > 60 ? "bad" : oldest > 30 ? "warn" : "ok",
      };
    },
  },
  {
    label: "GRNI value",
    fn: "erp_grni",
    compute: (rows) =>
      rows.length === 0
        ? null
        : { value: money(sum(rows, "open_value_minor")), hint: "open on the balance sheet" },
  },
  {
    label: "Match exceptions",
    fn: "erp_match_workbench",
    compute: (rows) => zeroIsGood(rows.length, "invoices that will not match"),
  },
  {
    label: "Value at risk",
    fn: "erp_match_workbench",
    compute: (rows) =>
      rows.length === 0
        ? null
        : {
            value: money(sum(rows, "value_at_risk_minor")),
            hint: "held by match exceptions",
            tone: "warn",
          },
  },
];

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
  group: TileGroup;
  /**
   * Offered only inside the platform's own organisation (v1.5 §17.5). The
   * database refuses every other organisation regardless; this keeps a door
   * that will be refused off the launchpad.
   */
  platformOnly?: boolean;
};

export const EXTRA_TILES: TileDef[] = [
  {
    path: "/sales",
    titleKey: "nav.sales",
    title: "Sales",
    blurb: "Sales quotes, sales orders and deliveries.",
    permission: "sales.read",
    group: "sell",
  },
  {
    path: "/commercial/price-book",
    titleKey: "nav.commercial_price_book",
    title: "Price book",
    blurb:
      "What the platform sells, at what rate per currency and term, and at what cost, so margin is visible while quoting.",
    permission: "sales.price",
    group: "sell",
    platformOnly: true,
  },
  {
    path: "/commercial/quotes",
    titleKey: "nav.commercial_quotes",
    title: "Quotes",
    blurb:
      "Assembled from price items with margin live, discount approval routed, every version retained, the order form rendered.",
    permission: "sales.order",
    group: "sell",
    platformOnly: true,
  },
  {
    path: "/procurement",
    titleKey: "nav.procurement",
    title: "Purchasing",
    blurb: "Purchase requisitions, purchase orders and receipts.",
    permission: "procurement.read",
    group: "source",
  },
  {
    path: "/master-data",
    titleKey: "nav.master_data",
    title: "Common data",
    blurb: "The products and business partners every document depends on.",
    permission: "master_data.read",
    group: "records",
  },
  {
    path: "/governance",
    titleKey: "nav.governance",
    title: "Change requests",
    blurb: "Proposed master data changes and the approvals on them.",
    permission: "master_data.read",
    group: "records",
  },
  {
    path: "/master-data/imports",
    titleKey: "nav.imports",
    title: "Imports",
    blurb: "Staged batches, preview, validation, load and rollback.",
    permission: "master_data.import",
    group: "records",
  },
  {
    path: "/notifications",
    titleKey: "nav.notifications",
    title: "Notifications",
    blurb:
      "What the product told you, your channel preferences and quiet hours, and the routes from events to audiences.",
    group: "records",
  },
  {
    path: "/reporting/distribution",
    titleKey: "nav.reporting_distribution",
    title: "Subscriptions, packs and extracts",
    blurb:
      "Runs the budget deferred, produced as archived extracts; subscriptions by person or role; assembled packs with manifests; the analytics contract.",
    permission: "reporting.read",
    group: "records",
  },
  {
    path: "/reporting/reproducibility",
    titleKey: "nav.reporting_reproducibility",
    title: "Report versions and runs",
    blurb:
      "Every report version, the governed view it reads, and each run with the parameters it used — so what was shown can be shown again.",
    permission: "reporting.read",
    group: "assure",
  },
  {
    path: "/operations/jobs",
    titleKey: "nav.operations_jobs",
    title: "Recurring tasks",
    blurb: "What is running, what failed, and what has stopped running.",
    permission: "administration.jobs",
    group: "operate",
  },
  {
    path: "/operations/integrations",
    titleKey: "nav.operations_integrations",
    title: "Integrations",
    blurb: "Outbound gateway health and the queue that needs a decision.",
    permission: "administration.integrate",
    group: "operate",
  },
  {
    path: "/operations/assurance",
    titleKey: "nav.operations_assurance",
    title: "Assurance",
    blurb: "The structural checks the build runs on every push.",
    permission: "administration.read",
    group: "assure",
  },
  {
    path: "/operations/continuity",
    titleKey: "nav.operations_continuity",
    title: "Continuity and incidents",
    blurb:
      "What was promised about staying up, whether a drill has proved it, and what happened when it did not.",
    permission: "administration.read",
    group: "operate",
  },
  {
    path: "/device",
    titleKey: "nav.device",
    title: "Scanner",
    blurb:
      "The warehouse application: one task at a time, driven by scanning, with a queue that holds your work until the network returns.",
    permission: "inventory.move",
    group: "move",
  },
  {
    path: "/operations/devices",
    titleKey: "nav.operations_devices",
    title: "Devices and scanning",
    blurb:
      "Registered scanners and terminals, what each may do, the rules a scan is judged by, and the actions waiting to be applied.",
    permission: "administration.read",
    group: "operate",
  },
  {
    path: "/operations/cutover",
    titleKey: "nav.operations_cutover",
    title: "Migration and cutover",
    blurb:
      "Opening balances loaded as at a date, whether each load reconciles, the parallel-run figures, and which domains are cut over on that evidence.",
    permission: "master_data.read",
    group: "operate",
  },
  {
    path: "/operations/output",
    titleKey: "nav.operations_output",
    title: "Output and printing",
    blurb:
      "Template versions, printers, every request with its render and delivery, and the addresses mail may not go to.",
    permission: "administration.read",
    group: "operate",
  },
  {
    path: "/administration/erasure",
    titleKey: "nav.administration_erasure",
    title: "Personal data and erasure",
    blurb:
      "Which columns hold a person's data and what erasure does to each; requests to erase a user or contact, executed by a second person, with the certificate.",
    permission: "administration.read",
    group: "assure",
  },
  {
    path: "/administration/adoption",
    titleKey: "nav.administration_adoption",
    title: "Guidance and adoption",
    blurb:
      "Where adoption is stalling, counted and never named; training scenarios practised in a demo organisation; the product's help for every screen.",
    permission: "administration.read",
    group: "assure",
  },
  {
    path: "/administration/accessibility",
    titleKey: "nav.administration_accessibility",
    title: "Accessibility",
    blurb:
      "The accessibility statement: each WCAG 2.2 criterion, whether the product meets it, how, and the known exceptions.",
    group: "assure",
  },
  {
    path: "/administration/commercial",
    titleKey: "nav.administration_commercial",
    title: "Plan and usage",
    blurb:
      "The plan this organisation is on, what it entitles, how much of each limit is used, and the meters behind the figures.",
    permission: "administration.read",
    group: "organisation",
  },
  {
    path: "/administration/configuration",
    titleKey: "nav.administration_configuration",
    title: "Configuration",
    blurb: "Install modules and promote the change sets that put them in force.",
    permission: "administration.configure",
    group: "configure",
  },
  {
    path: "/administration/packs",
    titleKey: "nav.administration_packs",
    title: "Features and content",
    blurb:
      "Switch product features on and off, apply starter content packs, and see what this organisation cannot yet do.",
    permission: "administration.configure",
    group: "configure",
  },
  {
    path: "/administration/onboarding",
    titleKey: "nav.administration_onboarding",
    title: "Onboarding interview",
    blurb:
      // "Change", not "change set": erp_ref.vocabulary marks the latter an
      // internal model term, and assert_vocabulary_aligned() keeps internal
      // words off the surface.
      "Questions about how this organisation works, turned into a proposed change for each configuration surface.",
    permission: "administration.configure",
    group: "organisation",
  },
  {
    path: "/administration/organisation",
    titleKey: "nav.administration_organisation",
    title: "Organisation and approval routing",
    blurb: "Departments, membership, value bands and named approvers — who approves what, and why.",
    permission: "administration.configure",
    group: "organisation",
  },
  {
    path: "/master-data/classification",
    titleKey: "nav.master_data_classification",
    title: "Categories and codes",
    blurb:
      "Classification axes and values, code templates composed from them, completeness gaps and divergences.",
    permission: "master_data.write",
    group: "configure",
  },
  {
    path: "/master-data/item-supply",
    titleKey: "nav.master_data_item_supply",
    title: "Product-suppliers",
    blurb: "Default suppliers, preference ranks, sourcing splits and approved-for-use status.",
    permission: "master_data.write",
    group: "configure",
  },
  {
    path: "/logistics/release-areas",
    titleKey: "nav.logistics_release_areas",
    title: "Marshalling areas",
    blurb:
      "Allocated stock scopes, pull and push replenishment, ageing back to bulk, and print gating.",
    permission: "logistics.plan",
    group: "configure",
  },
  {
    path: "/inventory/warehouse",
    titleKey: "nav.inventory_warehouse",
    title: "Warehouse layout",
    blurb:
      "Zones, aisles and bins, what each holds, and the storage rules put-away, replenishment and picking read.",
    permission: "inventory.adjust",
    group: "configure",
  },
  {
    path: "/inventory/audit",
    titleKey: "nav.inventory_audit",
    title: "Stock audit",
    blurb:
      "Every location with its quantity and value, the last count against it, and the variance between the two.",
    permission: "inventory.read",
    group: "assure",
  },
  {
    path: "/inventory/forecast",
    titleKey: "nav.inventory_forecast",
    title: "Stock forecast",
    blurb:
      "Usage per day, lead time and reorder point for each product, with days of cover, the date to order by and how much to buy.",
    permission: "inventory.read",
    group: "plan",
  },

  {
    path: "/finance/account-determination",
    titleKey: "nav.finance_account_determination",
    title: "Account determination",
    blurb:
      "Accounting codes and the matrix that decides the nominal account and analysis — with a gap report and no suspense fallback.",
    permission: "finance.configure",
    group: "configure",
  },
  {
    path: "/finance/dimensions",
    titleKey: "nav.finance_dimensions",
    title: "Analysis dimensions",
    blurb:
      "Cost centres, projects and the like: their values, how a posting derives them, and which combinations are allowed.",
    permission: "finance.read",
    group: "configure",
  },
  {
    path: "/administration/permissions",
    titleKey: "nav.administration_permissions",
    title: "Users and authorisations",
    blurb: "Principals, roles, and the grants between them.",
    permission: "administration.roles",
    group: "organisation",
  },
  {
    path: "/administration/terminology",
    titleKey: "nav.terminology",
    title: "Terminology",
    blurb: "The wording of every label, per organisation.",
    permission: "administration.configure",
    group: "configure",
  },
  {
    path: "/administration/audit",
    titleKey: "nav.audit",
    title: "Audit log",
    blurb:
      "Who did what, to which object, and when — filterable by action, object, actor and date.",
    permission: "administration.audit_read",
    group: "assure",
  },
  {
    path: "/administration/tenant",
    titleKey: "nav.tenant",
    title: "Organisation lifecycle",
    blurb: "Go-live, export and portability, and deletion that deletes.",
    permission: "administration.configure",
    group: "organisation",
  },
];

export const GROUP_LABELS: Record<TileGroup, string> = {
  plan: "Plan",
  source: "Source",
  make: "Make",
  move: "Move",
  sell: "Sell",
  settle: "Settle",
  records: "Records",
  organisation: "Organisation",
  configure: "Configure",
  operate: "Operate",
  assure: "Assure",
};

/** The order the two areas read in: the journey and its records, then the four settings sections. */
export const GROUP_ORDER: TileGroup[] = [...WORK_GROUPS, ...SETTINGS_GROUPS];

/**
 * Where a glossary term is maintained or used.
 *
 * The palette searches erp_ref.vocabulary so somebody who says "inventory",
 * "item" or "vendor" still lands somewhere. A term only earns a row when it
 * leads to a screen, so this map is the whole of what the search can offer —
 * and a term absent from it simply does not appear, rather than offering a
 * destination that would not help.
 */
export const GLOSSARY_DESTINATION: Record<string, string> = {
  stock: "/inventory",
  cycle_count: "/inventory",
  stocktake: "/inventory",
  batch: "/inventory",
  handling_unit: "/inventory",
  product: "/master-data",
  business_partner: "/master-data",
  supplier: "/master-data",
  analysis_code: "/master-data/classification",
  works_order: "/production",
  despatch: "/logistics",
  marshalling_area: "/logistics/release-areas",
  goods_out: "/logistics",
  goods_in: "/procurement",
  grni: "/procurement",
  requisition: "/procurement",
  accounting_code: "/finance/account-determination",
  nominal_account: "/finance",
  accounting_period: "/finance",
  sales_ledger: "/finance",
  purchase_ledger: "/finance",
  company: "/administration/organisation",
  user: "/administration/permissions",
  organisation: "/administration/tenant",
  global_allocation: "/sales",
  detailed_allocation: "/sales",
};

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
