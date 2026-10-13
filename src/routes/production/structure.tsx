import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { ActionButton, ErrorNote, useErpAction } from "../../components/erp/action";
import { useCurrencies } from "../../components/erp/currencies";
import { Gate } from "../../components/erp/gate";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { useErpSession, useScope } from "../../components/erp/session-context";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { formatMinor, minorUnitsOf } from "../../lib/money";

export const Route = createFileRoute("/production/structure")({
  head: () => ({
    meta: [
      { title: "Product structure — Clove ERP" },
      {
        name: "description",
        content:
          "What a made product is made of at every level, how long its routing takes, and what one costs to make in materials and labour.",
      },
      { property: "og:title", content: "Product structure — Clove ERP" },
      {
        property: "og:description",
        content:
          "A product's bill of materials opened level by level, its routing's operations, its rolled-up cost and where it is used.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <ProductStructure />
    </Gate>
  ),
});

type Option = { item_id: string; code: string; name: string };
type Site = { site_id: string; code: string; name: string };
type Bom = { item_id: string };

/** Shaped by public.erp_product_structure(). */
type Line = {
  level: number;
  path: string;
  item_id: string;
  code: string;
  name: string;
  quantity_per: number;
  quantity: number;
  uom: string | null;
  made: boolean;
  phantom: boolean;
  unit_cost_minor: number;
  cost_minor: number;
};

type Operation = {
  seq: number;
  name: string;
  work_centre: string | null;
  minutes: number;
  cost_minor: number;
};

type Structure = {
  item: Option;
  quantity: number;
  currency: string | null;
  bom: { code: string; version: number; output_quantity: number } | null;
  routing: { code: string; version: number } | null;
  lines: Line[];
  operations: Operation[];
  made: boolean;
  materials_minor: number;
  labour_minor: number;
  rolled_up_minor: number;
  current_cost_minor: number | null;
  costing_method: string;
  where_used: { item_id: string; code: string; name: string; bom: string; quantity_per: number }[];
  /** What the run makes besides the product (20261013100000). */
  outputs: {
    item_id: string;
    code: string;
    name: string;
    kind: string;
    quantity: number;
    cost_share_pct: number | null;
    unit_value_minor: number | null;
  }[];
};

const ADOPT = { fn: "erp_adopt_rolled_up_cost", permission: "finance.configure" } as const;

/**
 * A made product, opened.
 *
 * The Manufacturing page lists bills of materials one level at a time, by
 * code: a planner who wants to know what a product is really made of, how
 * long it takes, or what it costs had to open each component's bill in turn
 * and add it up by hand. Here the database does that walk once
 * (erp_product_structure) and the screen draws it: every level indented under
 * its parent, what one takes and what the quantity asked takes in all, the
 * routing's operations for that quantity, and one unit's cost to make, split
 * into materials and labour, beside what the product costs now.
 *
 * Adopting the roll-up as the standard is offered to whoever may set costs,
 * and only where the product is standard-costed; the database refuses it
 * otherwise, and refuses it with stock on hand it would revalue.
 */
function ProductStructure() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const scope = useScope();
  const { currencies } = useCurrencies();

  const [itemId, setItemId] = useState("");
  const [siteId, setSiteId] = useState("");
  const [quantity, setQuantity] = useState("1");
  const site = siteId || scope.siteId;
  const qty = Number(quantity) > 0 ? Number(quantity) : 1;

  const items = useQuery({
    queryKey: ["erp_items", { limit: 500 }],
    queryFn: () => callErp<Option[]>("erp_items", { p_limit: 500 }),
  });
  const sites = useQuery({
    queryKey: ["erp_sites"],
    queryFn: () => callErp<Site[]>("erp_sites", {}),
  });
  const boms = useQuery({
    queryKey: ["erp_boms"],
    queryFn: () => callErp<Bom[]>("erp_boms", {}),
  });
  const structure = useQuery({
    queryKey: ["erp_product_structure", { itemId, site, qty }],
    queryFn: () =>
      callErp<Structure>("erp_product_structure", {
        p_item_id: itemId,
        p_site_id: site,
        p_quantity: qty,
      }),
    enabled: itemId !== "" && site !== "",
  });

  const adopt = useErpAction({
    fn: ADOPT.fn,
    invalidates: ["erp_product_structure"],
    outcome: () => ui("The rolled-up cost is now the product's standard."),
  });

  // Made products first: they are what this screen is for. A bought one is
  // still offered, for where it is used.
  const made = new Set((boms.data ?? []).map((b) => b.item_id));
  const options = [...(items.data ?? [])].sort(
    (a, b) =>
      Number(made.has(b.item_id)) - Number(made.has(a.item_id)) || a.code.localeCompare(b.code),
  );

  const data = structure.data;
  const currency = data?.currency ?? "GBP";
  const money = (minor: number | null) =>
    minor === null
      ? ui("None yet")
      : formatMinor(minor, currency, minorUnitsOf(currencies, currency));
  const number = (n: number) => n.toLocaleString(undefined, { maximumFractionDigits: 4 });

  const field = `${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`;
  const caption = "text-xs font-medium uppercase tracking-wide text-muted-foreground";
  const mayAdopt = hasPermission(session, ADOPT.permission);
  const differs =
    data !== undefined && data.made && data.current_cost_minor !== data.rolled_up_minor;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader
        title={t("nav.production_structure", "Product structure")}
        howItWorks="Each component's own bill is opened in turn, down to what is bought. A run's set-up is shared across what the run makes; its run time is counted for every unit. Scrap and yield are included."
      >
        What a made product is made of, how long it takes, and what one costs to make.
      </PageHeader>

      <section className="grid min-w-0 grid-cols-1 gap-3 rounded-xl border border-border bg-card p-4 sm:grid-cols-3 sm:p-5">
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Product")}</span>
          <select value={itemId} onChange={(e) => setItemId(e.target.value)} className={field}>
            <option value="">{ui("Choose…")}</option>
            {options.map((o) => (
              <option key={o.item_id} value={o.item_id}>
                {o.code} — {o.name}
                {made.has(o.item_id) ? ` · ${ui("made")}` : ""}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Site")}</span>
          <select value={site} onChange={(e) => setSiteId(e.target.value)} className={field}>
            <option value="">{ui("Choose…")}</option>
            {(sites.data ?? []).map((s) => (
              <option key={s.site_id} value={s.site_id}>
                {s.code} — {s.name}
              </option>
            ))}
          </select>
        </label>
        <label className="flex min-w-0 flex-col gap-1 text-sm">
          <span className={caption}>{ui("Quantity")}</span>
          <input
            type="number"
            inputMode="decimal"
            min="0"
            step="any"
            value={quantity}
            onChange={(e) => setQuantity(e.target.value)}
            className={field}
          />
        </label>
      </section>

      {itemId === "" ? (
        <p className="text-sm text-muted-foreground">
          {ui("Choose a made product to see its structure and its cost.")}
        </p>
      ) : structure.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          {ui("Opening the structure…")}
        </p>
      ) : structure.error ? (
        <ErrorNote error={structure.error} />
      ) : data ? (
        <>
          <section className="min-w-0 rounded-xl border border-border bg-card px-4 py-4 sm:px-5">
            <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
              <h2 className="text-sm font-semibold">
                {data.item.code} — {data.item.name}
              </h2>
              {data.made ? (
                <Pill tone="ok">{data.bom?.code ?? ui("Made")}</Pill>
              ) : (
                <Pill tone="warn">{ui("Bought, not made here")}</Pill>
              )}
              {data.routing ? <Pill tone="ok">{data.routing.code}</Pill> : null}
            </div>
            <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-3 text-sm tabular-nums sm:grid-cols-4">
              <div className="flex min-w-0 flex-col gap-0.5">
                <dt className={caption}>{ui("Materials, one")}</dt>
                <dd>{money(data.materials_minor)}</dd>
              </div>
              <div className="flex min-w-0 flex-col gap-0.5">
                <dt className={caption}>{ui("Labour, one")}</dt>
                <dd>{money(data.labour_minor)}</dd>
              </div>
              <div className="flex min-w-0 flex-col gap-0.5">
                <dt className={caption}>{ui("Rolled up, one")}</dt>
                <dd className="font-semibold">{money(data.rolled_up_minor)}</dd>
              </div>
              <div className="flex min-w-0 flex-col gap-0.5">
                <dt className={caption}>{ui("Costs now")}</dt>
                <dd>
                  {money(data.current_cost_minor)}{" "}
                  <span className="text-xs text-muted-foreground">({data.costing_method})</span>
                </dd>
              </div>
            </dl>
            {mayAdopt && differs && data.costing_method === "standard" ? (
              <div className="mt-4 flex flex-wrap items-center gap-3 border-t border-border pt-4">
                <ActionButton
                  busy={adopt.isPending}
                  onClick={() => adopt.mutate({ p_item_id: itemId, p_site_id: site })}
                >
                  {ui("Adopt as standard cost")}
                </ActionButton>
                <span className="text-xs text-muted-foreground">
                  {ui("Refused while stock is on hand at the old standard.")}
                </span>
              </div>
            ) : null}
            <ErrorNote error={adopt.error} />
          </section>

          {data.lines.length > 0 ? (
            <section className="flex min-w-0 flex-col gap-3">
              <h2 className="text-sm font-semibold">
                {ui("Made of")} · {number(data.quantity)}
              </h2>
              <Table
                columns={[
                  ui("Component"),
                  ui("Each takes"),
                  ui("In all"),
                  ui("Unit cost"),
                  ui("Cost"),
                ]}
              >
                {data.lines.map((l) => (
                  <tr key={l.path} className="border-b border-border last:border-0">
                    <td className="py-2 pr-4">
                      <span
                        className="flex min-w-0 items-baseline gap-2"
                        style={{ paddingInlineStart: `${(l.level - 1) * 1.25}rem` }}
                      >
                        <span className="font-medium">{l.code}</span>
                        <span className="truncate text-muted-foreground">{l.name}</span>
                        {l.made ? <Pill tone="ok">{ui("made")}</Pill> : null}
                        {l.phantom ? <Pill tone="warn">{ui("phantom")}</Pill> : null}
                      </span>
                    </td>
                    <td className="py-2 pr-4 tabular-nums">
                      {number(l.quantity_per)} {l.uom ?? ""}
                    </td>
                    <td className="py-2 pr-4 tabular-nums">
                      {number(l.quantity)} {l.uom ?? ""}
                    </td>
                    <td className="py-2 pr-4 tabular-nums">{money(l.unit_cost_minor)}</td>
                    <td className="py-2 pr-4 tabular-nums">{money(l.cost_minor)}</td>
                  </tr>
                ))}
              </Table>
            </section>
          ) : null}

          {data.operations.length > 0 ? (
            <section className="flex min-w-0 flex-col gap-3">
              <h2 className="text-sm font-semibold">
                {ui("Operations")} · {number(data.quantity)}
              </h2>
              <Table columns={[ui("Operation"), ui("Work centre"), ui("Minutes"), ui("Cost")]}>
                {data.operations.map((o) => (
                  <tr key={o.seq} className="border-b border-border last:border-0">
                    <td className="py-2 pr-4">{o.name}</td>
                    <td className="py-2 pr-4">{o.work_centre ?? ""}</td>
                    <td className="py-2 pr-4 tabular-nums">{number(o.minutes)}</td>
                    <td className="py-2 pr-4 tabular-nums">{money(o.cost_minor)}</td>
                  </tr>
                ))}
              </Table>
            </section>
          ) : null}

          {data.outputs.length > 0 ? (
            <section className="flex min-w-0 flex-col gap-3">
              <h2 className="text-sm font-semibold">
                {ui("Also makes")} · {number(data.quantity)}
              </h2>
              <Table
                columns={[
                  ui("Product"),
                  ui("Kind"),
                  ui("In all"),
                  ui("Share of cost (%)"),
                  ui("Value each"),
                ]}
              >
                {data.outputs.map((o) => (
                  <tr key={o.item_id} className="border-b border-border last:border-0">
                    <td className="py-2 pr-4">
                      <span className="font-medium">{o.code}</span>{" "}
                      <span className="text-muted-foreground">{o.name}</span>
                    </td>
                    <td className="py-2 pr-4">{o.kind}</td>
                    <td className="py-2 pr-4 tabular-nums">{number(o.quantity)}</td>
                    <td className="py-2 pr-4 tabular-nums">
                      {o.cost_share_pct === null ? "" : number(o.cost_share_pct)}
                    </td>
                    <td className="py-2 pr-4 tabular-nums">
                      {o.unit_value_minor === null ? "" : money(o.unit_value_minor)}
                    </td>
                  </tr>
                ))}
              </Table>
            </section>
          ) : null}

          {data.where_used.length > 0 ? (
            <section className="flex min-w-0 flex-col gap-3">
              <h2 className="text-sm font-semibold">{ui("Used in")}</h2>
              <Table columns={[ui("Product"), ui("Bill of materials"), ui("Each takes")]}>
                {data.where_used.map((w) => (
                  <tr
                    key={`${w.item_id}-${w.bom}`}
                    className="border-b border-border last:border-0"
                  >
                    <td className="py-2 pr-4">
                      <button
                        type="button"
                        className="text-left font-medium underline-offset-2 hover:underline"
                        onClick={() => setItemId(w.item_id)}
                      >
                        {w.code}
                      </button>{" "}
                      <span className="text-muted-foreground">{w.name}</span>
                    </td>
                    <td className="py-2 pr-4">{w.bom}</td>
                    <td className="py-2 pr-4 tabular-nums">{number(w.quantity_per)}</td>
                  </tr>
                ))}
              </Table>
            </section>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
