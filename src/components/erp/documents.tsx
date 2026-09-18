import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp } from "../../lib/erp";
import { formatMinor, minorUnitsOf, toMinor, type Currency } from "../../lib/money";
import { useCurrencies } from "./currencies";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import { useErpSession, useScope } from "./session-context";
import { LoadingRows, Prose } from "./page";
import { Pill, Table } from "./panel";

/**
 * A list of documents of one kind, with the action that creates another.
 *
 * The screen names a **base** type — `quotation`, `purchase_order` — which is
 * product content and stable. The tenant's own type code, its numbering, its
 * lifecycle and the permission required to raise one all come from
 * `erp_document_types`. A tenant that calls its purchase orders something else
 * still gets a working button.
 *
 * That indirection is the whole reason `/sales` and `/procurement` are two
 * short files rather than two copies of this one.
 */

type Doc = {
  document_id: string;
  document_number: string;
  document_type: string;
  document_date: string;
  currency: string;
  party: string | null;
  total_minor: number;
  state: string | null;
  state_name: string | null;
  is_committed: boolean;
};

type DocType = {
  document_type_id: string;
  code: string;
  name: string;
  base_type_code: string;
  requires_party: boolean;
  requires_site: boolean;
  /**
   * The currency a document of this type is opened in: the base currency of
   * the company the type belongs to, which is what `erp.create_document` gives
   * a document when the caller names none. Null only when the type names no
   * company, and such a type cannot open a document at all.
   */
  currency: string | null;
  /** The permission `erp.open_document` will actually authorise. */
  create_permission: string;
};

export function DocumentPanel({
  title,
  description,
  baseType,
  /** Which party role the picker should offer — customers for sales, suppliers for buying. */
  partyRole,
  /**
   * Which configured type to show when a base carries more than one. A sales
   * invoice and a purchase invoice share the invoice_reference base, so the
   * base alone would put the supplier's bills on the sales screen.
   */
  typeCode,
  empty,
}: {
  title: string;
  description: string;
  baseType: string;
  partyRole: string;
  typeCode?: string;
  empty: string;
}) {
  const { session } = useErpSession();
  const scope = useScope();

  const {
    data: types,
    isPending: typesPending,
    error: typesError,
  } = useQuery({
    queryKey: ["erp_document_types", { p_base_type_code: baseType }],
    queryFn: () => callErp<DocType[]>("erp_document_types", { p_base_type_code: baseType }),
  });

  const { currencies } = useCurrencies();

  // A tenant may configure more than one type onto a base; the first active one
  // is the sensible default and the others are reachable once there is a reason
  // to choose between them.
  const type = typeCode ? types?.find((x) => x.code === typeCode) : types?.[0];

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_documents", { p_type_code: type?.code ?? "" }],
    queryFn: () => callErp<Doc[]>("erp_documents", { p_type_code: type?.code ?? "" }),
    enabled: Boolean(type),
    refetchInterval: 30_000,
  });

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="flex flex-wrap items-start justify-between gap-3 border-b border-border px-4 py-4 sm:px-5">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-semibold">{title}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">{description}</Prose>
        </div>

        {type && type.requires_site && session.sites.length === 0 ? (
          // The database refuses a document of this type without a site, and a
          // freshly provisioned organisation has none. Saying so beats a
          // dialog whose only possible outcome is a constraint failure.
          <p className="max-w-xs text-xs text-muted-foreground">
            This type needs a site, and this organisation has none yet. Add one under{" "}
            <Link to="/administration/organisation" className="underline underline-offset-2">
              Organisation structure
            </Link>
            .
          </p>
        ) : type ? (
          <NewDocumentAction type={type} partyRole={partyRole} />
        ) : null}
      </header>

      <div className="w-full max-w-full overflow-x-auto px-4 py-4 sm:px-5">
        {typesError ? (
          // A failed lookup is not an unconfigured tenant. Saying "install the
          // module" when the call fell over sends the reader to fix something
          // that was never broken.
          <ErrorNote error={typesError} />
        ) : typesPending ? (
          <LoadingRows />
        ) : !type ? (
          <p className="text-sm text-muted-foreground">
            No <code className="font-mono text-xs">{typeCode ?? baseType}</code> type is configured
            for this tenant. Installing the module that owns it on{" "}
            <Link to="/administration/configuration" className="underline underline-offset-2">
              Configuration
            </Link>{" "}
            is what creates one.
          </p>
        ) : isPending ? (
          <LoadingRows />
        ) : error ? (
          <ErrorNote error={error} />
        ) : (data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">{empty}</p>
        ) : (
          <Table columns={["Number", "Date", "Business partner", "Value", "State"]}>
            {(data ?? []).map((d) => (
              <tr key={d.document_id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4">
                  <Link
                    to="/documents/$documentId"
                    params={{ documentId: d.document_id }}
                    className="font-mono text-xs underline underline-offset-2"
                  >
                    {d.document_number}
                  </Link>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{d.document_date}</td>
                <td className="py-2 pr-4">{d.party ?? "—"}</td>
                <td className="py-2 pr-4 text-right tabular-nums">
                  {formatMinor(d.total_minor, d.currency, minorUnitsOf(currencies, d.currency))}
                </td>
                <td className="py-2 pr-4">
                  {/*
                    Committed is the distinction that matters operationally: it
                    is the point past which the outside world believes the
                    document, and for a delivery it is the moment stock left.
                  */}
                  <Pill tone={d.is_committed ? "ok" : "muted"}>
                    {d.state_name ?? d.state ?? "—"}
                  </Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </div>
    </section>
  );
}

/**
 * Raise a whole document on one screen.
 *
 * Header and lines are one form and one call: the partner, the dates and every
 * product with its quantity and price. It used to be a form for the header and
 * then a second visit to price each line, which is two pieces of work for one
 * decision. `erp_create_document_full` writes it as a whole, so a rejected line
 * leaves nothing half-made behind it.
 */
export function NewDocumentAction({
  type,
  partyRole,
  label,
}: {
  type: DocType;
  partyRole?: string;
  label?: string;
}) {
  const { session } = useErpSession();
  const scope = useScope();
  const { currencies } = useCurrencies();

  // The currency this document will be opened in, and the exponent that goes
  // with it. Both used to be the literal "GBP": the boxes said (GBP) whatever
  // the company trades in, and — the part that reached the ledger — a price
  // typed against a currency with no decimal places, JPY or KRW, was
  // multiplied by a hundred on its way to p_unit_price_minor. The sibling
  // screen, src/routes/documents/$documentId.tsx, has always used the
  // document's own currency; this one could not, because until now
  // erp_document_types did not say what it would be. p_currency is sent as
  // well, so what the form converted by and what the database opens the
  // document in are the same answer rather than two that happen to agree.
  const currency = type.currency ?? "";
  const minorUnits = minorUnitsOf(currencies, type.currency);

  // Which catalogue the database will ask for a line nobody priced, read the
  // way erp.document_type_party_role_kind() reads it: from the module the
  // permission belongs to. The form asks the same question so that the total it
  // shows is the total the record comes back with — it used to show GBP 0.00
  // for a line the database was about to price, and nothing at all for one it
  // could not price and would write at nought.
  const buying = type.create_permission.startsWith("procurement.");
  const selling = type.create_permission.startsWith("sales.");
  const effectiveSite = scope.siteId || session.sites[0]?.id || "";

  return (
    <ActionDialog
      trigger={<ActionButton>{label ?? "New"}</ActionButton>}
      title={`New ${type.name.toLowerCase()}`}
      description="Partner, dates and every line on one form. It is saved as a whole: if a line is wrong, nothing is created."
      // The permission the database checks, not one this screen guessed.
      permission={type.create_permission}
      fn="erp_create_document_full"
      fields={[
        {
          kind: "select",
          name: "p_party_id",
          label: "Business partner",
          required: type.requires_party,
          options: {
            fn: "erp_parties",
            args: { p_role_kind: partyRole ?? null },
            value: "party_id",
            label: ["code", "name"],
          },
        },
        // Only asked when the shell's scope has not already answered it: one
        // site, or a site chosen up there, is not a question.
        ...(type.requires_site && !scope.siteId && session.sites.length > 1
          ? ([{ kind: "site", name: "p_site_id", label: "Site", required: true }] as const)
          : []),
        {
          kind: "text",
          name: "p_their_ref",
          label: "Their reference",
          placeholder: "COOP-PO-771",
          hint: "Their own order or invoice number, so both sides can find it.",
        },
        { kind: "date", name: "p_required_date", label: "Required date" },
        {
          kind: "rows",
          name: "p_lines",
          label: "Lines",
          // A document is its lines. Create on an empty form said nothing about
          // them; now it says a line is needed, beside the lines.
          required: true,
          addLabel: "Add a line",
          hint: "Everything this document is for. A line left without a price takes the agreed price for that partner and product, where there is one.",
          total: { quantity: "quantity", price: "unit_price_minor", currency },
          columns: [
            {
              name: "item_id",
              label: "Product",
              kind: "select",
              options: { fn: "erp_items", value: "item_id", label: ["code", "name"] },
            },
            { name: "quantity", label: "Quantity", kind: "number", placeholder: "100" },
            {
              name: "unit_price_minor",
              label: "Unit price",
              kind: "money",
              currency,
              placeholder: "1.85",
              // A line left empty takes the agreed price. It used to be the
              // database that knew that and the form that did not, so the
              // running total said GBP 0.00 and the record did not.
              ...(buying
                ? {
                    priceFrom: {
                      fn: "erp_resolve_purchase_price",
                      args: {
                        p_item_id: "item_id",
                        p_quantity: "quantity",
                        p_party_id: "form.p_party_id",
                        p_site_id: "form.p_site_id",
                      },
                      fixed: { p_site_id: effectiveSite },
                      needs: ["p_item_id", "p_party_id"],
                      amount: "amount_minor",
                      note: "source",
                    },
                  }
                : {}),
              ...(selling
                ? {
                    priceFrom: {
                      fn: "erp_resolve_price",
                      args: {
                        p_item_id: "item_id",
                        p_quantity: "quantity",
                        p_party_id: "form.p_party_id",
                      },
                      needs: ["p_item_id", "p_party_id"],
                      amount: "amount_minor",
                      note: "source",
                    },
                  }
                : {}),
            },
            // The product's own description arrives the moment the product is
            // picked, so it is seen and can be changed. Left blank, the
            // database gives the line the product's description anyway — the
            // same rule for every route a line is written by, not only this one.
            {
              name: "description",
              label: "Description",
              kind: "text",
              placeholder: "Leave blank to use the product's description",
              fillFrom: { column: "item_id", key: "description" },
            },
          ],
        },
      ]}
      mapArgs={(v, picked) => ({
        p_type_code: type.code,
        p_party_id: v["p_party_id"] || null,
        p_site_id: v["p_site_id"] || scope.siteId || session.sites[0]?.id || null,
        p_their_ref: v["p_their_ref"] || null,
        p_required_date: v["p_required_date"] || null,
        p_currency: type.currency,
        p_lines: (picked?.rows["p_lines"] ?? [])
          .filter((row) => (row["item_id"] ?? "") !== "")
          .map((row) => ({
            item_id: row["item_id"],
            quantity: Number(row["quantity"] ?? 0),
            unit_price_minor: toMinor(row["unit_price_minor"] ?? "", minorUnits),
            // A cleared box is no description: null, so the line takes the
            // product's.
            description: row["description"] || null,
          })),
      })}
      // One press for the straightforward case: raise it and move it on.
      alsoSubmit={{ label: "Create and move on", args: { p_transition: "auto" } }}
      invalidates={["erp_documents", "erp_document", "erp_document_lines"]}
      submitLabel="Create"
    />
  );
}

/**
 * The same form, reached from a step on a process strip.
 *
 * A step knows the configured type it stands for, not the record behind it, so
 * the type is looked up here rather than passed down through the strip.
 */
export function NewDocumentForType({
  typeCode,
  partyRole,
  label,
}: {
  typeCode: string;
  partyRole?: string;
  label?: string;
}) {
  const { data: types, isPending } = useQuery({
    queryKey: ["erp_document_types", { p_base_type_code: "" }],
    queryFn: () => callErp<DocType[]>("erp_document_types", {}),
  });
  // Drawn, disabled, while the types are read. It used to be absent until then
  // and appear under a moving cursor — which is how a click meant for the
  // button beside it lands on this one.
  if (isPending)
    return (
      <ActionButton disabled title="Loading">
        {label ?? "New"}
      </ActionButton>
    );
  const type = types?.find((t) => t.code === typeCode);
  if (!type) return null;
  return (
    <NewDocumentAction
      type={type}
      {...(partyRole ? { partyRole } : {})}
      {...(label ? { label } : {})}
    />
  );
}
