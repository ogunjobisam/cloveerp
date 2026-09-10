import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { callErp } from "../../lib/erp";
import { formatMinor, minorUnitsOf, toMinor, type Currency } from "../../lib/money";
import { useCurrencies } from "./currencies";
import { ActionButton, ActionDialog, ErrorNote } from "./action";
import { useErpSession } from "./session-context";
import { Prose } from "./page";
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
  const { session, scope } = useErpSession();

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
          <p className="text-sm text-muted-foreground">Loading…</p>
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
          <p className="text-sm text-muted-foreground">Loading…</p>
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
