import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useState } from "react";

import { ActionButton, ActionDialog, ErrorNote } from "../../components/erp/action";
import { ActionBar, codeField, reason } from "../../components/erp/actions-bar";
import { AutoPanel } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { Field, RecordBrowser, RecordSection } from "../../components/erp/record-browser";
import { callErp, hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * Products and business partners.
 *
 * Every document line points at a product and most documents point at a
 * business partner, so an organisation with neither cannot transact at all.
 *
 * This was two flat tables until the list-and-record shape arrived. The tables
 * showed five columns each and nothing could be opened, so everything else the
 * doors already return — a product's group, its stock unit, whether it is
 * batch, serial or expiry controlled, how it is classified, who supplies it —
 * was being fetched and thrown away. The list now stays where it is and the
 * record opens beside it, which is how master data is actually read: not one
 * product at a time, but the one of forty that is set up differently from the
 * other thirty-nine.
 *
 * Creating either is still a dialog with the minimum a document needs. The
 * governed half of master data — attributes, duplicate merging, mass change —
 * has its own approvals and its own screens, and does not belong smuggled into
 * a create form.
 */

export const Route = createFileRoute("/master-data/")({
  head: () => ({
    meta: [
      { title: "Common data — Clove ERP" },
      {
        name: "description",
        content:
          "Create and review the products and business partners every Clove ERP document depends on.",
      },
      { property: "og:title", content: "Common data — Clove ERP" },
      {
        property: "og:description",
        content:
          "Create and review the products and business partners every Clove ERP document depends on.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <MasterData />
    </Gate>
  ),
});

type Item = {
  item_id: string;
  code: string;
  name: string;
  item_class: string | null;
  item_group: string | null;
  lifecycle: string;
  status: string;
  stock_uom_code: string | null;
  is_batch_controlled: boolean;
  is_serial_controlled: boolean;
  has_expiry: boolean;
};

type Party = {
  party_id: string;
  code: string;
  name: string;
  legal_name: string | null;
  country_code: string | null;
  status: string;
  roles: string[];
};

type Classification = {
  classification_id: string;
  axis_code: string;
  axis_name: string;
  value_code: string;
  value_name: string;
  abbreviation: string | null;
};

type ItemSupplier = {
  item_supplier_id: string;
  supplier: string;
  supplier_item_code: string | null;
  preference_rank: number | null;
  is_default: boolean;
  is_approved_for_use: boolean;
  lead_time_days: number | null;
  min_order_quantity: number | null;
};

const ROLES = ["customer", "supplier", "carrier", "manufacturer", "broker", "consignee", "agent"];

const LIMIT = 200;

function MasterData() {
  const { session } = useErpSession();
  const { t } = useT();
  const mayWrite = hasPermission(session, "master_data.write");
  // erp_item_suppliers authorises on procurement.read rather than
  // master_data.read, so the panel is asked for only where it would be
  // answered. Rendering it for everybody would turn a permission boundary
  // into an error message on a screen that is otherwise working.
  const maySeeSuppliers = hasPermission(session, "procurement.read");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.master_data", "Common data")}>
        Products and business partners. A document line needs a product and most documents need a
        business partner, so this is where an organisation becomes able to transact.
      </PageHeader>

      <Items mayWrite={mayWrite} maySeeSuppliers={maySeeSuppliers} />
      <Parties mayWrite={mayWrite} />

      <ActionBar
        title="Partners, roles and duplicates"
        note="A business partner is one record with the roles it plays. Two records for one partner are merged into a survivor, with the reason kept."
        actions={[
          {
            label: "Create a business partner with roles",
            description: "The record and every role it plays, in one step.",
            permission: "master_data.write",
            fn: "erp_create_party_with_roles",
            fields: [
              codeField("p_code", "Code", "CUST-COOP", {
                fn: "erp_parties",
                value: "code",
                label: ["code", "name"],
              }),
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Co-op Wholesale Ltd",
              },
              {
                kind: "multi",
                name: "p_role_kinds",
                label: "Roles",
                required: true,
                hint: "Tick every role this partner plays.",
                choices: ROLES.map((r) => ({ value: r, label: r })),
              },
              {
                kind: "text",
                name: "p_country_code",
                label: "Country",
                placeholder: "GB",
                hint: "Two-letter country code.",
              },
              {
                kind: "text",
                name: "p_legal_name",
                label: "Legal name",
                placeholder: "Co-operative Wholesale Limited",
                hint: "The registered name, if it differs from the trading name.",
              },
            ],
            mapArgs: (v, picked) => ({
              p_code: v["p_code"],
              p_name: v["p_name"],
              p_role_kinds: picked?.lists["p_role_kinds"] ?? [],
              p_country_code: v["p_country_code"] || null,
              p_legal_name: v["p_legal_name"] || null,
            }),
            invalidates: ["erp_parties"],
          },
          {
            label: "Add a role to a business partner",
            permission: "master_data.write",
            fn: "erp_add_party_role",
            fields: [
              {
                kind: "select",
                name: "p_party_id",
                label: "Business partner",
                required: true,
                options: { fn: "erp_parties", value: "party_id", label: ["code", "name"] },
              },
              {
                kind: "choice",
                name: "p_role_kind",
                label: "Role",
                required: true,
                choices: ROLES.map((r) => ({ value: r, label: r })),
              },
            ],
            invalidates: ["erp_parties"],
          },
          {
            label: "Merge duplicate records",
            description:
              "Every reference to the duplicate is moved to the survivor; the duplicate is withdrawn, not deleted.",
            permission: "master_data.write",
            fn: "erp_merge_master_record",
            fields: [
              {
                kind: "choice",
                name: "p_object_type",
                label: "Kind of record",
                required: true,
                choices: [
                  { value: "party", label: "Business partner" },
                  { value: "item", label: "Product" },
                ],
              },
              {
                kind: "text",
                name: "p_survivor_id",
                label: "Record being kept",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "The id of the record everything should point at afterwards.",
              },
              {
                kind: "text",
                name: "p_duplicate_id",
                label: "Record being withdrawn",
                required: true,
                placeholder: "0f9c1a2e-…",
                hint: "The id of the duplicate. Both ids are shown in the duplicate candidates list.",
              },
              reason("p_reason", "Reason", true),
            ],
            invalidates: ["erp_parties", "erp_items"],
          },
          {
            label: "Create a unit of measure",
            permission: "master_data.write",
            fn: "erp_create_uom",
            fields: [
              {
                kind: "text",
                name: "p_code",
                label: "Code",
                required: true,
                placeholder: "EA",
                hint: "The short code used on documents, for example EA, KG or BOX.",
              },
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Each",
              },
              {
                kind: "choice",
                name: "p_uom_class",
                label: "Class",
                required: true,
                choices: [
                  { value: "quantity", label: "Quantity" },
                  { value: "weight", label: "Weight" },
                  { value: "volume", label: "Volume" },
                  { value: "length", label: "Length" },
                  { value: "area", label: "Area" },
                  { value: "time", label: "Time" },
                ],
              },
              { kind: "number", name: "p_decimals", label: "Decimal places", required: true },
              {
                kind: "choice",
                name: "p_is_base",
                label: "Base unit of its class",
                required: true,
                boolean: true,
                choices: [
                  { value: "false", label: "No" },
                  { value: "true", label: "Yes" },
                ],
              },
            ],
            invalidates: ["erp_uoms"],
          },
        ]}
      />

      <AutoPanel
        title="Units of measure"
        description="Every unit a product can be counted, weighed or measured in."
        fn="erp_uoms"
        empty="No unit of measure yet. The first product creates one; a further one is created above."
        rowKey={(r, i) => String(r["uom_id"] ?? i)}
        columns={[
          { header: "Code", cell: "code" },
          { header: "Name", cell: "name" },
          { header: "Class", cell: "uom_class" },
          { header: "Decimals", cell: "decimals", numeric: true },
          { header: "Base", cell: "is_base" },
        ]}
      />
    </div>
  );
}

function Items({ mayWrite, maySeeSuppliers }: { mayWrite: boolean; maySeeSuppliers: boolean }) {
  const [search, setSearch] = useState("");
  const onSearchChange = useCallback((s: string) => setSearch(s), []);
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_items", { search }],
    queryFn: () => callErp<Item[]>("erp_items", { p_search: search || null, p_limit: LIMIT }),
  });

  return (
    <RecordBrowser<Item>
      nounSingular="product"
      nounPlural="products"
      title="Products"
      description="What is bought, made, stocked and sold. The unit of measure is created with the first product when the organisation has none."
      headerAction={mayWrite ? <NewItem /> : null}
      columns={[
        {
          key: "code",
          header: "Code",
          value: (i) => i.code,
          render: (i) => <span className="font-mono">{i.code}</span>,
          filter: true,
        },
        { key: "name", header: "Name", value: (i) => i.name, filter: true },
      ]}
      gridTemplate="grid-cols-[7rem_minmax(0,1fr)]"
      rows={data}
      isPending={isPending}
      error={error}
      limit={LIMIT}
      onSearchChange={onSearchChange}
      idOf={(i) => i.item_id}
      titleOf={(i) => i.code}
      subtitleOf={(i) => i.name}
      recentsKey="clove.recent.products"
      detail={(item) => <ItemRecord item={item} maySeeSuppliers={maySeeSuppliers} />}
    />
  );
}

function ItemRecord({ item, maySeeSuppliers }: { item: Item; maySeeSuppliers: boolean }) {
  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="font-mono text-sm font-semibold">{item.code}</h3>
        <p className="min-w-0 flex-1 truncate text-base">{item.name}</p>
        <Pill tone={item.lifecycle === "active" ? "ok" : "muted"}>{item.lifecycle}</Pill>
      </div>

      <RecordSection title="Identification">
        <dl className="grid gap-4 sm:grid-cols-3">
          <Field label="Class">{item.item_class ?? "—"}</Field>
          <Field label="Group">{item.item_group ?? "—"}</Field>
          <Field label="Stock unit">{item.stock_uom_code ?? "—"}</Field>
          <Field label="Status">{item.status}</Field>
        </dl>
      </RecordSection>

      <RecordSection title="Traceability">
        {/* Three separate controls, so they are shown separately. A single
            "tracked" pill would hide which of the three a product actually
            carries, and they mean different things at the receipt. */}
        <div className="flex flex-wrap gap-2">
          <Pill tone={item.is_batch_controlled ? "ok" : "muted"}>
            {item.is_batch_controlled ? "Batch controlled" : "No batch control"}
          </Pill>
          <Pill tone={item.is_serial_controlled ? "ok" : "muted"}>
            {item.is_serial_controlled ? "Serial controlled" : "No serial control"}
          </Pill>
          <Pill tone={item.has_expiry ? "ok" : "muted"}>
            {item.has_expiry ? "Expiry dated" : "No expiry date"}
          </Pill>
        </div>
      </RecordSection>

      <ItemClassification itemId={item.item_id} />
      {maySeeSuppliers ? <ItemSuppliers itemId={item.item_id} /> : null}
    </div>
  );
}

function ItemClassification({ itemId }: { itemId: string }) {
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_item_classification", { itemId }],
    queryFn: () => callErp<Classification[]>("erp_item_classification", { p_item_id: itemId }),
  });

  return (
    <RecordSection title="Classification">
      {isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      ) : error ? (
        <ErrorNote error={error} />
      ) : (data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          Not classified. Reports that group by an axis will leave this product out.
        </p>
      ) : (
        <dl className="grid gap-4 sm:grid-cols-3">
          {(data ?? []).map((c) => (
            <Field key={c.classification_id} label={c.axis_name}>
              {c.value_name}
              <span className="ml-1.5 font-mono text-xs text-muted-foreground">{c.value_code}</span>
            </Field>
          ))}
        </dl>
      )}
    </RecordSection>
  );
}

function ItemSuppliers({ itemId }: { itemId: string }) {
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_item_suppliers", { itemId }],
    queryFn: () => callErp<ItemSupplier[]>("erp_item_suppliers", { p_item_id: itemId }),
  });

  return (
    <RecordSection title="Supply">
      {isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      ) : error ? (
        <ErrorNote error={error} />
      ) : (data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No supplier recorded. A purchase order for this product has nobody to go to.
        </p>
      ) : (
        <Table columns={["Supplier", "Their code", "Rank", "Lead time", "Approved"]}>
          {(data ?? []).map((s) => (
            <tr key={s.item_supplier_id} className="border-b border-border/50 last:border-0">
              <td className="py-2 pr-4">
                {s.supplier}
                {s.is_default ? <Pill tone="ok">default</Pill> : null}
              </td>
              <td className="py-2 pr-4 font-mono text-xs">{s.supplier_item_code ?? "—"}</td>
              <td className="py-2 pr-4 text-xs text-muted-foreground">
                {s.preference_rank ?? "—"}
              </td>
              <td className="py-2 pr-4 text-xs text-muted-foreground">
                {s.lead_time_days === null ? "—" : `${s.lead_time_days} days`}
              </td>
              <td className="py-2 pr-4">
                <Pill tone={s.is_approved_for_use ? "ok" : "warn"}>
                  {s.is_approved_for_use ? "Approved" : "Not approved"}
                </Pill>
              </td>
            </tr>
          ))}
        </Table>
      )}
    </RecordSection>
  );
}

function NewItem() {
  return (
    <ActionDialog
      trigger={<ActionButton>New product</ActionButton>}
      title="New product"
      description="A code and a name are the minimum. Everything else is maintainable afterwards."
      permission="master_data.write"
      fn="erp_create_item"
      fields={[
        {
          kind: "text",
          name: "p_code",
          label: "Code",
          required: true,
          placeholder: "OAT-25",
          hint: "How people will refer to this product everywhere.",
        },
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          required: true,
          placeholder: "Oat milk 1L, case of 12",
        },
        {
          kind: "text",
          name: "p_item_class",
          label: "Class",
          hint: "Free text — finished_good, raw_material, packaging.",
        },
      ]}
      mapArgs={(v) => ({
        p_code: v["p_code"],
        p_name: v["p_name"],
        p_item_class: v["p_item_class"] || null,
        p_is_batch_controlled: false,
      })}
      invalidates={["erp_items"]}
      submitLabel="Create product"
    />
  );
}

function Parties({ mayWrite }: { mayWrite: boolean }) {
  const [search, setSearch] = useState("");
  const onSearchChange = useCallback((s: string) => setSearch(s), []);
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_parties", { search }],
    queryFn: () =>
      callErp<Party[]>("erp_parties", {
        p_role_kind: null,
        p_search: search || null,
        p_limit: LIMIT,
      }),
  });

  return (
    <RecordBrowser<Party>
      nounSingular="business partner"
      nounPlural="business partners"
      title="Business partners"
      description="One record for customers, suppliers and everybody else. The role is what decides which picker offers a partner, and one partner may hold several."
      headerAction={mayWrite ? <NewParty /> : null}
      columns={[
        {
          key: "code",
          header: "Code",
          value: (p) => p.code,
          render: (p) => <span className="font-mono">{p.code}</span>,
          filter: true,
        },
        { key: "name", header: "Name", value: (p) => p.name, filter: true },
      ]}
      gridTemplate="grid-cols-[7rem_minmax(0,1fr)]"
      rows={data}
      isPending={isPending}
      error={error}
      limit={LIMIT}
      onSearchChange={onSearchChange}
      idOf={(p) => p.party_id}
      titleOf={(p) => p.code}
      subtitleOf={(p) => p.name}
      recentsKey="clove.recent.partners"
      detail={(party) => <PartyRecord party={party} />}
    />
  );
}

function PartyRecord({ party }: { party: Party }) {
  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="font-mono text-sm font-semibold">{party.code}</h3>
        <p className="min-w-0 flex-1 truncate text-base">{party.name}</p>
        <Pill tone={party.status === "active" ? "ok" : "muted"}>{party.status}</Pill>
      </div>

      <RecordSection title="Identification">
        <dl className="grid gap-4 sm:grid-cols-3">
          <Field label="Legal name">{party.legal_name ?? party.name}</Field>
          <Field label="Country">{party.country_code ?? "—"}</Field>
          <Field label="Status">{party.status}</Field>
        </dl>
      </RecordSection>

      <RecordSection title="Roles">
        {(party.roles ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            None. This partner is offered in no picker, so nothing can be raised against it.
          </p>
        ) : (
          <div className="flex flex-wrap gap-2">
            {(party.roles ?? []).map((r) => (
              <Pill key={r} tone="muted">
                {r}
              </Pill>
            ))}
          </div>
        )}
      </RecordSection>

      {/*
        A partner record stops here on purpose. Addresses, contacts, payment
        terms and credit are each governed by their own permission and their
        own doors, and none of them is readable from what this screen has
        already fetched. Showing empty sections for them would say the data is
        absent when what is absent is the read.
      */}
      <Prose className="mt-5 text-xs text-muted-foreground">
        Addresses, contacts and credit are governed separately and are not read here.
      </Prose>
    </div>
  );
}

function NewParty() {
  return (
    <ActionDialog
      trigger={<ActionButton>New business partner</ActionButton>}
      title="New business partner"
      description="The role given here is the first one; more can be added afterwards."
      permission="master_data.write"
      fn="erp_create_party"
      fields={[
        {
          kind: "text",
          name: "p_code",
          label: "Code",
          required: true,
          placeholder: "CUST-COOP",
          hint: "How people will refer to this partner everywhere.",
        },
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          required: true,
          placeholder: "Co-op Wholesale Ltd",
        },
        {
          kind: "choice",
          name: "p_role_kind",
          label: "Role",
          required: true,
          choices: ROLES.map((r) => ({ value: r, label: r })),
          hint: "More roles can be added afterwards.",
        },
        {
          kind: "text",
          name: "p_country_code",
          label: "Country",
          hint: "Two-letter code, e.g. GB.",
        },
      ]}
      mapArgs={(v) => ({
        p_code: v["p_code"],
        p_name: v["p_name"],
        p_role_kind: (v["p_role_kind"] || "customer").toString().trim().toLowerCase(),
        p_country_code: v["p_country_code"]
          ? v["p_country_code"].toString().trim().toUpperCase()
          : null,
      })}
      invalidates={["erp_parties"]}
      submitLabel="Create business partner"
    />
  );
}
