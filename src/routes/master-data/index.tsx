import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";

import { ActionButton, ActionDialog, ErrorNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";

/**
 * Items and parties.
 *
 * Every document line points at an item and most documents point at a party,
 * so a tenant with neither cannot transact at all. Until now there was no way
 * to create either from the product — the pickers on Sales and Procurement
 * were reading lists nothing could ever fill.
 *
 * Both tables are deliberately plain. This is the minimum a document needs:
 * a code, a name, and for a party the role that decides which picker offers
 * it. The rest of the master-data surface — attributes, classifications,
 * duplicate merging, mass change — is governed work with its own approvals,
 * and belongs on its own screens rather than smuggled into a create form.
 */

export const Route = createFileRoute("/master-data/")({
  head: () => ({
    meta: [
      { title: "Master data — ERPWare" },
      {
        name: "description",
        content:
          "Create and review the items and trading parties every ERPWare document depends on.",
      },
      { property: "og:title", content: "Master data — ERPWare" },
      {
        property: "og:description",
        content:
          "Create and review the items and trading parties every ERPWare document depends on.",
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
  lifecycle: string;
  is_batch_controlled: boolean;
  status: string;
};

type Party = {
  party_id: string;
  code: string;
  name: string;
  country_code: string | null;
  status: string;
  roles: string[];
};

const ROLES = ["customer", "supplier", "carrier", "manufacturer", "broker", "consignee", "agent"];

function MasterData() {
  const { session } = useErpSession();
  const mayWrite = hasPermission(session, "master_data.write");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Master data">
        Items and parties. A document line needs an item and most documents need a party, so this is
        where a tenant becomes able to transact.
      </PageHeader>

      <Items mayWrite={mayWrite} />
      <Parties mayWrite={mayWrite} />
    </div>
  );
}

function Items({ mayWrite }: { mayWrite: boolean }) {
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_items", {}],
    queryFn: () => callErp<Item[]>("erp_items"),
  });

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold">Items</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            What is bought, made, stocked and sold. The unit of measure is created with the first
            item when the tenant has none.
          </Prose>
        </div>

        {mayWrite ? (
          <ActionDialog
            trigger={<ActionButton>New item</ActionButton>}
            title="New item"
            description="A code and a name are the minimum. Everything else is maintainable afterwards."
            permission="master_data.write"
            fn="erp_create_item"
            fields={[
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
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
            submitLabel="Create item"
          />
        ) : null}
      </header>

      <div className="px-4 py-4 sm:px-5">
        {isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : error ? (
          <ErrorNote error={error} />
        ) : (data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No items yet. Nothing can be put on a document line until there is one.
          </p>
        ) : (
          <Table columns={["Code", "Name", "Class", "Lifecycle", "Batches"]}>
            {(data ?? []).map((i) => (
              <tr key={i.item_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{i.code}</td>
                <td className="py-2 pr-4">{i.name}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{i.item_class ?? "—"}</td>
                <td className="py-2 pr-4">
                  <Pill tone={i.lifecycle === "active" ? "ok" : "muted"}>{i.lifecycle}</Pill>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {i.is_batch_controlled ? "Batch controlled" : "—"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </div>
    </section>
  );
}

function Parties({ mayWrite }: { mayWrite: boolean }) {
  const { data, isPending, error } = useQuery({
    queryKey: ["erp_parties", {}],
    queryFn: () => callErp<Party[]>("erp_parties"),
  });

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold">Parties</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            One table for customers, suppliers and everybody else. The role is what decides which
            picker offers a party, and one party may hold several.
          </Prose>
        </div>

        {mayWrite ? (
          <ActionDialog
            trigger={<ActionButton>New party</ActionButton>}
            title="New party"
            description="The role given here is the first one; more can be added afterwards."
            permission="master_data.write"
            fn="erp_create_party"
            fields={[
              { kind: "text", name: "p_code", label: "Code", required: true },
              { kind: "text", name: "p_name", label: "Name", required: true },
              {
                kind: "text",
                name: "p_role_kind",
                label: "Role",
                required: true,
                hint: `One of: ${ROLES.join(", ")}.`,
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
            submitLabel="Create party"
          />
        ) : null}
      </header>

      <div className="px-4 py-4 sm:px-5">
        {isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : error ? (
          <ErrorNote error={error} />
        ) : (data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No parties yet. A sales order needs a customer and a purchase order needs a supplier.
          </p>
        ) : (
          <Table columns={["Code", "Name", "Country", "Roles", "Status"]}>
            {(data ?? []).map((p) => (
              <tr key={p.party_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{p.code}</td>
                <td className="py-2 pr-4">{p.name}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{p.country_code ?? "—"}</td>
                <td className="py-2 pr-4">
                  <span className="flex flex-wrap gap-1">
                    {(p.roles ?? []).length === 0 ? (
                      <span className="text-xs text-muted-foreground">
                        None — this party is offered nowhere
                      </span>
                    ) : (
                      (p.roles ?? []).map((r) => (
                        <Pill key={r} tone="muted">
                          {r}
                        </Pill>
                      ))
                    )}
                  </span>
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={p.status === "active" ? "ok" : "muted"}>{p.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </div>
    </section>
  );
}
