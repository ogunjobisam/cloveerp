import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useState } from "react";

import { ActionButton, ActionDialog, ErrorNote, GoTo } from "../../components/erp/action";
import { openAction } from "../../components/erp/action-registry";
import {
  ActionBar,
  codeField,
  pickCountry,
  pickItem,
  pickParty,
  reason,
} from "../../components/erp/actions-bar";
import { AutoPanel } from "../../components/erp/auto";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { Field, RecordBrowser, RecordSection } from "../../components/erp/record-browser";
import { callErp, hasPermission } from "../../lib/erp";
import { prettifyField } from "../../lib/friendly";
import { useT } from "../../lib/i18n";
import { partyAddressArgs } from "../../lib/invoice-details";

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
  /** What lines take when nobody types one. Null when the product has none. */
  description: string | null;
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

/**
 * Every erp.party_role_kind, so the picker can create any partner the doors
 * accept, in the word a person reads rather than the database's code (J-107).
 */
const ROLE_CHOICES = [
  { value: "customer", label: "Customer" },
  { value: "supplier", label: "Supplier" },
  { value: "carrier", label: "Carrier" },
  { value: "manufacturer", label: "Manufacturer" },
  { value: "broker", label: "Broker" },
  { value: "consignee", label: "Consignee" },
  { value: "agent", label: "Agent" },
  { value: "internal", label: "Internal" },
  { value: "regulator", label: "Regulator" },
];

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
  // A partner's VAT number, terms and contacts are read on master_data.read.
  const mayReadParty = hasPermission(session, "master_data.read");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("nav.master_data", "Common data")}>
        Products and business partners. A document line needs a product and most documents need a
        business partner, so this is where an organisation becomes able to transact.
      </PageHeader>

      <Items mayWrite={mayWrite} maySeeSuppliers={maySeeSuppliers} />
      <Parties mayWrite={mayWrite} mayRead={mayReadParty} />

      <ActionBar
        title="Partners, roles and duplicates"
        note="A business partner is one record with the roles it plays. Two records for one partner are merged into a survivor, with the reason kept."
        actions={[
          {
            label: "Set a business partner's address",
            description:
              "Where invoices, deliveries or remittances go. A new address of the same kind replaces the one before as the default; the old one is kept on record.",
            permission: "master_data.write",
            fn: "erp_set_party_address",
            mapArgs: partyAddressArgs,
            fields: [
              pickParty(undefined, "p_party_id", "Business partner"),
              {
                kind: "choice",
                name: "p_address_kind",
                label: "Kind of address",
                required: true,
                default: "billing",
                choices: [
                  { value: "billing", label: "Billing" },
                  { value: "delivery", label: "Delivery" },
                  { value: "collection", label: "Collection" },
                  { value: "remittance", label: "Remittance" },
                  { value: "returns", label: "Returns" },
                ],
              },
              {
                kind: "text",
                name: "line_1",
                label: "Address, first line",
                required: true,
                placeholder: "2 Buyer Street",
              },
              {
                kind: "text",
                name: "line_2",
                label: "Address, second line",
                placeholder: "Unit 4",
              },
              { kind: "text", name: "p_locality", label: "Town", placeholder: "York" },
              { kind: "text", name: "p_postcode", label: "Postcode", placeholder: "YO1 1AA" },
              pickCountry("p_country_code", "Country", false),
              { kind: "text", name: "p_label", label: "Label", placeholder: "Accounts payable" },
            ],
            invalidates: ["erp_parties"],
          },
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
                choices: ROLE_CHOICES,
              },
              pickCountry("p_country_code", "Country", false),
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
                choices: ROLE_CHOICES,
              },
            ],
            invalidates: ["erp_parties"],
          },
          // One action per kind of record, because a picker cannot change its
          // door on the strength of a sibling field: the survivor and the
          // duplicate are chosen from the business partners or from the
          // products, never typed as ids.
          {
            label: "Merge duplicate business partners",
            description:
              "Every reference to the duplicate is moved to the survivor; the duplicate is withdrawn, not deleted.",
            // The database authorises master_data.approve: a merge withdraws a
            // record and is not undone, which is the second person's act.
            permission: "master_data.approve",
            fn: "erp_merge_master_record",
            fields: [
              pickParty(undefined, "p_survivor_id", "Record being kept"),
              pickParty(undefined, "p_duplicate_id", "Record being withdrawn"),
              reason("p_reason", "Reason", true),
            ],
            mapArgs: (v) => ({
              p_object_type: "party",
              p_survivor_id: v["p_survivor_id"],
              p_duplicate_id: v["p_duplicate_id"],
              p_reason: v["p_reason"],
            }),
            invalidates: ["erp_parties"],
          },
          {
            label: "Merge duplicate products",
            description:
              "Every reference to the duplicate is moved to the survivor; the duplicate is withdrawn, not deleted.",
            // The database authorises master_data.approve: a merge withdraws a
            // record and is not undone, which is the second person's act.
            permission: "master_data.approve",
            fn: "erp_merge_master_record",
            fields: [
              pickItem("p_survivor_id", "Record being kept"),
              pickItem("p_duplicate_id", "Record being withdrawn"),
              reason("p_reason", "Reason", true),
            ],
            mapArgs: (v) => ({
              p_object_type: "item",
              p_survivor_id: v["p_survivor_id"],
              p_duplicate_id: v["p_duplicate_id"],
              p_reason: v["p_reason"],
            }),
            invalidates: ["erp_items"],
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
                // The values of erp.uom_class, which erp_create_uom casts to.
                choices: [
                  { value: "quantity", label: "Quantity" },
                  { value: "mass", label: "Mass (weight)" },
                  { value: "volume", label: "Volume" },
                  { value: "length", label: "Length" },
                  { value: "area", label: "Area" },
                  { value: "time", label: "Time" },
                  { value: "packaging", label: "Packaging" },
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

type Words = (text: string) => string;

/**
 * A product's class in the words the New product form offers it by. A class
 * nothing on the form names (one a file loaded, say) is still shown as words.
 */
function classWord(code: string | null, ui: Words): string {
  switch (code) {
    case null:
    case "":
      return "—";
    case "finished_good":
      return ui("Finished good");
    case "raw_material":
      return ui("Raw material");
    case "packaging":
      return ui("Packaging");
    case "consumable":
      return ui("Consumable");
    default:
      return prettifyField(code);
  }
}

/** A product's status (erp.item_lifecycle), as the New product form words it. */
function lifecycleWord(code: string, ui: Words): string {
  switch (code) {
    case "draft":
      return ui("Draft");
    case "active":
      return ui("Active");
    case "restricted":
      return ui("Restricted");
    case "discontinued":
      return ui("Discontinued");
    case "obsolete":
      return ui("Obsolete");
    default:
      return prettifyField(code);
  }
}

/** Whether a record is in use (erp.record_status). */
function recordStatusWord(code: string, ui: Words): string {
  switch (code) {
    case "draft":
      return ui("Draft");
    case "active":
      return ui("Active");
    case "inactive":
      return ui("Inactive");
    case "archived":
      return ui("Archived");
    default:
      return prettifyField(code);
  }
}

function ItemRecord({ item, maySeeSuppliers }: { item: Item; maySeeSuppliers: boolean }) {
  const { ui } = useT();
  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="font-mono text-sm font-semibold">{item.code}</h3>
        <p className="min-w-0 flex-1 truncate text-base">{item.name}</p>
        <Pill tone={item.lifecycle === "active" ? "ok" : "muted"}>
          {lifecycleWord(item.lifecycle, ui)}
        </Pill>
      </div>

      <RecordSection title="Identification">
        <dl className="grid gap-4 sm:grid-cols-3">
          <Field label="Class">{classWord(item.item_class, ui)}</Field>
          <Field label="Category">{item.item_group ?? "—"}</Field>
          <Field label="Stock unit">{item.stock_uom_code ?? "—"}</Field>
          <Field label="Status">{recordStatusWord(item.status, ui)}</Field>
        </dl>
      </RecordSection>

      <RecordSection title="Description">
        {/* Its own section rather than a field in the grid above: a field
            there is one truncated line, and this can run to a paragraph. */}
        {item.description ? (
          <p className="whitespace-pre-line break-words text-sm">{item.description}</p>
        ) : (
          <p className="text-sm text-muted-foreground">
            None. A line for this product carries only what whoever raises it types.
          </p>
        )}
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
        <Table columns={["Supplier", "Their code", "Rank", "Days to arrive", "Approved"]}>
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
          name: "p_description",
          label: "Description",
          placeholder: "Oat milk, 1 litre cartons, case of 12",
          hint: "What the product is, in the words that should appear on orders, receipts and invoices. Lines take it when nobody types one.",
        },
        {
          kind: "choice",
          name: "p_item_class",
          label: "Class",
          choices: [
            { value: "finished_good", label: "Finished good" },
            { value: "raw_material", label: "Raw material" },
            { value: "packaging", label: "Packaging" },
            { value: "consumable", label: "Consumable" },
          ],
          hint: "What kind of thing it is. Drives bills of materials and planning.",
        },
        {
          kind: "combo",
          name: "p_item_group",
          label: "Category",
          options: { fn: "erp_item_categories", value: "group", label: ["group"] },
          hint: "The group it belongs to — pick one already in use or type a new one.",
        },
        {
          kind: "choice",
          name: "p_lifecycle",
          label: "Status",
          choices: [
            { value: "draft", label: "Draft" },
            { value: "active", label: "Active" },
            { value: "restricted", label: "Restricted" },
            { value: "discontinued", label: "Discontinued" },
            { value: "obsolete", label: "Obsolete" },
          ],
          hint: "Left blank, a new product starts active.",
        },
      ]}
      mapArgs={(v) => ({
        p_code: v["p_code"],
        p_name: v["p_name"],
        // Optional: blank is no description, and the database trims the rest.
        p_description: v["p_description"]?.trim() || null,
        p_item_class: v["p_item_class"] || null,
        p_item_group: v["p_item_group"] || null,
        p_lifecycle: v["p_lifecycle"] || null,
        p_is_batch_controlled: false,
      })}
      invalidates={["erp_items"]}
      submitLabel="Create product"
    />
  );
}

function Parties({ mayWrite, mayRead }: { mayWrite: boolean; mayRead: boolean }) {
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
      detail={(party) => <PartyRecord party={party} mayRead={mayRead} mayWrite={mayWrite} />}
    />
  );
}

/** A business partner's VAT number and payment terms, from erp_party_details. */
type PartyTerms = {
  role: string;
  payment_terms_code: string | null;
  payment_terms_name: string | null;
  payment_days: number | null;
};

type PartyDetails = {
  party_id: string;
  tax_identifier: string | null;
  /** One of the organisation's own companies: its VAT number is kept with its invoice details. */
  is_company: boolean;
  is_merged: boolean;
  terms: PartyTerms[];
};

/** One of a business partner's people, from erp_party_contacts. */
type PartyContact = {
  contact_id: string;
  kind: string;
  name: string | null;
  email: string | null;
  phone: string | null;
  is_default: boolean;
  state: "current" | "ended" | "starts_later";
  erased: boolean;
};

/**
 * What a contact is reached for: the values erp_save_party_contact accepts.
 * "purchasing" is the one a purchase order's email goes to first
 * (erp.supplier_email_address); "commercial" is what the party file and Set
 * the quote's contact write.
 */
const CONTACT_KINDS = [
  { value: "commercial", label: "General" },
  { value: "purchasing", label: "Purchase orders" },
  { value: "accounts", label: "Invoices and payments" },
  { value: "delivery", label: "Deliveries" },
  { value: "other", label: "Other" },
];

const SECONDARY = `${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-3 text-sm font-medium`;

/** What a partner's details change: the record's own reads. */
const DETAILS_CHANGED = ["erp_party_details"];
const CONTACTS_CHANGED = ["erp_party_contacts"];

function roleWord(code: string, ui: Words): string {
  const known = ROLE_CHOICES.find((r) => r.value === code);
  return known ? ui(known.label) : prettifyField(code);
}

function contactKindWord(code: string, ui: Words): string {
  const known = CONTACT_KINDS.find((k) => k.value === code);
  return known ? ui(known.label) : prettifyField(code);
}

function PartyRecord({
  party,
  mayRead,
  mayWrite,
}: {
  party: Party;
  mayRead: boolean;
  mayWrite: boolean;
}) {
  const { ui } = useT();
  // erp_party_details authorises master_data.read, so it is asked for only
  // where it would be answered (as ItemSuppliers is on procurement.read).
  const details = useQuery({
    queryKey: ["erp_party_details", { partyId: party.party_id }],
    queryFn: () => callErp<PartyDetails>("erp_party_details", { p_party_id: party.party_id }),
    enabled: mayRead,
  });
  const vat = !mayRead ? "—" : details.isPending ? "…" : (details.data?.tax_identifier ?? "—");
  const context = `${party.code} — ${party.name}`;
  const mayKeep = mayWrite && details.data !== undefined && !details.data.is_merged;
  // An answer without terms (an empty one, say) has none to show.
  const terms = details.data?.terms ?? [];

  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <h3 className="font-mono text-sm font-semibold">{party.code}</h3>
        <p className="min-w-0 flex-1 truncate text-base">{party.name}</p>
        <Pill tone={party.status === "active" ? "ok" : "muted"}>
          {recordStatusWord(party.status, ui)}
        </Pill>
      </div>

      <RecordSection title="Identification">
        <dl className="grid gap-4 sm:grid-cols-3">
          <Field label="Legal name">{party.legal_name ?? party.name}</Field>
          <Field label="Country">{party.country_code ?? "—"}</Field>
          <Field label="Status">{recordStatusWord(party.status, ui)}</Field>
          <Field label="VAT number">
            <span className="font-mono">{vat}</span>
          </Field>
        </dl>
        {details.error ? <ErrorNote error={details.error} /> : null}
        {details.data?.is_company ? (
          <p className="mt-2 text-xs text-muted-foreground">
            {ui(
              "One of this organisation's own companies. Its VAT number is kept with its invoice details.",
            )}
          </p>
        ) : mayKeep ? (
          <div className="mt-3">
            <ActionDialog
              trigger={
                <button type="button" className={SECONDARY}>
                  {ui("Set the VAT number")}
                </button>
              }
              title="Set the VAT number"
              description="As it is printed on the partner's invoices, such as GB123456789. Spaces, dots and dashes are taken out."
              permission="master_data.write"
              fn="erp_set_party_tax_identifier"
              fields={[
                {
                  kind: "text",
                  name: "p_tax_identifier",
                  label: "VAT number",
                  placeholder: "GB123456789",
                  hint: "Leave it empty to clear the VAT number.",
                },
              ]}
              preselect={{ p_tax_identifier: details.data?.tax_identifier ?? "" }}
              mapArgs={(v) => ({
                p_party_id: party.party_id,
                p_tax_identifier: v["p_tax_identifier"]?.trim() || null,
              })}
              prefill={{ p_party_id: party.party_id }}
              context={context}
              invalidates={DETAILS_CHANGED}
            />
          </div>
        ) : null}
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
                {roleWord(r, ui)}
              </Pill>
            ))}
          </div>
        )}
      </RecordSection>

      {mayRead ? (
        <RecordSection title={ui("Payment terms")}>
          {details.isPending ? (
            <p role="status" className="text-sm text-muted-foreground">
              Loading…
            </p>
          ) : terms.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {ui(
                "Payment terms are kept for a customer or a supplier. Give this partner one of those roles first.",
              )}
            </p>
          ) : (
            <>
              <dl className="grid gap-4 sm:grid-cols-3">
                {terms.map((t) => (
                  <Field
                    key={t.role}
                    label={t.role === "customer" ? ui("As a customer") : ui("As a supplier")}
                  >
                    {t.payment_terms_name ?? ui("Not set")}
                  </Field>
                ))}
              </dl>
              {mayKeep ? (
                <div className="mt-3">
                  <ActionDialog
                    trigger={
                      <button type="button" className={SECONDARY}>
                        {ui("Set payment terms")}
                      </button>
                    }
                    title="Set payment terms"
                    description="When this partner pays the organisation as a customer, or is paid as a supplier. A credit limit is kept separately, on Sales."
                    permission="master_data.write"
                    fn="erp_set_party_payment_terms"
                    fields={[
                      {
                        kind: "choice",
                        name: "p_role",
                        label: "Role",
                        required: true,
                        choices: ROLE_CHOICES.filter((r) => terms.some((t) => t.role === r.value)),
                        hint: "Customer or supplier: the role these terms are for.",
                      },
                      {
                        kind: "select",
                        name: "p_payment_terms_code",
                        label: "Payment terms",
                        options: { fn: "erp_payment_terms", value: "code", label: ["name"] },
                        hint: "Leave empty to clear the terms.",
                      },
                    ]}
                    preselect={{
                      p_role: terms[0]?.role ?? "",
                      p_payment_terms_code: terms[0]?.payment_terms_code ?? "",
                    }}
                    mapArgs={(v) => ({
                      p_party_id: party.party_id,
                      p_role: v["p_role"],
                      p_payment_terms_code: v["p_payment_terms_code"] || null,
                    })}
                    prefill={{ p_party_id: party.party_id }}
                    context={context}
                    invalidates={DETAILS_CHANGED}
                  />
                </div>
              ) : null}
            </>
          )}
        </RecordSection>
      ) : null}

      {mayRead ? (
        <PartyContacts partyId={party.party_id} context={context} mayKeep={mayKeep} />
      ) : null}

      <RecordSection title={ui("Addresses and credit")}>
        <p className="text-sm text-muted-foreground">
          {ui(
            "A business partner's addresses are set on this screen. A customer's credit limit is set on Sales.",
          )}
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          {mayWrite ? (
            <button
              type="button"
              className={SECONDARY}
              onClick={() => openAction("erp_set_party_address")}
            >
              {ui("Set a business partner's address")}
            </button>
          ) : null}
          <GoTo to="/sales">{ui("Open Sales")}</GoTo>
        </div>
      </RecordSection>
    </div>
  );
}

function PartyContacts({
  partyId,
  context,
  mayKeep,
}: {
  partyId: string;
  context: string;
  mayKeep: boolean;
}) {
  const { ui } = useT();
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_party_contacts", { partyId }],
    queryFn: () => callErp<PartyContact[]>("erp_party_contacts", { p_party_id: partyId }),
  });
  const contacts = data ?? [];

  return (
    <RecordSection title={ui("Contacts")}>
      <p className="mb-3 text-xs text-muted-foreground">
        {ui(
          "Somebody at this partner, and how they are reached. A purchase order's email goes to the purchase orders contact first, then the default one; a quote goes to the default one.",
        )}
      </p>
      {isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading…
        </p>
      ) : error ? (
        <ErrorNote error={error} />
      ) : contacts.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          {ui(
            "No contact yet. A purchase order or quote emailed to this partner has nobody to go to.",
          )}
        </p>
      ) : (
        <Table columns={[ui("Name"), ui("Kind"), ui("Email"), ui("Phone"), ""]}>
          {contacts.map((c) => (
            <tr key={c.contact_id} className="border-b border-border/50 align-top last:border-0">
              <td className="py-2 pr-4">
                {c.name ?? "—"}
                {c.is_default ? (
                  <span className="ml-1.5">
                    <Pill tone="ok">{ui("Default")}</Pill>
                  </span>
                ) : null}
                {c.state === "ended" ? (
                  <span className="ml-1.5">
                    <Pill tone="muted">{ui("Ended")}</Pill>
                  </span>
                ) : null}
                {c.erased ? (
                  <span className="ml-1.5">
                    <Pill tone="muted">{ui("Details erased on request")}</Pill>
                  </span>
                ) : null}
              </td>
              <td className="py-2 pr-4 text-xs">{contactKindWord(c.kind, ui)}</td>
              <td className="py-2 pr-4 text-xs">{c.email ?? "—"}</td>
              <td className="py-2 pr-4 text-xs">{c.phone ?? "—"}</td>
              <td className="py-2">
                {mayKeep && c.state !== "ended" ? (
                  <div className="flex flex-wrap gap-2">
                    {c.erased ? null : (
                      <ContactDialog partyId={partyId} context={context} contact={c} />
                    )}
                    <ActionDialog
                      trigger={
                        <button type="button" className={SECONDARY}>
                          {ui("End the contact")}
                        </button>
                      }
                      title="End the contact"
                      description="The contact stops being sent anything from today. They stay on the record, ended."
                      permission="master_data.write"
                      fn="erp_end_party_contact"
                      fields={[]}
                      prefill={{ p_contact_id: c.contact_id }}
                      context={`${context}: ${c.name ?? c.email ?? ""}`}
                      invalidates={CONTACTS_CHANGED}
                      submitLabel="End the contact"
                    />
                  </div>
                ) : null}
              </td>
            </tr>
          ))}
        </Table>
      )}
      {mayKeep ? (
        <div className="mt-3">
          <ContactDialog partyId={partyId} context={context} />
        </div>
      ) : null}
    </RecordSection>
  );
}

/** Add a contact, or, given one, change it. */
function ContactDialog({
  partyId,
  context,
  contact,
}: {
  partyId: string;
  context: string;
  contact?: PartyContact;
}) {
  const { ui } = useT();
  const label = contact ? "Change the contact" : "Add a contact";
  return (
    <ActionDialog
      trigger={
        <button type="button" className={SECONDARY}>
          {ui(label)}
        </button>
      }
      title={label}
      description="Somebody at this partner, and how they are reached. A purchase order's email goes to the purchase orders contact first, then the default one; a quote goes to the default one."
      permission="master_data.write"
      fn="erp_save_party_contact"
      fields={[
        {
          kind: "choice",
          name: "p_kind",
          label: "Kind",
          choices: CONTACT_KINDS,
          hint: "What this contact is reached for.",
        },
        {
          kind: "text",
          name: "p_name",
          label: "Name",
          placeholder: "Kim Lee",
          hint: "Give a name, an email address, or both.",
        },
        {
          kind: "text",
          name: "p_email",
          label: "Email",
          placeholder: "kim@example.com",
          hint: "Where emails to this contact go.",
        },
        {
          kind: "text",
          name: "p_phone",
          label: "Phone",
          placeholder: "01904 123456",
          hint: "With its digits, and the country code if it is abroad.",
        },
        {
          kind: "choice",
          name: "p_is_default",
          label: "Default",
          boolean: true,
          choices: [
            { value: "false", label: "No" },
            { value: "true", label: "Yes" },
          ],
          hint: "The one emails to this partner go to when nothing more particular is asked for.",
        },
      ]}
      preselect={
        contact
          ? {
              p_kind: CONTACT_KINDS.some((k) => k.value === contact.kind) ? contact.kind : "",
              p_name: contact.name ?? "",
              p_email: contact.email ?? "",
              p_phone: contact.phone ?? "",
              p_is_default: contact.is_default ? "true" : "false",
            }
          : { p_kind: "commercial" }
      }
      mapArgs={(v) => ({
        p_party_id: partyId,
        p_contact_id: contact?.contact_id ?? null,
        p_kind: v["p_kind"] || null,
        p_name: v["p_name"]?.trim() || null,
        p_email: v["p_email"]?.trim() || null,
        p_phone: v["p_phone"]?.trim() || null,
        p_is_default: v["p_is_default"] ? v["p_is_default"] === "true" : null,
      })}
      prefill={{ p_party_id: partyId }}
      context={context}
      invalidates={CONTACTS_CHANGED}
      submitLabel={label}
    />
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
          choices: ROLE_CHOICES,
          hint: "More roles can be added afterwards.",
        },
        pickCountry("p_country_code", "Country", false),
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
